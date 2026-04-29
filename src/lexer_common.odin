package main
import "core:fmt"

Lexer :: struct {
	src:      []byte,
	idx:      int,
	filepath: string,
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
