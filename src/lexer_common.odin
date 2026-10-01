package main
import "core:fmt"

Lexer :: struct {
	src:      []byte,
	idx:      int,
	newlines: u32,
	filepath: string,
}

IDENT_START, IDENT_CHAR: [256]bool
@(init)
lexer_init_ident_tables :: proc "contextless" () {
	// true for ident start and ident char (this can show up anywhere in ident)
	for c in 'a' ..= 'z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	for c in 'A' ..= 'Z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	IDENT_START['_'] = true; IDENT_CHAR['_'] = true

	// only true for ident char, cannot see this at the beginning of an ident
	for c in '0' ..= '9' { IDENT_CHAR[c] = true }
	IDENT_CHAR['$'] = true
}

lexer_peek :: #force_inline proc(l: ^Lexer, offset: int = 0) -> byte { return l.src[l.idx + offset] if l.idx + offset < len(l.src) else 0 }

lexer_advance :: #force_inline proc(l: ^Lexer, advance_by: int = 1) {
	lexer_ensure(l = l, condition = l.idx + advance_by <= len(l.src), err_msg = "Unexpected EOF")
	l.idx += advance_by
}

lexer_panic :: #force_inline proc(l: ^Lexer, err_msg: string) {
	panic(fmt.tprintfln("Error: %s at byte %d for char %r in file '%s' on line %d", err_msg, l.idx, lexer_peek(l), l.filepath, l.newlines + 1))
}

lexer_ensure :: #force_inline proc(l: ^Lexer, condition: bool, err_msg: string) { if !condition { lexer_panic(l, err_msg) } }

lexer_consume :: #force_inline proc(l: ^Lexer, c: byte) {
	lexer_ensure(l = l, condition = lexer_peek(l) == c, err_msg = "Unexpected Char")
	lexer_advance(l)
}

lexer_scan_double_quote_wrapped_string :: #force_inline proc(l: ^Lexer) -> (unwrapped_string: string) {
	lexer_consume(l, DOUBLE_QUOTE)
	start := l.idx
	for l.idx < len(l.src) { if lexer_peek(l) == DOUBLE_QUOTE { break } else { lexer_advance(l) } }
	lexer_ensure(l = l, condition = l.idx < len(l.src), err_msg = "Unterminated string")
	unwrapped_string = string(l.src[start:l.idx])
	lexer_consume(l, DOUBLE_QUOTE)
	return unwrapped_string
}

lexer_is_ident_start :: #force_inline proc(b: byte) -> bool { return IDENT_START[b] }
lexer_is_ident_char :: #force_inline proc(b: byte) -> bool { return IDENT_CHAR[b] }

// Scan identifiers handling escape symbols
lexer_scan_ident :: #force_inline proc(l: ^Lexer) -> string {
	start: int
	if lexer_peek(l) == ESCAPE_SYMBOL {
		lexer_consume(l, ESCAPE_SYMBOL)
		start = l.idx
		for {
			c := lexer_peek(l)
			if c == WHITESPACE || c == WHITESPACE_TAB || c == NEWLINE || c == NEWLINE_CARRIAGE_RETURN || c == 0 { break }
			lexer_advance(l)
		}
	} else {
		lexer_ensure(l, lexer_is_ident_start(lexer_peek(l)), "Invalid identifier start")
		start = l.idx
		for lexer_is_ident_char(lexer_peek(l)) { lexer_advance(l) }
	}
	return string(l.src[start:l.idx])
}

lexer_scan_ident_ascii_upper :: #force_inline proc(l: ^Lexer) -> string {
	start: int
	// NOTE(rahul): DO NOT normalize escaped identifiers, they are case-sensitive by definition
	if lexer_peek(l) == ESCAPE_SYMBOL {
		lexer_consume(l, ESCAPE_SYMBOL)
		start = l.idx
		for {
			c := lexer_peek(l)
			if c == WHITESPACE || c == WHITESPACE_TAB || c == NEWLINE || c == NEWLINE_CARRIAGE_RETURN || c == 0 { break }
			lexer_advance(l)
		}
	} else {
		lexer_ensure(l, lexer_is_ident_start(lexer_peek(l)), "Invalid identifier start")
		start = l.idx
		for {
			c := lexer_peek(l)
			if !lexer_is_ident_char(c) { break }
			if c >= 'a' && c <= 'z' { l.src[l.idx] = c - 32 }
			lexer_advance(l)
		}
	}
	return string(l.src[start:l.idx])
}

lexer_skip_newlines_and_whitespaces :: #force_inline proc(l: ^Lexer) {
	for {
		c := lexer_peek(l)
		if c == NEWLINE { l.newlines += 1 }
		if c != NEWLINE && c != NEWLINE_CARRIAGE_RETURN && c != WHITESPACE && c != WHITESPACE_TAB { break }
		lexer_advance(l)
	}
}
