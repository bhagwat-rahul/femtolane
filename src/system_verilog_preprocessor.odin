/*
SystemVerilog preprocessor: raw tokenizer frames in, a flat token array out.

All sources (files, includes, macro expansions, __FILE__/__LINE__ text) are byte
streams. That keeps argument scanning and nested macro expansion ordinary raw
tokenizing, exactly like the language's replacement-list model, and lets the parser
stay token-only.
*/

package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

SVPPFrame :: struct {
	tokenizer: SVTokenizer,
	path:      string,
}

SVCond :: struct {
	parent_active: bool,
	any_taken:     bool,
	active:        bool,
}

SVPreprocessor :: struct {
	ast:         ^SystemVerilogAST,
	allocator:   mem.Allocator,
	sources:     [dynamic]SVPPFrame,
	cond_stack:  [dynamic]SVCond,
	tokens:      [dynamic]SVToken,
	source_data: [dynamic]SVSource,
	total_depth: int,
}

svpp_init :: proc(ast: ^SystemVerilogAST, allocator: mem.Allocator) -> SVPreprocessor {
	return SVPreprocessor{ast = ast, allocator = allocator}
}

svpp_active :: #force_inline proc(pp: ^SVPreprocessor) -> bool {
	return len(pp.cond_stack) == 0 || pp.cond_stack[len(pp.cond_stack) - 1].active
}

svpp_add_file :: proc(pp: ^SVPreprocessor, data: []byte, path: string) -> u16 {
	append(&pp.source_data, SVSource{data = data, line_base = 1, path = path})
	return u16(len(pp.source_data) - 1)
}

svpp_push_include :: proc(pp: ^SVPreprocessor, path: string) {
	data, err := os.read_entire_file_from_path(path, pp.allocator)
	ensure(err == nil, fmt.tprint("SystemVerilog include read error: ", err, " ", path))
	file_id := svpp_add_file(pp, data, path)
	frame := SVPPFrame {
		tokenizer = svt_init(data, file_id),
		path      = path,
	}
	frame.tokenizer.comment_sink = &pp.ast.comments
	frame.tokenizer.path = path
	append(&pp.sources, frame)
	// Includes can be nested arbitrarily through the same frame stack; cap it for safety.
	pp.total_depth += 1
	ensure(pp.total_depth < 512, "SystemVerilog include nesting too deep")
}

svpp_push_text :: proc(pp: ^SVPreprocessor, text: string, path: string, line: u32) {
	// All callers hand us arena-owned text (builder output, fmt output, or a stored
	// macro body), so retain a byte view instead of copying it again.
	data := transmute([]byte)text
	append(&pp.source_data, SVSource{data = data, line_base = line, path = path})
	file_id := u16(len(pp.source_data) - 1)
	frame := SVPPFrame {
		tokenizer = svt_init(data, file_id),
		path      = path,
	}
	frame.tokenizer.comment_sink = &pp.ast.comments
	frame.tokenizer.path = path
	frame.tokenizer.line = line
	append(&pp.sources, frame)
	pp.total_depth += 1
	ensure(pp.total_depth < 4096, "SystemVerilog macro expansion nesting too deep")
}

svpp_cur_tokenizer :: #force_inline proc(pp: ^SVPreprocessor) -> ^SVTokenizer {
	return &pp.sources[len(pp.sources) - 1].tokenizer
}

svpp_error :: proc(pp: ^SVPreprocessor, msg: string) -> ! {
	panic(fmt.tprintf("SystemVerilog preprocessor error: %s", msg))
}

// ---------------------------------------------------------------------------------------
// Macro bodies and invocations
// ---------------------------------------------------------------------------------------

svpp_skip_define_line :: proc(l: ^SVTokenizer) {
	for {
		for !svt_at_eof(l) && !svt_is_newline(svt_peek(l)) { svt_advance(l) }
		continued := l.idx > 0 && l.src[l.idx - 1] == '\\'
		if svt_peek(l) == '\r' { svt_advance(l) }
		if svt_peek(l) == '\n' { svt_advance(l) }
		if !continued { break }
	}
}

svpp_scan_define :: proc(pp: ^SVPreprocessor) {
	l := svpp_cur_tokenizer(pp)
	svt_skip_blank(l)
	if !svt_is_ident_start(svt_peek(l)) {
		svpp_error(pp, "`define requires a macro name")
	}
	macro := svt_scan_ident(l)
	def := SVDefine {
		params         = make([dynamic]string, pp.allocator),
		param_defaults = make([dynamic]string, pp.allocator),
	}

	// Function-like only when '(' immediately follows the name (IEEE 1800-2023 22.5.1).
	if svt_peek(l) == '(' {
		def.is_function_like = true
		svt_advance(l)
		svt_skip_blank(l)
		if svt_peek(l) != ')' {
			for {
				svt_skip_blank(l)
				append(&def.params, svt_scan_ident(l))
				svt_skip_blank(l)
				default_text := ""
				if svt_peek(l) == '=' {
					svt_advance(l)
					svt_skip_blank(l)
					start := l.idx
					depth := 0
					for {
						c := svt_peek(l)
						if svt_at_eof(l) { svpp_error(pp, "unterminated macro parameter default") }
						if c == '"' {
							_ = svt_scan_string(l)
							continue
						}
						if c == '(' { depth += 1 }
						if c == ')' {
							if depth == 0 { break }
							depth -= 1
						}
						if c == ',' && depth == 0 { break }
						svt_advance(l)
					}
					default_text = strings.trim_space(string(l.src[start:l.idx]))
				}
				append(&def.param_defaults, default_text)
				svt_skip_blank(l)
				if svt_peek(l) == ',' {
					svt_advance(l)
					continue
				}
				break
			}
		}
		svt_skip_blank(l)
		if svt_peek(l) != ')' { svpp_error(pp, "expected ')' after macro parameters") }
		svt_advance(l)
	}

	// Replacement text runs to the end of the line; backslash-newline continues it and
	// is removed from the stored body. Comments are not part of the substituted text
	// and string literals are copied verbatim (22.5.1).
	b := strings.builder_make(pp.allocator)
	for !svt_at_eof(l) {
		c := svt_peek(l)
		if svt_is_newline(c) || c == 0 { break }
		if c == '"' {
			start := l.idx
			svt_advance(l)
			if svt_peek(l) == '"' && svt_peek(l, 1) == '"' {
				svt_advance(l, 2)
				for !svt_at_eof(l) {
					if svt_peek(l) == '"' && svt_peek(l, 1) == '"' && svt_peek(l, 2) == '"' {
						svt_advance(l, 3)
						break
					}
					if svt_peek(l) == '\\' { svt_advance(l, 2) } else { svt_advance(l) }
				}
			} else {
				for !svt_at_eof(l) {
					if svt_peek(l) == '\\' { svt_advance(l, 2); continue }
					if svt_peek(l) == '"' { svt_advance(l); break }
					if svt_is_newline(svt_peek(l)) { break }
					svt_advance(l)
				}
			}
			strings.write_string(&b, string(l.src[start:l.idx]))
			continue
		}
		if c == '/' && svt_peek(l, 1) == '/' {
			for !svt_at_eof(l) && !svt_is_newline(svt_peek(l)) { svt_advance(l) }
			continued := l.idx > 0 && l.src[l.idx - 1] == '\\'
			if continued {
				if svt_peek(l) == '\r' { svt_advance(l) }
				if svt_peek(l) == '\n' { svt_advance(l) }
				continue
			}
			break
		}
		if c == '/' && svt_peek(l, 1) == '*' {
			svt_advance(l, 2)
			for !svt_at_eof(l) && !(svt_peek(l) == '*' && svt_peek(l, 1) == '/') { svt_advance(l) }
			if svt_at_eof(l) { svpp_error(pp, "unterminated comment in macro body") }
			svt_advance(l, 2)
			continue
		}
		if c == '\\' {
			after := l.idx + 1
			if after < len(l.src) && l.src[after] == '\r' { after += 1 }
			if after < len(l.src) && l.src[after] == '\n' {
				strings.write_byte(&b, '\n')
				l.idx = after + 1
				l.line += 1
				continue
			}
		}
		strings.write_byte(&b, c)
		svt_advance(l)
	}
	def.body = strings.to_string(b)
	def.body_owned = true
	pp.ast.defines[macro] = def
	svt_skip_to_line_end(l)
}

// Raw text between balanced parentheses, split on top-level commas.
svpp_scan_macro_args :: proc(pp: ^SVPreprocessor) -> [dynamic]string {
	l := svpp_cur_tokenizer(pp)
	args := make([dynamic]string, pp.allocator)
	svt_skip_trivia(l)
	if svt_peek(l) != '(' { svpp_error(pp, "macro invocation requires an argument list") }
	svt_advance(l)
	svt_skip_trivia(l)
	if svt_peek(l) == ')' {
		svt_advance(l)
		return args
	}
	paren_depth := 0
	brace_depth := 0
	bracket_depth := 0
	arg_start := l.idx
	for {
		c := svt_peek(l)
		if svt_at_eof(l) { svpp_error(pp, "unterminated macro argument list") }
		if c == '"' {
			_ = svt_scan_string(l)
			continue
		}
		if c == '/' && svt_peek(l, 1) == '/' {
			for !svt_at_eof(l) && !svt_is_newline(svt_peek(l)) { svt_advance(l) }
			continue
		}
		if c == '/' && svt_peek(l, 1) == '*' {
			svt_advance(l, 2)
			for !svt_at_eof(l) && !(svt_peek(l) == '*' && svt_peek(l, 1) == '/') { svt_advance(l) }
			if svt_at_eof(l) { svpp_error(pp, "unterminated comment in macro arguments") }
			svt_advance(l, 2)
			continue
		}
		switch c {
		case '(': paren_depth += 1
		case ')':
			if paren_depth == 0 && brace_depth == 0 && bracket_depth == 0 {
				append(&args, strings.trim_space(string(l.src[arg_start:l.idx])))
				svt_advance(l)
				return args
			}
			paren_depth -= 1
		case '{': brace_depth += 1
		case '}': brace_depth -= 1
		case '[': bracket_depth += 1
		case ']': bracket_depth -= 1
		case ',': if paren_depth == 0 && brace_depth == 0 && bracket_depth == 0 {
					append(&args, strings.trim_space(string(l.src[arg_start:l.idx])))
					svt_advance(l)
					arg_start = l.idx
					continue
				}
		}
		svt_advance(l)
	}
}

// Substitute formal parameters and handle ``, `", and `\`" inside a replacement list.
svpp_expand_text :: proc(pp: ^SVPreprocessor, def: SVDefine, args: [dynamic]string, line: u32, path: string) -> string {
	body := def.body
	// The overwhelmingly common object-like macro with a literal body needs no
	// rewriting. Returning the stored body also lets svpp_push_text avoid a copy.
	if !def.is_function_like && strings.index_byte(body, '`') < 0 {
		return body if def.body_owned else strings.clone(body, pp.allocator) or_else panic("OOM")
	}
	b := strings.builder_make(pp.allocator)
	i := 0
	in_macro_string := false
	for i < len(body) {
		c := body[i]
		if c == '`' {
			if i + 3 < len(body) && body[i + 1] == '\\' && body[i + 2] == '`' && body[i + 3] == '"' {
				strings.write_string(&b, "\\\"")
				i += 4
				continue
			}
			if i + 1 < len(body) && body[i + 1] == '"' {
				strings.write_byte(&b, '"')
				in_macro_string = !in_macro_string
				i += 2
				continue
			}
			if i + 1 < len(body) && body[i + 1] == '`' {
				i += 2
				continue
			}
			// Inline the built-in file/line macros. This preserves implicit token pasting
			// such as `__foo`__LINE__`.
			line_end := i + 1 + len("__LINE__")
			if strings.has_prefix(body[i + 1:], "__LINE__") && (line_end >= len(body) || !svt_is_ident_char(body[line_end])) {
				strings.write_string(&b, fmt.aprintf("%d", line, allocator = pp.allocator))
				i = line_end
				continue
			}
			file_end := i + 1 + len("__FILE__")
			if strings.has_prefix(body[i + 1:], "__FILE__") && (file_end >= len(body) || !svt_is_ident_char(body[file_end])) {
				strings.write_byte(&b, '"')
				for c in path {
					if c == '\\' || c == '"' { strings.write_byte(&b, '\\') }
					strings.write_byte(&b, u8(c))
				}
				strings.write_byte(&b, '"')
				i = file_end
				continue
			}
			strings.write_byte(&b, '`')
			i += 1
			continue
		}
		if c == '"' && !in_macro_string {
			j := i + 1
			if i + 2 < len(body) && body[i + 1] == '"' && body[i + 2] == '"' {
				j = i + 3
				for j + 2 < len(body) {
					if body[j] == '"' && body[j + 1] == '"' && body[j + 2] == '"' {
						j += 3
						break
					}
					j += 1
				}
			} else {
				for j < len(body) {
					if body[j] == '\\' { j += 2; continue }
					j += 1
					if body[j - 1] == '"' { break }
				}
			}
			strings.write_string(&b, body[i:j])
			i = j
			continue
		}
		if def.is_function_like && (svt_is_ident_start(c) || c == '\\') {
			j := i + 1
			if c == '\\' {
				for j < len(body) {
					ch := body[j]
					if svt_is_space(ch) || svt_is_newline(ch) { break }
					j += 1
				}
			} else {
				for j < len(body) && svt_is_ident_char(body[j]) { j += 1 }
			}
			word := body[i:j]
			substituted := false
			for param, k in def.params {
				if param == word {
					if k < len(args) {
						strings.write_string(&b, args[k])
					} else if k < len(def.param_defaults) {
						strings.write_string(&b, def.param_defaults[k])
					}
					substituted = true
					break
				}
			}
			if !substituted { strings.write_string(&b, word) }
			i = j
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

svpp_expand_macro :: proc(pp: ^SVPreprocessor, name: string, tok: SVToken) {
	def, defined := pp.ast.defines[name]
	if !defined {
		svpp_error(pp, fmt.tprintf("Undefined macro `%s", name))
	}
	args: [dynamic]string
	if def.is_function_like {
		args = svpp_scan_macro_args(pp)
	}
	line := pp.sources[len(pp.sources) - 1].tokenizer.line
	text := svpp_expand_text(pp, def, args, line, pp.sources[len(pp.sources) - 1].path)
	svpp_push_text(pp, text, pp.sources[len(pp.sources) - 1].path, line)
}

// ---------------------------------------------------------------------------------------
// Includes and directive dispatch
// ---------------------------------------------------------------------------------------

svpp_resolve_include :: proc(pp: ^SVPreprocessor, include_path: string, current_file: string) -> string {
	if sv_path_is_absolute(include_path) { return strings.clone(include_path, pp.allocator) or_else panic("OOM") }
	dir := sv_path_directory(current_file)
	if len(dir) > 0 {
		candidate := fmt.tprintf("%s/%s", dir, include_path)
		if os.exists(candidate) { return strings.clone(candidate, pp.allocator) or_else panic("OOM") }
	} else if os.exists(include_path) {
		return strings.clone(include_path, pp.allocator) or_else panic("OOM")
	}
	for include_dir in pp.ast.include_dirs {
		candidate := fmt.tprintf("%s/%s", include_dir, include_path)
		if os.exists(candidate) { return strings.clone(candidate, pp.allocator) or_else panic("OOM") }
	}
	for file_dir in pp.ast.file_dirs {
		candidate := fmt.tprintf("%s/%s", file_dir, include_path)
		if os.exists(candidate) { return strings.clone(candidate, pp.allocator) or_else panic("OOM") }
	}
	base := sv_path_basename(include_path)
	for file_dir in pp.ast.file_dirs {
		candidate := fmt.tprintf("%s/%s", file_dir, base)
		if os.exists(candidate) { return strings.clone(candidate, pp.allocator) or_else panic("OOM") }
	}
	first := fmt.tprintf("%s/%s", dir, include_path) if len(dir) > 0 else include_path
	svpp_error(pp, fmt.tprintf("`include not found: %s (include_dirs searched too)", first))
}

svpp_handle_directive :: proc(pp: ^SVPreprocessor, tok: SVToken) {
	cur := svpp_cur_tokenizer(pp)
	name := svt_token_text(cur, tok)
	active := svpp_active(pp)

	switch name {
	case "define": if active { svpp_scan_define(pp) } else { svpp_skip_define_line(svpp_cur_tokenizer(pp)) }
	case "undef": if active {
				l := svpp_cur_tokenizer(pp)
				svt_skip_blank(l)
				macro := svt_scan_ident(l)
				if len(macro) > 0 { delete_key(&pp.ast.defines, macro) }
				svt_skip_to_line_end(l)
			} else { svt_skip_to_line_end(svpp_cur_tokenizer(pp)) }
	case "undefineall": if active { clear(&pp.ast.defines) }
	case "ifdef", "ifndef":
		l := svpp_cur_tokenizer(pp)
		svt_skip_blank(l)
		macro := svt_scan_ident(l)
		if len(macro) == 0 { svpp_error(pp, fmt.tprintf("`%s requires a macro name", name)) }
		defined := macro in pp.ast.defines
		cond := defined if name == "ifdef" else !defined
		parent := active
		branch := parent && cond
		append(&pp.cond_stack, SVCond{parent_active = parent, any_taken = branch, active = branch})
	case "elsif":
		if len(pp.cond_stack) == 0 { svpp_error(pp, "unexpected `elsif") }
		top := &pp.cond_stack[len(pp.cond_stack) - 1]
		l := svpp_cur_tokenizer(pp)
		branch := false
		if top.parent_active && !top.any_taken {
			svt_skip_blank(l)
			macro := svt_scan_ident(l)
			branch = macro in pp.ast.defines
		}
		top.active = top.parent_active && branch
		top.any_taken = top.any_taken || top.active
	case "else":
		if len(pp.cond_stack) == 0 { svpp_error(pp, "unexpected `else") }
		top := &pp.cond_stack[len(pp.cond_stack) - 1]
		top.active = top.parent_active && !top.any_taken
		top.any_taken = true
	case "endif":
		if len(pp.cond_stack) == 0 { svpp_error(pp, "unexpected `endif") }
		_ = pop(&pp.cond_stack)
	case "include":
		if !active { svt_skip_to_line_end(svpp_cur_tokenizer(pp)); return }
		l := svpp_cur_tokenizer(pp)
		svt_skip_blank(l)
		include_path: string
		if svt_peek(l) == '`' {
			svt_advance(l)
			svt_skip_blank(l)
			macro := svt_scan_ident(l)
			def, defined := pp.ast.defines[macro]
			if !defined { svpp_error(pp, fmt.tprintf("Undefined macro `%s used by `include", macro)) }
			include_path = strings.trim_space(def.body)
			if len(include_path) >= 2 && include_path[0] == '"' && include_path[len(include_path) - 1] == '"' {
				include_path = include_path[1:len(include_path) - 1]
			}
		} else {
			if svt_peek(l) != '"' { svpp_error(pp, "expected a quoted path after `include") }
			include_path = svt_scan_string(l)
		}
		path := svpp_resolve_include(pp, include_path, pp.sources[len(pp.sources) - 1].path)
		svpp_push_include(pp, path)
	case "timescale",
		 "default_nettype",
		 "celldefine",
		 "endcelldefine",
		 "pragma",
		 "resetall",
		 "line",
		 "begin_keywords",
		 "end_keywords",
		 "nounconnected_drive",
		 "unconnected_drive",
		 "default_decay_time",
		 "default_trireg_strength",
		 "delay_mode_distributed",
		 "delay_mode_path",
		 "delay_mode_unit",
		 "delay_mode_zero":
		svt_skip_to_line_end(svpp_cur_tokenizer(pp))
	case:
		// `__FILE__ and `__LINE__ are built-ins, not entries in the define table.
		if name == "__FILE__" {
			path := pp.sources[len(pp.sources) - 1].path
			b := strings.builder_make(pp.allocator)
			strings.write_byte(&b, '"')
			for c in path {
				if c == '\\' || c == '"' { strings.write_byte(&b, '\\') }
				strings.write_byte(&b, u8(c))
			}
			strings.write_byte(&b, '"')
			svpp_push_text(pp, strings.to_string(b), path, cur.line)
			return
		}
		if name == "__LINE__" {
			svpp_push_text(pp, fmt.aprintf("%d", cur.line, allocator = pp.allocator), pp.sources[len(pp.sources) - 1].path, cur.line)
			return
		}
		if !active { return }
		if name in pp.ast.defines {
			svpp_expand_macro(pp, name, tok)
			return
		}
		svpp_error(pp, fmt.tprintf("Unsupported compiler directive `%s", name))
	}
}

// Tokenize a file (and everything it includes/expands) into one flat array.
svpp_preprocess :: proc(pp: ^SVPreprocessor, data: []byte, filepath: string) -> []SVToken {
	old_allocator := context.allocator
	context.allocator = pp.allocator
	defer context.allocator = old_allocator

	// Large RTL files have roughly one token per ten source bytes. Reserving up
	// front avoids the repeated zero-and-copy growth of the token array.
	if len(pp.tokens) == 0 {
		non_zero_reserve(&pp.tokens, len(data) / 8 + 64)
	}
	file_id := svpp_add_file(pp, data, filepath)
	frame := SVPPFrame {
		tokenizer = svt_init(data, file_id),
		path      = filepath,
	}
	frame.tokenizer.comment_sink = &pp.ast.comments
	frame.tokenizer.path = filepath
	append(&pp.sources, frame)
	for len(pp.sources) > 0 {
		top := &pp.sources[len(pp.sources) - 1]
		t := svt_next(&top.tokenizer)
		if t.kind == .EOF {
			_ = pop(&pp.sources)
			if pp.total_depth > 0 { pp.total_depth -= 1 }
			continue
		}
		if t.kind == .Directive {
			svpp_handle_directive(pp, t)
			continue
		}
		if !svpp_active(pp) { continue }
		append(&pp.tokens, t)
	}
	ensure(len(pp.cond_stack) == 0, "Unterminated `ifdef/`ifndef at end of file")
	// Give the parser a few EOF sentinels so lookahead never needs a bounds check.
	for _ in 0 ..< 4 { append(&pp.tokens, SVToken{kind = .EOF}) }
	return pp.tokens[:]
}
