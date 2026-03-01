package femtolane

import "core:bufio"
import "core:unicode"

// TODO(rahul): Optimize helper func's and review all structs for a good single pass lex -> instance hypergraph emit step

// Parsing, advancing, etc. all get a pointer to this struct
Lexer :: struct {
	r:    ^bufio.Reader,
	curr: byte,
	peek: byte,
	buf:  [dynamic]byte,
}

// distinct 32 bit generic string id
StringId32 :: distinct u32
// distinct 32 bit vertex id
VertexID32 :: distinct u32
// distinct 32 bit net id
NetID32 :: distinct u32

Vertex :: struct {
	name: StringId32,
	cell: StringId32,
}

Pin :: struct {
	vertex: VertexID32, // instance id
	port:   StringId32,
}

Net :: struct {
	name:      StringId32,
	first_pin: u32,
	pin_count: u32,
}

// net hypergraph builder for fast writes, this has net_lookup to dedupe while building
NetHyperGraphBuilder :: struct {
	vertices:   [dynamic]Vertex,
	nets:       [dynamic]Net,
	pins:       [dynamic]Pin,
	net_lookup: map[StringId32]NetID32,
}

// Final net hypergraph post build phase for fast reads, SIMD'able
NetHyperGraph :: struct {
	vertices: #soa[dynamic]Vertex,
	nets:     #soa[dynamic]Net,
	pins:     #soa[dynamic]Pin,
}

// Advance the lexer struct, move current and next (peek) char by a byte, handling EOF
advance :: proc(l: ^Lexer) {
	l.curr = l.peek
	b, err := bufio.reader_read_byte(l.r)
	l.peek = 0 if err == .EOF else b
}

// Initialise the lexer struct
init_lexer :: proc(r: ^bufio.Reader) -> (l: Lexer) {
	l.r = r
	advance(&l); advance(&l)
	return l
}

// Skip whitespaces
skip_whitespace :: proc(l: ^Lexer) {
	for unicode.is_space(rune(l.curr)) {advance(l)}
}

// Once you see the start of a comment, keep going till end of line or */ if multi-line comment
skip_comments :: proc(l: ^Lexer) {
	for {
		if l.curr == '/' && l.peek == '/' {
			for l.curr != '\n' {advance(l)}
			continue
		}
		if l.curr == '/' && l.peek == '*' {
			advance(l); advance(l)
			for !(l.curr == '*' && l.peek == '/') {
				advance(l)
			}
			advance(l); advance(l)
			continue
		}
		break
	}
}

is_identifier :: proc(c: byte) -> bool {
	return unicode.is_letter(rune(c)) || unicode.is_digit(rune(c)) || c == '_' || c == '$'
}

read_identifier :: proc(l: ^Lexer) -> []byte {
	clear(&l.buf)
	for is_identifier(l.curr) {append(&l.buf, l.curr); advance(l)}
	return l.buf[:]
}

read_escaped_identifier :: proc(l: ^Lexer) -> []byte {
	advance(l) // skip '\'
	clear(&l.buf)
	for !unicode.is_space(rune(l.curr)) {
		append(&l.buf, l.curr)
		advance(l)
	}
	return l.buf[:]
}

expect :: proc(l: ^Lexer, c: byte) {
	skip_whitespace(l)
	ensure(l.curr == c, "parse_error")
	advance(l)
}

parse_instance_and_emit_graph :: proc(l: ^Lexer, resulting_graph: ^NetHyperGraph) {
}
