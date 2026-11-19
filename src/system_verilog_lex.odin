/*
Fast, allocation-free SystemVerilog lexer and preprocessing token stream.

The parser never looks at raw bytes: this layer skips whitespace/comments, maps
identifiers to keyword enum values through a small open-addressed table, and
emits source-slice tokens. Compiler directives and macro expansion are handled
by the preprocessor in system_verilog_pp.odin, which feeds a flat token array to
the parser.

Token layout is deliberately small (kind/keyword/file/line/position + text
slice). Numbers are decoded once when they become AST nodes, not during the
scan; the text slice keeps every literal lossless.
*/

package main

import "core:fmt"
import "core:strconv"
import "core:strings"

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

SVToken :: struct {
	kind: SVTokenKind,
	kw:   SVKeyword,
	line: u32,
	text: string,
}

SVLexer :: struct {
	src:     []byte,
	idx:     int,
	line:    u32,
	file_id: u16,
}

svl_init :: #force_inline proc(src: []byte, file_id: u16) -> SVLexer {
	return SVLexer{src = src, line = 1, file_id = file_id}
}

svl_peek :: #force_inline proc(l: ^SVLexer, offset := 0) -> byte {
	i := l.idx + offset
	return l.src[i] if i < len(l.src) else 0
}

svl_advance :: #force_inline proc(l: ^SVLexer, n := 1) {
	for _ in 0 ..< n {
		if l.idx >= len(l.src) { return }
		if l.src[l.idx] == '\n' { l.line += 1 }
		l.idx += 1
	}
}

svl_error :: proc(l: ^SVLexer, msg: string) -> ! {
	panic(fmt.tprintf("SystemVerilog lex error at line %d: %s", l.line, msg))
}

svl_at_eof :: #force_inline proc(l: ^SVLexer) -> bool { return l.idx >= len(l.src) }

svl_is_space :: #force_inline proc(c: byte) -> bool { return c == ' ' || c == '\t' || c == '\v' || c == '\f' }
svl_is_newline :: #force_inline proc(c: byte) -> bool { return c == '\n' || c == '\r' }
svl_is_digit :: #force_inline proc(c: byte) -> bool { return c >= '0' && c <= '9' }
svl_is_ident_start :: #force_inline proc(c: byte) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
svl_is_ident_char :: #force_inline proc(c: byte) -> bool { return c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }
svl_is_base_char :: #force_inline proc(c: byte) -> bool { return c == 'b' || c == 'B' || c == 'o' || c == 'O' || c == 'd' || c == 'D' || c == 'h' || c == 'H' }

svl_skip_trivia :: proc(l: ^SVLexer) {
	for {
		c := svl_peek(l)
		switch {
		case svl_is_space(c):
			svl_advance(l)
		case svl_is_newline(c):
			// CRLF/CL counts as one line: only '\n' increments the line counter.
			if c == '\r' && svl_peek(l, 1) == '\n' { svl_advance(l) }
			svl_advance(l)
		case c == '/' && svl_peek(l, 1) == '/':
			for !svl_at_eof(l) && !svl_is_newline(svl_peek(l)) { svl_advance(l) }
		case c == '/' && svl_peek(l, 1) == '*':
			svl_advance(l, 2)
			for !svl_at_eof(l) && !(svl_peek(l) == '*' && svl_peek(l, 1) == '/') { svl_advance(l) }
			if svl_at_eof(l) { svl_error(l, "unterminated block comment") }
			svl_advance(l, 2)
		case:
			return
		}
	}
}

// Identifier text after a backslash, up to whitespace (escaped identifiers include
// punctuation and are never keywords).
svl_scan_escaped_ident :: proc(l: ^SVLexer) -> string {
	svl_advance(l) // backslash
	start := l.idx
	for !svl_at_eof(l) {
		c := svl_peek(l)
		if svl_is_space(c) || svl_is_newline(c) { break }
		svl_advance(l)
	}
	return string(l.src[start:l.idx])
}

svl_scan_ident :: #force_inline proc(l: ^SVLexer) -> string {
	start := l.idx
	for svl_is_ident_char(svl_peek(l)) { svl_advance(l) }
	return string(l.src[start:l.idx])
}

svl_scan_string :: proc(l: ^SVLexer) -> string {
	// Triple-quoted string literal: """ ... """
	if svl_peek(l) == '"' && svl_peek(l, 1) == '"' && svl_peek(l, 2) == '"' {
		svl_advance(l, 3)
		start := l.idx
		for !svl_at_eof(l) {
			if svl_peek(l) == '"' && svl_peek(l, 1) == '"' && svl_peek(l, 2) == '"' {
				text := string(l.src[start:l.idx])
				svl_advance(l, 3)
				return text
			}
			if svl_peek(l) == '\\' { svl_advance(l, 2) } else { svl_advance(l) }
		}
		svl_error(l, "unterminated triple-quoted string literal")
	}
	svl_advance(l) // opening quote
	start := l.idx
	for !svl_at_eof(l) {
		c := svl_peek(l)
		if c == '\\' {
			svl_advance(l, 2)
			continue
		}
		if c == '"' { break }
		if svl_is_newline(c) { svl_error(l, "unterminated string literal") }
		svl_advance(l)
	}
	if svl_peek(l) != '"' { svl_error(l, "unterminated string literal") }
	text := string(l.src[start:l.idx])
	svl_advance(l)
	return text
}

// Numbers are one token, including a based literal's base and any time-unit suffix.
// Raw text is preserved; decoding happens when the token becomes an SVNumber.
svl_scan_number :: proc(l: ^SVLexer) -> string {
	start := l.idx
	if svl_peek(l) == '\'' {
		// Unsized based literal ('hFF) or unbased literal ('0/'1/'x/'z).
		svl_advance(l)
		if svl_peek(l) == 's' || svl_peek(l) == 'S' { svl_advance(l) }
		if svl_is_base_char(svl_peek(l)) {
			svl_advance(l)
			svl_skip_number_space(l)
			for svl_is_number_char(svl_peek(l)) { svl_advance(l) }
			return string(l.src[start:l.idx])
		}
		c := svl_peek(l)
		if c == '0' || c == '1' || c == 'x' || c == 'X' || c == 'z' || c == 'Z' || c == '?' {
			svl_advance(l)
		}
		return string(l.src[start:l.idx])
	}

	for svl_is_digit(svl_peek(l)) || svl_peek(l) == '_' { svl_advance(l) }
	if svl_peek(l) == '.' && svl_is_digit(svl_peek(l, 1)) {
		svl_advance(l)
		for svl_is_digit(svl_peek(l)) || svl_peek(l) == '_' { svl_advance(l) }
	}
	if (svl_peek(l) == 'e' || svl_peek(l) == 'E') &&
	   (svl_is_digit(svl_peek(l, 1)) ||
	    ((svl_peek(l, 1) == '+' || svl_peek(l, 1) == '-') && svl_is_digit(svl_peek(l, 2)))) {
		svl_advance(l)
		if svl_peek(l) == '+' || svl_peek(l) == '-' { svl_advance(l) }
		for svl_is_digit(svl_peek(l)) || svl_peek(l) == '_' { svl_advance(l) }
	}

	// Sized based literal: 12'hFF, 8'sd10. A macro-expanded size is handled by the
	// parser by joining adjacent number tokens.
	if svl_peek(l) == '\'' {
		if svl_peek(l, 1) == 's' || svl_peek(l, 1) == 'S' {
			if svl_is_base_char(svl_peek(l, 2)) {
				svl_advance(l, 2)
				svl_advance(l) // base char
				svl_skip_number_space(l)
				for svl_is_number_char(svl_peek(l)) { svl_advance(l) }
				return string(l.src[start:l.idx])
			}
		} else if svl_is_base_char(svl_peek(l, 1)) {
			svl_advance(l) // '
			svl_advance(l) // base char
			svl_skip_number_space(l)
			for svl_is_number_char(svl_peek(l)) { svl_advance(l) }
			return string(l.src[start:l.idx])
		}
	}

	// Optional time unit suffix (s, ms, us, ns, ps, fs), no whitespace between.
	unit_start := l.idx
	for svl_is_ident_char(svl_peek(l)) { svl_advance(l) }
	unit := string(l.src[unit_start:l.idx])
	switch unit {
	case "s", "ms", "us", "ns", "ps", "fs":
	// keep it in the token
	case:
		l.idx = unit_start
	}
	return string(l.src[start:l.idx])
}

svl_skip_number_space :: #force_inline proc(l: ^SVLexer) {
	for svl_peek(l) == ' ' || svl_peek(l) == '\t' { svl_advance(l) }
}

svl_is_number_char :: #force_inline proc(c: byte) -> bool {
	return svl_is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') ||
	       c == 'x' || c == 'X' || c == 'z' || c == 'Z' || c == '?' || c == '_'
}

svl_scan_directive :: proc(l: ^SVLexer) -> SVToken {	start := l.idx
	line := l.line
	svl_advance(l) // backtick
	if !svl_is_ident_start(svl_peek(l)) {
		return SVToken{kind = .Backtick, line = line, text = "`"}
	}
	svl_scan_ident(l)
	return SVToken{kind = .Directive, line = line, text = string(l.src[start + 1:l.idx])}
}

svl_op1 :: #force_inline proc(l: ^SVLexer, start: int, line: u32, kind: SVTokenKind) -> SVToken {
	svl_advance(l)
	return SVToken{kind = kind, line = line, text = string(l.src[start:l.idx])}
}

svl_op2 :: #force_inline proc(l: ^SVLexer, start: int, line: u32, kind: SVTokenKind) -> SVToken {
	svl_advance(l, 2)
	return SVToken{kind = kind, line = line, text = string(l.src[start:l.idx])}
}

svl_next :: proc(l: ^SVLexer) -> SVToken {
	svl_skip_trivia(l)
	start := l.idx
	line := l.line
	if svl_at_eof(l) {
		return SVToken{kind = .EOF, line = line}
	}

	c := svl_peek(l)
	switch {
	case c == '\\':
		text := svl_scan_escaped_ident(l)
		return SVToken{kind = .EscapedIdent, line = line, text = text}
	case svl_is_ident_start(c):
		text := svl_scan_ident(l)
		return SVToken{kind = .Ident, kw = svl_keyword_lookup(text), line = line, text = text}
	case c == '$':
		svl_advance(l)
		_ = svl_scan_ident(l)
		return SVToken{kind = .SystemIdent, line = line, text = string(l.src[start:l.idx])}
	case svl_is_digit(c):
		text := svl_scan_number(l)
		return SVToken{kind = .Number, line = line, text = text}
	case c == '\'':
		if svl_is_base_char(svl_peek(l, 1)) ||
		   ((svl_peek(l, 1) == 's' || svl_peek(l, 1) == 'S') && svl_is_base_char(svl_peek(l, 2))) ||
		   svl_is_digit(svl_peek(l, 1)) || svl_peek(l, 1) == '0' || svl_peek(l, 1) == '1' ||
		   svl_peek(l, 1) == 'x' || svl_peek(l, 1) == 'X' || svl_peek(l, 1) == 'z' || svl_peek(l, 1) == 'Z' {
			text := svl_scan_number(l)
			return SVToken{kind = .Number, line = line, text = text}
		}
		svl_advance(l)
		return SVToken{kind = .Tick, line = line, text = "'"}
	case c == '"':
		text := svl_scan_string(l)
		return SVToken{kind = .String, line = line, text = text}
	case c == '`':
		return svl_scan_directive(l)
	}

	// Operators and punctuation.
	t := SVToken{line = line}
	switch c {
	case '(':
		if svl_peek(l, 1) == '*' { return svl_op2(l, start, line, .AttrStart) }
		return svl_op1(l, start, line, .LParen)
	case ')': return svl_op1(l, start, line, .RParen)
	case '[': return svl_op1(l, start, line, .LBracket)
	case ']': return svl_op1(l, start, line, .RBracket)
	case '{': return svl_op1(l, start, line, .LBrace)
	case '}': return svl_op1(l, start, line, .RBrace)
	case ',': return svl_op1(l, start, line, .Comma)
	case ';': return svl_op1(l, start, line, .Semicolon)
	case ':':
		if svl_peek(l, 1) == ':' { return svl_op2(l, start, line, .ColonColon) }
		return svl_op1(l, start, line, .Colon)
	case '.':
		if svl_peek(l, 1) == '*' { return svl_op2(l, start, line, .DotStar) }
		return svl_op1(l, start, line, .Dot)
	case '#':
		if svl_peek(l, 1) == '#' { return svl_op2(l, start, line, .HashHash) }
		return svl_op1(l, start, line, .Hash)
	case '@': return svl_op1(l, start, line, .At)
	case '?': return svl_op1(l, start, line, .Question)
	case '=':
		if svl_peek(l, 1) == '=' {
			if svl_peek(l, 2) == '=' { svl_advance(l, 3); t.kind = .CaseEq; return t }
			if svl_peek(l, 2) == '?' { svl_advance(l, 3); t.kind = .WildEq; return t }
			return svl_op2(l, start, line, .EqEq)
		}
		if svl_peek(l, 1) == '>' { return svl_op2(l, start, line, .FatArrow) }
		return svl_op1(l, start, line, .Assign)
	case '!':
		if svl_peek(l, 1) == '=' {
			if svl_peek(l, 2) == '=' { svl_advance(l, 3); t.kind = .CaseNeq; return t }
			if svl_peek(l, 2) == '?' { svl_advance(l, 3); t.kind = .WildNeq; return t }
			return svl_op2(l, start, line, .NotEq)
		}
		return svl_op1(l, start, line, .Bang)
	case '+':
		switch svl_peek(l, 1) {
		case '+': return svl_op2(l, start, line, .Inc)
		case '=': return svl_op2(l, start, line, .PlusEq)
		case ':': return svl_op2(l, start, line, .PlusColon)
		}
		return svl_op1(l, start, line, .Plus)
	case '-':
		switch svl_peek(l, 1) {
		case '-': return svl_op2(l, start, line, .Dec)
		case '=': return svl_op2(l, start, line, .MinusEq)
		case ':': return svl_op2(l, start, line, .MinusColon)
		case '>': return svl_op2(l, start, line, .Arrow)
		}
		return svl_op1(l, start, line, .Minus)
	case '*':
		if svl_peek(l, 1) == ')' { return svl_op2(l, start, line, .AttrEnd) }
		if svl_peek(l, 1) == '*' { return svl_op2(l, start, line, .Pow) }
		if svl_peek(l, 1) == '>' { return svl_op2(l, start, line, .StarGt) }
		if svl_peek(l, 1) == '=' { return svl_op2(l, start, line, .StarEq) }
		return svl_op1(l, start, line, .Star)
	case '/':
		if svl_peek(l, 1) == '=' { return svl_op2(l, start, line, .SlashEq) }
		return svl_op1(l, start, line, .Slash)
	case '%':
		if svl_peek(l, 1) == '=' { return svl_op2(l, start, line, .PercentEq) }
		return svl_op1(l, start, line, .Percent)
	case '&':
		if svl_peek(l, 1) == '&' { return svl_op2(l, start, line, .AmpAmp) }
		if svl_peek(l, 1) == '=' { return svl_op2(l, start, line, .AmpEq) }
		return svl_op1(l, start, line, .Amp)
	case '|':
		if svl_peek(l, 1) == '|' { return svl_op2(l, start, line, .PipePipe) }
		if svl_peek(l, 1) == '-' && svl_peek(l, 2) == '>' { svl_advance(l, 3); t.kind = .PipeArrow; return t }
		if svl_peek(l, 1) == '=' && svl_peek(l, 2) == '>' { svl_advance(l, 3); t.kind = .PipeFatArrow; return t }
		if svl_peek(l, 1) == '=' { return svl_op2(l, start, line, .PipeEq) }
		return svl_op1(l, start, line, .Pipe)
	case '^':
		if svl_peek(l, 1) == '~' { return svl_op2(l, start, line, .CaretTilde) }
		if svl_peek(l, 1) == '=' { return svl_op2(l, start, line, .CaretEq) }
		return svl_op1(l, start, line, .Caret)
	case '~':
		switch svl_peek(l, 1) {
		case '^': return svl_op2(l, start, line, .TildeCaret)
		case '&': return svl_op2(l, start, line, .TildeAmp)
		case '|': return svl_op2(l, start, line, .TildePipe)
		}
		return svl_op1(l, start, line, .Tilde)
	case '<':
		switch svl_peek(l, 1) {
		case '<':
			if svl_peek(l, 2) == '<' { svl_advance(l, 3); t.kind = .Ashl; return t }
			if svl_peek(l, 2) == '=' { svl_advance(l, 3); t.kind = .ShlEq; return t }
			return svl_op2(l, start, line, .Shl)
		case '=': return svl_op2(l, start, line, .Le)
		}
		return svl_op1(l, start, line, .Lt)
	case '>':
		switch svl_peek(l, 1) {
		case '>':
			if svl_peek(l, 2) == '>' { svl_advance(l, 3); t.kind = .Ashr; return t }
			if svl_peek(l, 2) == '=' { svl_advance(l, 3); t.kind = .ShrEq; return t }
			return svl_op2(l, start, line, .Shr)
		case '=': return svl_op2(l, start, line, .Ge)
		}
		return svl_op1(l, start, line, .Gt)
	}
	svl_error(l, fmt.tprintf("unexpected character '%r'", c))
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
sv_keyword_first: [26]bool

sv_keyword_hash :: #force_inline proc "contextless" (text: string) -> u32 {
	h := u32(0x811c9dc5)
	for i in 0 ..< len(text) {
		h = (h ~ u32(text[i])) * 0x01000193
	}
	return h
}

@(init)
sv_keyword_lut_init :: proc "contextless" () {
	for entry in SV_KEYWORDS {
		h := sv_keyword_hash(entry.name)
		i := int(h) & SVKeyword_LUT_Mask
		for sv_keyword_lut[i].name != "" { i = (i + 1) & SVKeyword_LUT_Mask }
		sv_keyword_lut[i] = SVKeyword_LUT_Entry{hash = h, keyword = entry.keyword, name = entry.name}
		if entry.name[0] >= 'a' && entry.name[0] <= 'z' {
			sv_keyword_first[entry.name[0] - 'a'] = true
		}
	}
}

svl_keyword_lookup :: proc(text: string) -> SVKeyword {
	if len(text) < 2 || len(text) > 24 { return .None }
	c := text[0]
	if c < 'a' || c > 'z' || !sv_keyword_first[c - 'a'] { return .None }
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
	for entry in SV_KEYWORDS {
		if entry.keyword == kw { return entry.name }
	}
	return "identifier"
}

// ---------------------------------------------------------------------------------------
// The keyword table (IEEE 1800-2023 Annex B), generated from the language keyword list.
// Kept in enum('s) numerical order so it can double as a name table.
// ---------------------------------------------------------------------------------------

SVKeyword :: enum u16 {
	None,
	AcceptOn, Alias, Always, AlwaysComb, AlwaysFf, AlwaysLatch, And, Assert,
	Assign, Assume, Automatic, Before, Begin, Bind, Bins, Binsof,
	Bit, Break, Buf, Bufif0, Bufif1, Byte, Case, Casex,
	Casez, Cell, Chandle, Checker, Class, Clocking, Cmos, Config,
	Const, Constraint, Context, Continue, Cover, Covergroup, Coverpoint, Cross,
	Deassign, Default, Defparam, Design, Disable, Dist, Do, Edge,
	Else, End, Endcase, Endchecker, Endclass, Endclocking, Endconfig, Endfunction,
	Endgenerate, Endgroup, Endinterface, Endmodule, Endpackage, Endprimitive, Endprogram, Endproperty,
	Endspecify, Endsequence, Endtable, Endtask, Enum, Event, Eventually, Expect,
	Export, Extends, Extern, Final, FirstMatch, For, Force, Foreach,
	Forever, Fork, Forkjoin, Function, Generate, Genvar, Global, Highz0,
	Highz1, If, Iff, Ifnone, IgnoreBins, IllegalBins, Implements, Implies,
	Import, Incdir, Include, Initial, Inout, Input, Inside, Instance,
	Int, Integer, Interconnect, Interface, Intersect, Join, JoinAny, JoinNone,
	Large, Let, Liblist, Library, Local, Localparam, Logic, Longint,
	Macromodule, Matches, Medium, Modport, Module, Nand, Negedge, Nettype,
	New, Nexttime, Nmos, Nor, Noshowcancelled, Not, Notif0, Notif1,
	Null, Or, Output, Package, Packed, Parameter, Pmos, Posedge,
	Primitive, Priority, Program, Property, Protected, Pull0, Pull1, Pulldown,
	Pullup, PulsestyleOndetect, PulsestyleOnevent, Pure, Rand, Randc, Randcase, Randsequence,
	Rcmos, Real, Realtime, Ref, Reg, RejectOn, Release, Repeat,
	Restrict, Return, Rnmos, Rpmos, Rtran, Rtranif0, Rtranif1, SAlways,
	SEventually, SNexttime, SUntil, SUntilWith, Scalared, Sequence, Shortint, Shortreal,
	Showcancelled, Signed, Small, Soft, Solve, Specify, Specparam, Static,
	String, Strong, Strong0, Strong1, Struct, Super, Supply0, Supply1,
	SyncAcceptOn, SyncRejectOn, Table, Tagged, Task, This, Throughout, Time,
	Timeprecision, Timeunit, Tran, Tranif0, Tranif1, Tri, Tri0, Tri1,
	Triand, Trior, Trireg, Type, Typedef, Union, Unique, Unique0,
	Unsigned, Until, UntilWith, Untyped, Use, Uwire, Var, Vectored,
	Virtual, Void, Wait, WaitOrder, Wand, Weak, Weak0, Weak1,
	While, Wildcard, Wire, With, Within, Wor, Xnor, Xor,
}

SVKeyword_Entry :: struct {
	name:    string,
	keyword: SVKeyword,
}

@(rodata)
SV_KEYWORDS := [?]SVKeyword_Entry {
	{"accept_on", .AcceptOn}, {"alias", .Alias}, {"always", .Always},
	{"always_comb", .AlwaysComb}, {"always_ff", .AlwaysFf}, {"always_latch", .AlwaysLatch},
	{"and", .And}, {"assert", .Assert}, {"assign", .Assign},
	{"assume", .Assume}, {"automatic", .Automatic}, {"before", .Before},
	{"begin", .Begin}, {"bind", .Bind}, {"bins", .Bins},
	{"binsof", .Binsof}, {"bit", .Bit}, {"break", .Break},
	{"buf", .Buf}, {"bufif0", .Bufif0}, {"bufif1", .Bufif1},
	{"byte", .Byte}, {"case", .Case}, {"casex", .Casex},
	{"casez", .Casez}, {"cell", .Cell}, {"chandle", .Chandle},
	{"checker", .Checker}, {"class", .Class}, {"clocking", .Clocking},
	{"cmos", .Cmos}, {"config", .Config}, {"const", .Const},
	{"constraint", .Constraint}, {"context", .Context}, {"continue", .Continue},
	{"cover", .Cover}, {"covergroup", .Covergroup}, {"coverpoint", .Coverpoint},
	{"cross", .Cross}, {"deassign", .Deassign}, {"default", .Default},
	{"defparam", .Defparam}, {"design", .Design}, {"disable", .Disable},
	{"dist", .Dist}, {"do", .Do}, {"edge", .Edge},
	{"else", .Else}, {"end", .End}, {"endcase", .Endcase},
	{"endchecker", .Endchecker}, {"endclass", .Endclass}, {"endclocking", .Endclocking},
	{"endconfig", .Endconfig}, {"endfunction", .Endfunction}, {"endgenerate", .Endgenerate},
	{"endgroup", .Endgroup}, {"endinterface", .Endinterface}, {"endmodule", .Endmodule},
	{"endpackage", .Endpackage}, {"endprimitive", .Endprimitive}, {"endprogram", .Endprogram},
	{"endproperty", .Endproperty}, {"endspecify", .Endspecify}, {"endsequence", .Endsequence},
	{"endtable", .Endtable}, {"endtask", .Endtask}, {"enum", .Enum},
	{"event", .Event}, {"eventually", .Eventually}, {"expect", .Expect},
	{"export", .Export}, {"extends", .Extends}, {"extern", .Extern},
	{"final", .Final}, {"first_match", .FirstMatch}, {"for", .For},
	{"force", .Force}, {"foreach", .Foreach}, {"forever", .Forever},
	{"fork", .Fork}, {"forkjoin", .Forkjoin}, {"function", .Function},
	{"generate", .Generate}, {"genvar", .Genvar}, {"global", .Global},
	{"highz0", .Highz0}, {"highz1", .Highz1}, {"if", .If},
	{"iff", .Iff}, {"ifnone", .Ifnone}, {"ignore_bins", .IgnoreBins},
	{"illegal_bins", .IllegalBins}, {"implements", .Implements}, {"implies", .Implies},
	{"import", .Import}, {"incdir", .Incdir}, {"include", .Include},
	{"initial", .Initial}, {"inout", .Inout}, {"input", .Input},
	{"inside", .Inside}, {"instance", .Instance}, {"int", .Int},
	{"integer", .Integer}, {"interconnect", .Interconnect}, {"interface", .Interface},
	{"intersect", .Intersect}, {"join", .Join}, {"join_any", .JoinAny},
	{"join_none", .JoinNone}, {"large", .Large}, {"let", .Let},
	{"liblist", .Liblist}, {"library", .Library}, {"local", .Local},
	{"localparam", .Localparam}, {"logic", .Logic}, {"longint", .Longint},
	{"macromodule", .Macromodule}, {"matches", .Matches}, {"medium", .Medium},
	{"modport", .Modport}, {"module", .Module}, {"nand", .Nand},
	{"negedge", .Negedge}, {"nettype", .Nettype}, {"new", .New},
	{"nexttime", .Nexttime}, {"nmos", .Nmos}, {"nor", .Nor},
	{"noshowcancelled", .Noshowcancelled}, {"not", .Not}, {"notif0", .Notif0},
	{"notif1", .Notif1}, {"null", .Null}, {"or", .Or},
	{"output", .Output}, {"package", .Package}, {"packed", .Packed},
	{"parameter", .Parameter}, {"pmos", .Pmos}, {"posedge", .Posedge},
	{"primitive", .Primitive}, {"priority", .Priority}, {"program", .Program},
	{"property", .Property}, {"protected", .Protected}, {"pull0", .Pull0},
	{"pull1", .Pull1}, {"pulldown", .Pulldown}, {"pullup", .Pullup},
	{"pulsestyle_ondetect", .PulsestyleOndetect}, {"pulsestyle_onevent", .PulsestyleOnevent}, {"pure", .Pure},
	{"rand", .Rand}, {"randc", .Randc}, {"randcase", .Randcase},
	{"randsequence", .Randsequence}, {"rcmos", .Rcmos}, {"real", .Real},
	{"realtime", .Realtime}, {"ref", .Ref}, {"reg", .Reg},
	{"reject_on", .RejectOn}, {"release", .Release}, {"repeat", .Repeat},
	{"restrict", .Restrict}, {"return", .Return}, {"rnmos", .Rnmos},
	{"rpmos", .Rpmos}, {"rtran", .Rtran}, {"rtranif0", .Rtranif0},
	{"rtranif1", .Rtranif1}, {"s_always", .SAlways}, {"s_eventually", .SEventually},
	{"s_nexttime", .SNexttime}, {"s_until", .SUntil}, {"s_until_with", .SUntilWith},
	{"scalared", .Scalared}, {"sequence", .Sequence}, {"shortint", .Shortint},
	{"shortreal", .Shortreal}, {"showcancelled", .Showcancelled}, {"signed", .Signed},
	{"small", .Small}, {"soft", .Soft}, {"solve", .Solve},
	{"specify", .Specify}, {"specparam", .Specparam}, {"static", .Static},
	{"string", .String}, {"strong", .Strong}, {"strong0", .Strong0},
	{"strong1", .Strong1}, {"struct", .Struct}, {"super", .Super},
	{"supply0", .Supply0}, {"supply1", .Supply1}, {"sync_accept_on", .SyncAcceptOn},
	{"sync_reject_on", .SyncRejectOn}, {"table", .Table}, {"tagged", .Tagged},
	{"task", .Task}, {"this", .This}, {"throughout", .Throughout},
	{"time", .Time}, {"timeprecision", .Timeprecision}, {"timeunit", .Timeunit},
	{"tran", .Tran}, {"tranif0", .Tranif0}, {"tranif1", .Tranif1},
	{"tri", .Tri}, {"tri0", .Tri0}, {"tri1", .Tri1},
	{"triand", .Triand}, {"trior", .Trior}, {"trireg", .Trireg},
	{"type", .Type}, {"typedef", .Typedef}, {"union", .Union},
	{"unique", .Unique}, {"unique0", .Unique0}, {"unsigned", .Unsigned},
	{"until", .Until}, {"until_with", .UntilWith}, {"untyped", .Untyped},
	{"use", .Use}, {"uwire", .Uwire}, {"var", .Var},
	{"vectored", .Vectored}, {"virtual", .Virtual}, {"void", .Void},
	{"wait", .Wait}, {"wait_order", .WaitOrder}, {"wand", .Wand},
	{"weak", .Weak}, {"weak0", .Weak0}, {"weak1", .Weak1},
	{"while", .While}, {"wildcard", .Wildcard}, {"wire", .Wire},
	{"with", .With}, {"within", .Within}, {"wor", .Wor},
	{"xnor", .Xnor}, {"xor", .Xor},
}

svl_skip_to_line_end :: proc(l: ^SVLexer) {
	for !svl_at_eof(l) && !svl_is_newline(svl_peek(l)) { svl_advance(l) }
}

svl_skip_blank :: #force_inline proc(l: ^SVLexer) {
	for svl_peek(l) == ' ' || svl_peek(l) == '\t' { svl_advance(l) }
}
