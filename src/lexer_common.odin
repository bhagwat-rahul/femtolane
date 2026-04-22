package main
import "core:fmt"

Lexer :: struct {
	src:      []byte,
	idx:      int,
	filepath: string,
}

peek :: #force_inline proc(l: ^Lexer, offset: int = 0) -> byte { return l.src[l.idx + offset] if l.idx + offset < len(l.src) else 0 }

advance :: #force_inline proc(l: ^Lexer, advance_by: int = 1) {
	if l.idx + advance_by > len(l.src) { lexer_panic(l, "Unexpected EOF") }
	l.idx += advance_by
}

lexer_panic :: #force_inline proc(l: ^Lexer, err_msg: string) {
	panic(fmt.tprintf("Error: %s at byte %d for char %r in file '%s'", err_msg, l.idx, l.src[l.idx], l.filepath))
}

lexer_ensure :: #force_inline proc(l: ^Lexer, condition: bool, err_msg: string) {
	ensure(condition, fmt.tprintf("Error: %s at byte %d for char %r in file '%s'", err_msg, l.idx, l.src[l.idx], l.filepath))
}

consume :: #force_inline proc(l: ^Lexer, c: byte) {
	if peek(l) != c { panic("unexpected char") }
	advance(l)
}

scan_double_quote_wrapped_string :: proc(l: ^Lexer) -> string {
	consume(l, '"')
	start := l.idx
	for {
		if l.idx >= len(l.src) { panic("unterminated string") }
		if peek(l) == '"' {
			s := string(l.src[start:l.idx]) // ← NO quotes
			advance(l)
			return s
		}
		advance(l)
	}
}
