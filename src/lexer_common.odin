package main
import "core:fmt"

Lexer :: struct {
	src:      []byte,
	idx:      int,
	filepath: string,
}

IDENT_START, IDENT_CHAR: [256]bool
@(init)
init_ident_tables :: proc "contextless" () {
	// true for ident start and ident char (this can show up anywhere in ident)
	for c in 'a' ..= 'z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	for c in 'A' ..= 'Z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	IDENT_START['_'] = true; IDENT_CHAR['_'] = true

	// only true for ident char, cannot see this at the beginning of an ident
	for c in '0' ..= '9' { IDENT_CHAR[c] = true }
	IDENT_CHAR['$'] = true
}

peek :: #force_inline proc(l: ^Lexer, offset: int = 0) -> byte { return l.src[l.idx + offset] if l.idx + offset < len(l.src) else 0 }

advance :: #force_inline proc(l: ^Lexer, advance_by: int = 1) {
	lexer_ensure(l = l, condition = l.idx + advance_by <= len(l.src), err_msg = "Unexpected EOF")
	l.idx += advance_by
}

lexer_panic :: #force_inline proc(l: ^Lexer, err_msg: string) {
	panic(fmt.tprintfln("Error: %s at byte %d for char %r in file '%s'", err_msg, l.idx, l.src[l.idx], l.filepath))
}

lexer_ensure :: #force_inline proc(l: ^Lexer, condition: bool, err_msg: string) { if !condition { lexer_panic(l, err_msg) } }

consume :: #force_inline proc(l: ^Lexer, c: byte) {
	lexer_ensure(l = l, condition = peek(l) == c, err_msg = "Unexpected Char")
	advance(l)
}

scan_double_quote_wrapped_string :: #force_inline proc(l: ^Lexer) -> (unwrapped_string: string) {
	consume(l, '"')
	start := l.idx
	for l.idx < len(l.src) { if peek(l) == '"' { break } else { advance(l) } }
	lexer_ensure(l = l, condition = l.idx < len(l.src), err_msg = "Unterminated string")
	unwrapped_string = string(l.src[start:l.idx])
	consume(l, '"')
	return unwrapped_string
}

is_ident_start :: #force_inline proc(b: byte) -> bool { return IDENT_START[b] }
is_ident_char :: #force_inline proc(b: byte) -> bool { return IDENT_CHAR[b] }

// Scan identifiers handling escape symbols
scan_ident :: #force_inline proc(l: ^Lexer) -> string {
	start: int
	if peek(l) == ESCAPE_SYMBOL {
		consume(l, '\\')
		start = l.idx
		for {
			c := peek(l)
			if c == WHITESPACE || c == WHITESPACE_TAB || c == NEWLINE || c == NEWLINE_CARRIAGE_RETURN || c == 0 { break }
			advance(l)
		}
	} else {
		lexer_ensure(l, is_ident_start(peek(l)), "Invalid identifier start")
		start = l.idx
		for is_ident_char(peek(l)) { advance(l) }
	}
	return string(l.src[start:l.idx])
}

scan_ident_ascii_upper :: #force_inline proc(l: ^Lexer) -> string {
	start: int
	// NOTE(rahul): DO NOT normalize escaped identifiers, they are case-sensitive by definition
	if peek(l) == ESCAPE_SYMBOL {
		consume(l, '\\')
		start = l.idx
		for {
			c := peek(l)
			if c == WHITESPACE || c == WHITESPACE_TAB || c == NEWLINE || c == NEWLINE_CARRIAGE_RETURN || c == 0 { break }
			advance(l)
		}
	} else {
		lexer_ensure(l, is_ident_start(peek(l)), "Invalid identifier start")
		start = l.idx
		for {
			c := peek(l)
			if !is_ident_char(c) { break }
			if c >= 'a' && c <= 'z' { l.src[l.idx] = c - 32 }
			advance(l)
		}
	}
	return string(l.src[start:l.idx])
}
