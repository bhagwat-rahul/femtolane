/*
Fast, allocation-free SystemVerilog tokenizer and preprocessing token stream.

The parser never looks at raw bytes: this layer skips whitespace/comments, maps
identifiers to keyword enum values through a small open-addressed table, and
emits source-slice tokens. Compiler directives and macro expansion are handled
by the preprocessor in system_verilog_preprocessor.odin, which feeds a flat
token array to the parser.

Token layout is 10 bytes: 32-bit source offset, 16-bit length, 16-bit source id,
token kind and a one-byte keyword id. Text is materialized from the source buffer
only when the parser or preprocessor needs it, so the token stream is compact and
cache-friendly. Numbers are decoded once
when they become AST nodes, not during the scan; the source slice keeps every
literal lossless.
*/

package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:simd"

SVTokenKind :: enum u8 {
	Invalid,
	EOF,
	Ident,
	EscapedIdent,
	SystemIdent,
	Number,
	String,
	Directive, // `name (compiler directive or macro invocation)
	Backtick, // lone ` (macro token pasting)
	LParen,
	RParen,
	LBracket,
	RBracket,
	LBrace,
	RBrace,
	Comma,
	Semicolon,
	Colon,
	ColonColon,
	Dot,
	DotStar,
	Hash,
	At,
	Tick,
	Question,
	AttrStart, // (*
	AttrEnd, // *)
	Assign,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Pow,
	Amp,
	Pipe,
	Caret,
	Tilde,
	Bang,
	Lt,
	Gt,
	Le,
	Ge,
	EqEq,
	NotEq,
	CaseEq,
	CaseNeq,
	WildEq,
	WildNeq,
	Shl,
	Shr,
	Ashl,
	Ashr,
	AmpAmp,
	PipePipe,
	Inc,
	Dec,
	PlusEq,
	MinusEq,
	StarEq,
	SlashEq,
	PercentEq,
	AmpEq,
	PipeEq,
	CaretEq,
	ShlEq,
	ShrEq,
	AshlEq,
	AshrEq,
	PlusColon,
	MinusColon,
	Arrow,
	FatArrow,
	StarGt,
	PipeArrow,
	PipeFatArrow,
	HashHash,
	TildeAmp,
	TildePipe,
	CaretTilde,
	TildeCaret,
}

SVToken :: struct #packed {
	off:  u32, // byte offset into the source selected by `file`
	len:  u16,
	file: u16,
	kind: SVTokenKind,
	kw:   SVKeyword,
}

SVTokenizer :: struct {
	src:          []byte,
	idx:          int,
	line:         u32,
	file_id:      u16,
	comment_sink: ^[dynamic]SVComment,
	path:         string,
}

svt_init :: #force_inline proc(src: []byte, file_id: u16) -> SVTokenizer {
	return SVTokenizer{src = src, line = 1, file_id = file_id}
}

svt_peek :: #force_inline proc(l: ^SVTokenizer, offset := 0) -> byte {
	i := l.idx + offset
	return l.src[i] if i < len(l.src) else 0
}

svt_advance :: #force_inline proc(l: ^SVTokenizer, n := 1) {
	for _ in 0 ..< n {
		if l.idx >= len(l.src) { return }
		if l.src[l.idx] == '\n' { l.line += 1 }
		l.idx += 1
	}
}

svt_error :: proc(l: ^SVTokenizer, msg: string) -> ! {
	panic(fmt.tprintf("SystemVerilog tokenizer error at line %d: %s", l.line, msg))
}

svt_at_eof :: #force_inline proc(l: ^SVTokenizer) -> bool { return l.idx >= len(l.src) }

svt_is_space :: #force_inline proc(c: byte) -> bool { return c == ' ' || c == '\t' || c == '\v' || c == '\f' }
svt_is_newline :: #force_inline proc(c: byte) -> bool { return c == '\n' || c == '\r' }
svt_is_digit :: #force_inline proc "contextless" (c: byte) -> bool { return c >= '0' && c <= '9' }
svt_is_ident_start :: #force_inline proc "contextless" (c: byte) -> bool { return c == '_' || (c | 0x20) >= 'a' && (c | 0x20) <= 'z' }
svt_is_ident_char :: #force_inline proc "contextless" (c: byte) -> bool {return(
		c == '_' ||
		c == '$' ||
		(c | 0x20) >= 'a' && (c | 0x20) <= 'z' ||
		(c >= '0' && c <= '9') \
	)}

svt_ident_char_lut: [256]bool
svt_simple_token_lut: [256]SVTokenKind

SV_IDENT_LANES :: 16
sv_simd_lower: simd.u8x16 = {0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20}
sv_simd_a: simd.u8x16 = {'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a'}
sv_simd_z: simd.u8x16 = {'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z', 'z'}
sv_simd_0: simd.u8x16 = {'0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0'}
sv_simd_9: simd.u8x16 = {'9', '9', '9', '9', '9', '9', '9', '9', '9', '9', '9', '9', '9', '9', '9', '9'}
sv_simd_us: simd.u8x16 = {'_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_', '_'}
sv_simd_dollar: simd.u8x16 = {'$', '$', '$', '$', '$', '$', '$', '$', '$', '$', '$', '$', '$', '$', '$', '$'}

@(init)
svt_lut_init :: proc "contextless" () {
	for i in 0 ..< 256 {
		c := u8(i)
		svt_ident_char_lut[i] = svt_is_ident_char(c)
	}
	svt_simple_token_lut[')'] = .RParen
	svt_simple_token_lut[']'] = .RBracket
	svt_simple_token_lut['}'] = .RBrace
	svt_simple_token_lut[','] = .Comma
	svt_simple_token_lut[';'] = .Semicolon
	svt_simple_token_lut['['] = .LBracket
	svt_simple_token_lut['{'] = .LBrace
	svt_simple_token_lut['@'] = .At
	svt_simple_token_lut['?'] = .Question
}
svt_is_base_char :: #force_inline proc(c: byte) -> bool {return(
		c == 'b' ||
		c == 'B' ||
		c == 'o' ||
		c == 'O' ||
		c == 'd' ||
		c == 'D' ||
		c == 'h' ||
		c == 'H' \
	)}

svt_record_comment :: #force_inline proc(l: ^SVTokenizer, start, end: int, line: u32, is_block: bool) {
	if l.comment_sink == nil { return }
	append(l.comment_sink, SVComment{text = string(l.src[start:end]), path = l.path, line = line, is_block = is_block})
}

svt_skip_comment :: #force_no_inline proc(l: ^SVTokenizer, start: int) -> int {
	src := l.src
	n := len(src)
	i := start
	start_line := l.line
	if src[i + 1] == '/' {
		i += 2
		for i < n && src[i] != '\n' && src[i] != '\r' { i += 1 }
		svt_record_comment(l, start, i, start_line, false)
		return i
	}

	i += 2
	content_start := i
	for i + 1 < n && !(src[i] == '*' && src[i + 1] == '/') { i += 1 }
	if i + 1 >= n {
		for j in content_start ..< i {
			if src[j] == '\n' { l.line += 1 }
		}
		l.idx = i
		svt_error(l, "unterminated block comment")
	}
	for j in content_start ..< i {
		if src[j] == '\n' { l.line += 1 }
	}
	i += 2
	svt_record_comment(l, start, i, start_line, true)
	return i
}

svt_skip_trivia :: #force_inline proc(l: ^SVTokenizer) {
	#no_bounds_check {
		src := l.src
		n := len(src)
		i := l.idx
		for i < n {
			c := src[i]
			switch {
			case c == ' ' || c == '\t' || c == '\v' || c == '\f':
				i += 1
				// Indentation is usually a run of spaces. Check eight at a time and
				// locate the first non-space with the standard per-byte zero mask.
				for i + 8 <= n && src[i] == ' ' {
					v := intrinsics.unaligned_load((^u64)(&src[i]))
					x := v ~ u64(0x2020202020202020)
					t := ((x & 0x7f7f7f7f7f7f7f7f) + 0x7f7f7f7f7f7f7f7f)
					nz := (t | x) & 0x8080808080808080
					if nz == 0 {
						i += 8
						continue
					}
					i += int(intrinsics.count_trailing_zeros(nz)) >> 3
					break
				}
				for i < n && (src[i] == ' ' || src[i] == '\t' || src[i] == '\v' || src[i] == '\f') { i += 1 }
			case c == '\r': // CRLF/CL counts as one line: only '\n' increments the line counter.
					i += 1
			case c == '\n':
				l.line += 1
				i += 1
			case c == '/' && i + 1 < n && (src[i + 1] == '/' || src[i + 1] == '*'): i = svt_skip_comment(l, i)
			case:
				l.idx = i
				return
			}
		}
		l.idx = i

	}}

// Identifier text after a backslash, up to whitespace (escaped identifiers include
// punctuation and are never keywords).
svt_scan_escaped_ident :: proc(l: ^SVTokenizer) -> string {
	src := l.src
	n := len(src)
	start := l.idx + 1 // skip backslash
	i := start
	for i < n {
		c := src[i]
		if svt_is_space(c) || svt_is_newline(c) { break }
		i += 1
	}
	l.idx = i
	return string(src[start:i])
}

svt_scan_ident :: #force_inline proc(l: ^SVTokenizer) -> string {
	#no_bounds_check {
		src := l.src
		n := len(src)
		start := l.idx
		i := start
		when simd.HAS_HARDWARE_SIMD {
			for i + SV_IDENT_LANES <= n {
				#no_bounds_check v := intrinsics.unaligned_load((^simd.u8x16)(&src[i]))
				lower := v | sv_simd_lower
				is_alpha := simd.lanes_ge(lower, sv_simd_a) & simd.lanes_le(lower, sv_simd_z)
				is_digit := simd.lanes_ge(v, sv_simd_0) & simd.lanes_le(v, sv_simd_9)
				is_us := simd.lanes_eq(v, sv_simd_us) | simd.lanes_eq(v, sv_simd_dollar)
				bits := transmute(u16)(simd.extract_msbs(is_alpha | is_digit | is_us))
				if bits == 0xFFFF {
					i += SV_IDENT_LANES
					continue
				}
				i += int(intrinsics.count_trailing_zeros(~bits))
				l.idx = i
				return string(src[start:i])
			}
		}
		for i < n && svt_ident_char_lut[src[i]] { i += 1 }
		l.idx = i
		return string(src[start:i])

	}}

svt_scan_string :: proc(l: ^SVTokenizer) -> string {
	src := l.src
	n := len(src)
	// Triple-quoted string literal: """ ... """
	if l.idx + 2 < n && src[l.idx] == '"' && src[l.idx + 1] == '"' && src[l.idx + 2] == '"' {
		i := l.idx + 3
		start := i
		for i < n {
			if i + 2 < n && src[i] == '"' && src[i + 1] == '"' && src[i + 2] == '"' {
				text := string(src[start:i])
				l.idx = i + 3
				return text
			}
			if src[i] == '\\' {
				if i + 1 < n && src[i + 1] == '\n' { l.line += 1 }
				i += 2
			} else {
				if src[i] == '\n' { l.line += 1 }
				i += 1
			}
		}
		l.idx = i
		svt_error(l, "unterminated triple-quoted string literal")
	}
	i := l.idx + 1 // opening quote
	start := i
	for i < n {
		c := src[i]
		if c == '\\' {
			if i + 1 < n && src[i + 1] == '\n' { l.line += 1 }
			i += 2
			continue
		}
		if c == '"' { break }
		if svt_is_newline(c) {
			l.idx = i
			svt_error(l, "unterminated string literal")
		}
		i += 1
	}
	if i >= n { l.idx = i; svt_error(l, "unterminated string literal") }
	text := string(src[start:i])
	l.idx = i + 1
	return text
}

svt_scan_based_body :: #force_inline proc(l: ^SVTokenizer, start, i_in: int) -> string {
	i := i_in
	src := l.src
	n := len(src)
	for i < n && (src[i] == ' ' || src[i] == '\t') { i += 1 }
	for i < n && sv_digit_value_lut[src[i]] != 255 { i += 1 }
	l.idx = i
	return string(src[start:i])
}

// Numbers are one token, including a based literal's base and any time-unit suffix.
// Raw text is preserved; decoding happens when the token becomes an SVNumber.
svt_scan_number :: #force_inline proc(l: ^SVTokenizer) -> string {
	#no_bounds_check {
		src := l.src
		n := len(src)
		start := l.idx
		i := start
		if src[i] == '\'' {
			// Unsized based literal ('hFF) or unbased literal ('0/'1/'x/'z).
			i += 1
			if i < n && (src[i] == 's' || src[i] == 'S') { i += 1 }
			if i < n && svt_is_base_char(src[i]) {
				i += 1
				return svt_scan_based_body(l, start, i)
			}
			if i < n {
				c := src[i]
				if c == '0' || c == '1' || c == 'x' || c == 'X' || c == 'z' || c == 'Z' || c == '?' { i += 1 }
			}
			l.idx = i
			return string(src[start:i])
		}

		// Fast path: a plain decimal integer followed by a byte that cannot extend the
		// literal. This is the common case for indices, replication counts and delays.
		for i < n && svt_is_digit(src[i]) { i += 1 }
		if i >= n || (src[i] != '_' && src[i] != '\'' && src[i] != '.' && src[i] != 'e' && src[i] != 'E' && !svt_is_ident_char(src[i])) {
			l.idx = i
			return string(src[start:i])
		}
		i = start
		for i < n && (svt_is_digit(src[i]) || src[i] == '_') { i += 1 }
		if i + 1 < n && src[i] == '.' && svt_is_digit(src[i + 1]) {
			i += 1
			for i < n && (svt_is_digit(src[i]) || src[i] == '_') { i += 1 }
		}
		if i + 1 < n &&
		   (src[i] == 'e' || src[i] == 'E') &&
		   (svt_is_digit(src[i + 1]) || (i + 2 < n && (src[i + 1] == '+' || src[i + 1] == '-') && svt_is_digit(src[i + 2]))) {
			i += 1
			if i < n && (src[i] == '+' || src[i] == '-') { i += 1 }
			for i < n && (svt_is_digit(src[i]) || src[i] == '_') { i += 1 }
		}

		// Sized based literal: 12'hFF, 8'sd10. A macro-expanded size is handled by the
		// parser by joining adjacent number tokens.
		if i + 1 < n && src[i] == '\'' {
			if (src[i + 1] == 's' || src[i + 1] == 'S') && i + 2 < n && svt_is_base_char(src[i + 2]) {
				i += 3 // ' s base
				return svt_scan_based_body(l, start, i)
			}
			if svt_is_base_char(src[i + 1]) {
				i += 2 // ' base
				return svt_scan_based_body(l, start, i)
			}
		}

		// Optional time unit suffix (s, ms, us, ns, ps, fs), no whitespace between.
		unit_start := i
		for i < n && svt_ident_char_lut[src[i]] { i += 1 }
		unit := string(src[unit_start:i])
		if len(unit) == 0 { l.idx = i; return string(src[start:i]) }
		switch unit {
		case "s", "ms", "us", "ns", "ps", "fs":
		// keep it in the token
		case: i = unit_start
		}
		l.idx = i
		return string(src[start:i])

	}}


svt_scan_directive :: proc(l: ^SVTokenizer) -> SVToken {
	start := l.idx
	svt_advance(l) // backtick
	if !svt_is_ident_start(svt_peek(l)) {
		return SVToken{off = u32(start), len = 1, file = l.file_id, kind = .Backtick}
	}
	svt_scan_ident(l)
	return SVToken{off = u32(start + 1), len = u16(l.idx - start - 1), file = l.file_id, kind = .Directive}
}

svt_check_token_len :: #force_inline proc(l: ^SVTokenizer, text: string) {
	if len(text) > 0xFFFF { svt_error(l, "token too long") }
}

svt_token_text :: #force_inline proc(l: ^SVTokenizer, t: SVToken) -> string {
	#no_bounds_check return string(l.src[t.off:t.off + u32(t.len)])
}

svt_op1 :: #force_inline proc(l: ^SVTokenizer, start: int, kind: SVTokenKind) -> SVToken {
	svt_advance(l)
	return SVToken{off = u32(start), len = 1, file = l.file_id, kind = kind}
}

svt_op2 :: #force_inline proc(l: ^SVTokenizer, start: int, kind: SVTokenKind) -> SVToken {
	svt_advance(l, 2)
	return SVToken{off = u32(start), len = 2, file = l.file_id, kind = kind}
}

svt_op3 :: #force_inline proc(l: ^SVTokenizer, start: int, kind: SVTokenKind) -> SVToken {
	svt_advance(l, 3)
	return SVToken{off = u32(start), len = 3, file = l.file_id, kind = kind}
}

svt_op4 :: #force_inline proc(l: ^SVTokenizer, start: int, kind: SVTokenKind) -> SVToken {
	svt_advance(l, 4)
	return SVToken{off = u32(start), len = 4, file = l.file_id, kind = kind}
}

svt_next :: #force_inline proc(l: ^SVTokenizer) -> SVToken {
	svt_skip_trivia(l)
	start := l.idx
	if svt_at_eof(l) {
		return SVToken{kind = .EOF}
	}

	c := svt_peek(l)

	// Most punctuation is a fixed single-character token. Testing the table first
	// avoids the longer identifier/number/string dispatch chain for those tokens.
	simple := svt_simple_token_lut[c]
	if simple != .Invalid { return svt_op1(l, start, simple) }

	switch {
	case c == '\\':
		text := svt_scan_escaped_ident(l)
		svt_check_token_len(l, text)
		return SVToken{off = u32(start + 1), len = u16(len(text)), file = l.file_id, kind = .EscapedIdent}
	case svt_is_ident_start(c):
		text := svt_scan_ident(l)
		svt_check_token_len(l, text)
		return SVToken{off = u32(start), len = u16(len(text)), file = l.file_id, kind = .Ident, kw = svt_keyword_lookup(text)}
	case c == '$':
		svt_advance(l)
		_ = svt_scan_ident(l)
		return SVToken{off = u32(start), len = u16(l.idx - start), file = l.file_id, kind = .SystemIdent}
	case svt_is_digit(c):
		text := svt_scan_number(l)
		svt_check_token_len(l, text)
		return SVToken{off = u32(start), len = u16(len(text)), file = l.file_id, kind = .Number}
	case c == '\'':
		if svt_is_base_char(svt_peek(l, 1)) ||
		   ((svt_peek(l, 1) == 's' || svt_peek(l, 1) == 'S') && svt_is_base_char(svt_peek(l, 2))) ||
		   svt_is_digit(svt_peek(l, 1)) ||
		   svt_peek(l, 1) == '0' ||
		   svt_peek(l, 1) == '1' ||
		   svt_peek(l, 1) == 'x' ||
		   svt_peek(l, 1) == 'X' ||
		   svt_peek(l, 1) == 'z' ||
		   svt_peek(l, 1) == 'Z' {
			text := svt_scan_number(l)
			svt_check_token_len(l, text)
			return SVToken{off = u32(start), len = u16(len(text)), file = l.file_id, kind = .Number}
		}
		svt_advance(l)
		return SVToken{off = u32(start), len = 1, file = l.file_id, kind = .Tick}
	case c == '"':
		triple := svt_peek(l, 1) == '"' && svt_peek(l, 2) == '"'
		text := svt_scan_string(l)
		if len(text) > 0xFFFF { svt_error(l, "string literal too long") }
		quote_len := 3 if triple else 1
		return SVToken{off = u32(start + quote_len), len = u16(len(text)), file = l.file_id, kind = .String}
	case c == '`': return svt_scan_directive(l)
	}

	// Operators and punctuation.
	switch c {
	case '(':
		if svt_peek(l, 1) == '*' { return svt_op2(l, start, .AttrStart) }
		return svt_op1(l, start, .LParen)
	case ')': return svt_op1(l, start, .RParen)
	case '[': return svt_op1(l, start, .LBracket)
	case ']': return svt_op1(l, start, .RBracket)
	case '{': return svt_op1(l, start, .LBrace)
	case '}': return svt_op1(l, start, .RBrace)
	case ',': return svt_op1(l, start, .Comma)
	case ';': return svt_op1(l, start, .Semicolon)
	case ':':
		if svt_peek(l, 1) == ':' { return svt_op2(l, start, .ColonColon) }
		return svt_op1(l, start, .Colon)
	case '.':
		if svt_peek(l, 1) == '*' { return svt_op2(l, start, .DotStar) }
		return svt_op1(l, start, .Dot)
	case '#':
		if svt_peek(l, 1) == '#' { return svt_op2(l, start, .HashHash) }
		return svt_op1(l, start, .Hash)
	case '@': return svt_op1(l, start, .At)
	case '?': return svt_op1(l, start, .Question)
	case '=':
		if svt_peek(l, 1) == '=' {
			if svt_peek(l, 2) == '=' { return svt_op3(l, start, .CaseEq) }
			if svt_peek(l, 2) == '?' { return svt_op3(l, start, .WildEq) }
			return svt_op2(l, start, .EqEq)
		}
		if svt_peek(l, 1) == '>' { return svt_op2(l, start, .FatArrow) }
		return svt_op1(l, start, .Assign)
	case '!':
		if svt_peek(l, 1) == '=' {
			if svt_peek(l, 2) == '=' { return svt_op3(l, start, .CaseNeq) }
			if svt_peek(l, 2) == '?' { return svt_op3(l, start, .WildNeq) }
			return svt_op2(l, start, .NotEq)
		}
		return svt_op1(l, start, .Bang)
	case '+':
		switch svt_peek(l, 1) {
		case '+': return svt_op2(l, start, .Inc)
		case '=': return svt_op2(l, start, .PlusEq)
		case ':': return svt_op2(l, start, .PlusColon)
		}
		return svt_op1(l, start, .Plus)
	case '-':
		switch svt_peek(l, 1) {
		case '-': return svt_op2(l, start, .Dec)
		case '=': return svt_op2(l, start, .MinusEq)
		case ':': return svt_op2(l, start, .MinusColon)
		case '>': return svt_op2(l, start, .Arrow)
		}
		return svt_op1(l, start, .Minus)
	case '*':
		if svt_peek(l, 1) == ')' { return svt_op2(l, start, .AttrEnd) }
		if svt_peek(l, 1) == '*' { return svt_op2(l, start, .Pow) }
		if svt_peek(l, 1) == '>' { return svt_op2(l, start, .StarGt) }
		if svt_peek(l, 1) == '=' { return svt_op2(l, start, .StarEq) }
		return svt_op1(l, start, .Star)
	case '/':
		if svt_peek(l, 1) == '=' { return svt_op2(l, start, .SlashEq) }
		return svt_op1(l, start, .Slash)
	case '%':
		if svt_peek(l, 1) == '=' { return svt_op2(l, start, .PercentEq) }
		return svt_op1(l, start, .Percent)
	case '&':
		if svt_peek(l, 1) == '&' { return svt_op2(l, start, .AmpAmp) }
		if svt_peek(l, 1) == '=' { return svt_op2(l, start, .AmpEq) }
		return svt_op1(l, start, .Amp)
	case '|':
		if svt_peek(l, 1) == '|' { return svt_op2(l, start, .PipePipe) }
		if svt_peek(l, 1) == '-' && svt_peek(l, 2) == '>' { return svt_op3(l, start, .PipeArrow) }
		if svt_peek(l, 1) == '=' && svt_peek(l, 2) == '>' { return svt_op3(l, start, .PipeFatArrow) }
		if svt_peek(l, 1) == '=' { return svt_op2(l, start, .PipeEq) }
		return svt_op1(l, start, .Pipe)
	case '^':
		if svt_peek(l, 1) == '~' { return svt_op2(l, start, .CaretTilde) }
		if svt_peek(l, 1) == '=' { return svt_op2(l, start, .CaretEq) }
		return svt_op1(l, start, .Caret)
	case '~':
		switch svt_peek(l, 1) {
		case '^': return svt_op2(l, start, .TildeCaret)
		case '&': return svt_op2(l, start, .TildeAmp)
		case '|': return svt_op2(l, start, .TildePipe)
		}
		return svt_op1(l, start, .Tilde)
	case '<':
		switch svt_peek(l, 1) {
		case '<':
			if svt_peek(l, 2) == '<' {
				if svt_peek(l, 3) == '=' { return svt_op4(l, start, .AshlEq) }
				return svt_op3(l, start, .Ashl)
			}
			if svt_peek(l, 2) == '=' { return svt_op3(l, start, .ShlEq) }
			return svt_op2(l, start, .Shl)
		case '=': return svt_op2(l, start, .Le)
		}
		return svt_op1(l, start, .Lt)
	case '>':
		switch svt_peek(l, 1) {
		case '>':
			if svt_peek(l, 2) == '>' {
				if svt_peek(l, 3) == '=' { return svt_op4(l, start, .AshrEq) }
				return svt_op3(l, start, .Ashr)
			}
			if svt_peek(l, 2) == '=' { return svt_op3(l, start, .ShrEq) }
			return svt_op2(l, start, .Shr)
		case '=': return svt_op2(l, start, .Ge)
		}
		return svt_op1(l, start, .Gt)
	}
	svt_error(l, fmt.tprintf("unexpected character '%r'", c))
}

// ---------------------------------------------------------------------------------------
// Keyword table: one lookup per identifier, no string switches in the parser.
// ---------------------------------------------------------------------------------------

SVKeyword_LUT_Size :: 2048
SVKeyword_LUT_Mask :: SVKeyword_LUT_Size - 1

SVKeyword_LUT_Entry :: struct {
	hash:    u32,
	keyword: SVKeyword,
	name:    string,
}

sv_keyword_lut: [SVKeyword_LUT_Size]SVKeyword_LUT_Entry
sv_keyword_lens: [26]u32 // bit N set when a keyword of length N starts with this letter
sv_keyword_names: [SVKeyword]string
sv_keyword_name_buf: [8192]u8
sv_keyword_name_off: int
sv_keyword_max_len :: 19

sv_keyword_hash :: #force_inline proc "contextless" (text: string) -> u32 {
	// Keywords are a small, fixed set. Length, first, last and third bytes give an
	// even spread in the 2048-entry table without scanning the whole identifier.
	n := len(text)
	h := u32(n) * 0x9e3779b1
	h = (h ~ u32(text[0])) * 0x85ebca6b
	h = (h ~ u32(text[n - 1])) * 0xc2b2ae35
	if n > 3 {
		h = (h ~ (u32(text[2]) << 8)) * 0x27d4eb2f
	}
	return h
}

// The enum fields are CamelCase and the language spelling is the same name in
// snake_case (SAlways -> s_always, Highz0 -> highz0), so the lookup table can be
// generated from the enum's type information instead of being spelled out twice.
sv_keyword_spelling :: proc "contextless" (name: string) -> string {
	start := sv_keyword_name_off
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 'A' && c <= 'Z' {
			prev: byte
			if i > 0 { prev = name[i - 1] }
			next: byte
			if i + 1 < len(name) { next = name[i + 1] }
			if i > 0 && (prev >= 'a' && prev <= 'z' || prev >= '0' && prev <= '9' || (prev >= 'A' && prev <= 'Z' && next >= 'a' && next <= 'z')) {
				sv_keyword_name_buf[sv_keyword_name_off] = '_'
				sv_keyword_name_off += 1
			}
			c += 'a' - 'A'
		}
		sv_keyword_name_buf[sv_keyword_name_off] = c
		sv_keyword_name_off += 1
	}
	return string(sv_keyword_name_buf[start:sv_keyword_name_off])
}

sv_enum_field_names :: #force_inline proc "contextless" (T: typeid) -> []string {
	ti := runtime.type_info_base(type_info_of(T))
	if e, ok := ti.variant.(^runtime.Type_Info_Enum); ok { return e.names }
	return nil
}

@(init)
sv_keyword_lut_init :: proc "contextless" () {
	sv_keyword_names[.None] = "identifier"
	for name, vi in sv_enum_field_names(SVKeyword) {
		kw := SVKeyword(vi)
		if kw == .None { continue }
		spelling := sv_keyword_spelling(name)
		sv_keyword_names[kw] = spelling
		h := sv_keyword_hash(spelling)
		idx := int(h) & SVKeyword_LUT_Mask
		for sv_keyword_lut[idx].name != "" { idx = (idx + 1) & SVKeyword_LUT_Mask }
		sv_keyword_lut[idx] = SVKeyword_LUT_Entry {
			hash    = h,
			keyword = kw,
			name    = spelling,
		}
		c := spelling[0]
		if c >= 'a' && c <= 'z' {
			sv_keyword_lens[c - 'a'] |= 1 << uint(len(spelling))
		}
	}
}

svt_keyword_lookup :: #force_inline proc(text: string) -> SVKeyword {
	n := len(text)
	if n < 2 || n > sv_keyword_max_len { return .None }
	c := text[0]
	if c < 'a' || c > 'z' { return .None }
	if (sv_keyword_lens[c - 'a'] >> uint(n)) & 1 == 0 { return .None }
	h := sv_keyword_hash(text)
	i := int(h) & SVKeyword_LUT_Mask
	for {
		e := &sv_keyword_lut[i]
		if e.name == "" { return .None }
		if e.hash == h && e.name == text { return e.keyword }
		i = (i + 1) & SVKeyword_LUT_Mask
	}
}

// Keyword spelling for diagnostics; the token's text is usually enough, but tests and
// error messages sometimes have only a keyword value.
sv_keyword_name :: proc(kw: SVKeyword) -> string {
	return sv_keyword_names[kw]
}

// ---------------------------------------------------------------------------------------
// The keyword table (IEEE 1800-2023 Annex B), generated from the language keyword list.
// Kept in enum('s) numerical order so it can double as a name table.
// ---------------------------------------------------------------------------------------

SVKeyword :: enum u8 {
	None,
	AcceptOn,
	Alias,
	Always,
	AlwaysComb,
	AlwaysFf,
	AlwaysLatch,
	And,
	Assert,
	Assign,
	Assume,
	Automatic,
	Before,
	Begin,
	Bind,
	Bins,
	Binsof,
	Bit,
	Break,
	Buf,
	Bufif0,
	Bufif1,
	Byte,
	Case,
	Casex,
	Casez,
	Cell,
	Chandle,
	Checker,
	Class,
	Clocking,
	Cmos,
	Config,
	Const,
	Constraint,
	Context,
	Continue,
	Cover,
	Covergroup,
	Coverpoint,
	Cross,
	Deassign,
	Default,
	Defparam,
	Design,
	Disable,
	Dist,
	Do,
	Edge,
	Else,
	End,
	Endcase,
	Endchecker,
	Endclass,
	Endclocking,
	Endconfig,
	Endfunction,
	Endgenerate,
	Endgroup,
	Endinterface,
	Endmodule,
	Endpackage,
	Endprimitive,
	Endprogram,
	Endproperty,
	Endspecify,
	Endsequence,
	Endtable,
	Endtask,
	Enum,
	Event,
	Eventually,
	Expect,
	Export,
	Extends,
	Extern,
	Final,
	FirstMatch,
	For,
	Force,
	Foreach,
	Forever,
	Fork,
	Forkjoin,
	Function,
	Generate,
	Genvar,
	Global,
	Highz0,
	Highz1,
	If,
	Iff,
	Ifnone,
	IgnoreBins,
	IllegalBins,
	Implements,
	Implies,
	Import,
	Incdir,
	Include,
	Initial,
	Inout,
	Input,
	Inside,
	Instance,
	Int,
	Integer,
	Interconnect,
	Interface,
	Intersect,
	Join,
	JoinAny,
	JoinNone,
	Large,
	Let,
	Liblist,
	Library,
	Local,
	Localparam,
	Logic,
	Longint,
	Macromodule,
	Matches,
	Medium,
	Modport,
	Module,
	Nand,
	Negedge,
	Nettype,
	New,
	Nexttime,
	Nmos,
	Nor,
	Noshowcancelled,
	Not,
	Notif0,
	Notif1,
	Null,
	Or,
	Output,
	Package,
	Packed,
	Parameter,
	Pmos,
	Posedge,
	Primitive,
	Priority,
	Program,
	Property,
	Protected,
	Pull0,
	Pull1,
	Pulldown,
	Pullup,
	PulsestyleOndetect,
	PulsestyleOnevent,
	Pure,
	Rand,
	Randc,
	Randcase,
	Randsequence,
	Rcmos,
	Real,
	Realtime,
	Ref,
	Reg,
	RejectOn,
	Release,
	Repeat,
	Restrict,
	Return,
	Rnmos,
	Rpmos,
	Rtran,
	Rtranif0,
	Rtranif1,
	SAlways,
	SEventually,
	SNexttime,
	SUntil,
	SUntilWith,
	Scalared,
	Sequence,
	Shortint,
	Shortreal,
	Showcancelled,
	Signed,
	Small,
	Soft,
	Solve,
	Specify,
	Specparam,
	Static,
	String,
	Strong,
	Strong0,
	Strong1,
	Struct,
	Super,
	Supply0,
	Supply1,
	SyncAcceptOn,
	SyncRejectOn,
	Table,
	Tagged,
	Task,
	This,
	Throughout,
	Time,
	Timeprecision,
	Timeunit,
	Tran,
	Tranif0,
	Tranif1,
	Tri,
	Tri0,
	Tri1,
	Triand,
	Trior,
	Trireg,
	Type,
	Typedef,
	Union,
	Unique,
	Unique0,
	Unsigned,
	Until,
	UntilWith,
	Untyped,
	Use,
	Uwire,
	Var,
	Vectored,
	Virtual,
	Void,
	Wait,
	WaitOrder,
	Wand,
	Weak,
	Weak0,
	Weak1,
	While,
	Wildcard,
	Wire,
	With,
	Within,
	Wor,
	Xnor,
	Xor,
}


svt_skip_to_line_end :: proc(l: ^SVTokenizer) {
	src := l.src
	n := len(src)
	i := l.idx
	for i < n && !svt_is_newline(src[i]) { i += 1 }
	l.idx = i
}

svt_skip_blank :: #force_inline proc(l: ^SVTokenizer) {
	src := l.src
	n := len(src)
	i := l.idx
	for i < n && (src[i] == ' ' || src[i] == '\t') { i += 1 }
	l.idx = i
}
