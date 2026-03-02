package femtolane

// TODO(rahul): Optimize helper func's and review all structs for a good single pass lex -> instance hypergraph emit step

//TODO(rahul): IMPORTANT!!! Lot's of func's here made with codex 5.2, review and re-write

// Parsing, advancing, etc. all get a pointer to this struct
Lexer :: struct {
	src:  []byte,
	pos:  int,
	curr: byte,
	peek: byte,
	buf:  [dynamic]byte,
}

StringId32 :: distinct u32 // distinct 32 bit generic string id
VertexID32 :: distinct u32 // distinct 32 bit vertex id
NetID32 :: distinct u32 // distinct 32 bit net id

Vertex :: struct {
	name: StringId32,
	cell: StringId32,
}

BuilderPin :: struct {
	net:    NetID32,
	vertex: VertexID32,
	port:   StringId32,
}

Pin :: struct {
	vertex: VertexID32,
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
	pins:       [dynamic]BuilderPin,
	net_lookup: map[StringId32]NetID32,
	counts:     [dynamic]u32,
	offsets:    [dynamic]u32,
	next:       [dynamic]u32,
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
	if l.pos < len(l.src) {
		l.peek = l.src[l.pos]
		l.pos += 1
	} else {
		l.peek = 0
	}
}

// Initialise the lexer struct
init_lexer :: proc(src: []byte) -> (l: Lexer) {
	l.src = src
	advance(&l); advance(&l)
	return l
}

is_space :: proc(c: rune) -> (is_space: bool) {
	is_space = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
	return is_space
}

// Skip whitespaces
skip_whitespace :: proc(l: ^Lexer) {
	for is_space(rune(l.curr)) {advance(l)}
}

skip_comments :: proc(l: ^Lexer) {
	if l.curr == '/' && l.peek == '/' {
		for l.curr != 0 && l.curr != '\n' {advance(l)}
		return
	}
	if l.curr == '/' && l.peek == '*' {
		advance(l); advance(l)
		for l.curr != 0 && !(l.curr == '*' && l.peek == '/') {
			advance(l)
		}
		if l.curr != 0 {
			advance(l); advance(l)
		}
	}
}

skip_attributes :: proc(l: ^Lexer) {
	if l.curr == '(' && l.peek == '*' {
		advance(l); advance(l)
		for l.curr != 0 && !(l.curr == '*' && l.peek == ')') {
			advance(l)
		}
		if l.curr != 0 {
			advance(l); advance(l)
		}
	}
}

skip_trivia :: proc(l: ^Lexer) {
	for {
		skip_whitespace(l)
		start_curr := l.curr
		start_peek := l.peek
		skip_comments(l)
		skip_attributes(l)
		if l.curr == start_curr && l.peek == start_peek {
			break
		}
	}
}

is_identifier :: proc(byte: byte) -> bool {
	is_id :=
		(byte >= 'a' && byte <= 'z') ||
		(byte >= 'A' && byte <= 'Z') ||
		(byte >= '0' && byte <= '9') ||
		byte == '_' ||
		byte == '$'
	return is_id
}

read_identifier :: proc(l: ^Lexer) -> []byte {
	clear(&l.buf)
	for is_identifier(l.curr) {append(&l.buf, l.curr); advance(l)}
	return l.buf[:]
}

read_escaped_identifier :: proc(l: ^Lexer) -> []byte {
	advance(l) // skip '\'
	clear(&l.buf)
	for l.curr != 0 && !is_space(rune(l.curr)) {
		append(&l.buf, l.curr)
		advance(l)
	}
	return l.buf[:]
}

read_name :: proc(l: ^Lexer) -> []byte {
	if l.curr == '\\' {return read_escaped_identifier(l)}
	return read_identifier(l)
}

expect :: proc(l: ^Lexer, c: byte) {
	skip_trivia(l)
	ensure(l.curr == c, "parse_error")
	advance(l)
}

bytes_equal_string :: proc(data: []byte, s: string) -> bool {
	if len(data) != len(s) {return false}
	for i in 0 ..< len(data) {
		if data[i] != s[i] {return false}
	}
	return true
}

hash_string_id :: proc(data: []byte) -> StringId32 {
	hash: u32 = 2166136261
	for b in data {
		hash = (hash ~ u32(b)) * 16777619
	}
	if hash == 0 {hash = 1}
	return StringId32(hash)
}

is_skip_statement_keyword :: proc(id: []byte) -> bool {
	return(
		bytes_equal_string(id, "module") ||
		bytes_equal_string(id, "input") ||
		bytes_equal_string(id, "output") ||
		bytes_equal_string(id, "inout") ||
		bytes_equal_string(id, "wire") ||
		bytes_equal_string(id, "reg") ||
		bytes_equal_string(id, "logic") ||
		bytes_equal_string(id, "assign") ||
		bytes_equal_string(id, "parameter") ||
		bytes_equal_string(id, "localparam") ||
		bytes_equal_string(id, "supply0") ||
		bytes_equal_string(id, "supply1") ||
		bytes_equal_string(id, "tri") ||
		bytes_equal_string(id, "wand") ||
		bytes_equal_string(id, "wor") \
	)
}

is_block_end_keyword :: proc(id: []byte) -> bool {
	return bytes_equal_string(id, "endmodule") || bytes_equal_string(id, "endgenerate")
}

skip_to_statement_end :: proc(l: ^Lexer) {
	for l.curr != 0 && l.curr != ';' {
		advance(l)
	}
	if l.curr == ';' {advance(l)}
}

skip_to_end_of_line :: proc(l: ^Lexer) {
	for l.curr != 0 && l.curr != '\n' {
		advance(l)
	}
}

skip_balanced :: proc(l: ^Lexer, open, close: byte) {
	ensure(l.curr == open, "parse_error")
	depth := 0
	for l.curr != 0 {
		if l.curr == open {
			depth += 1
		} else if l.curr == close {
			depth -= 1
			if depth == 0 {
				advance(l)
				return
			}
		}
		advance(l)
	}
}

read_connection_target :: proc(l: ^Lexer) -> []byte {
	if l.curr == '\\' {return read_escaped_identifier(l)}
	clear(&l.buf)
	bracket_depth := 0
	brace_depth := 0
	for l.curr != 0 {
		if bracket_depth == 0 && brace_depth == 0 && (l.curr == ')' || l.curr == ',') {
			break
		}
		if is_space(rune(l.curr)) && bracket_depth == 0 && brace_depth == 0 {
			break
		}
		if l.curr == '[' {
			bracket_depth += 1
		} else if l.curr == ']' && bracket_depth > 0 {
			bracket_depth -= 1
		} else if l.curr == '{' {
			brace_depth += 1
		} else if l.curr == '}' && brace_depth > 0 {
			brace_depth -= 1
		}
		append(&l.buf, l.curr)
		advance(l)
	}
	return l.buf[:]
}

add_vertex :: proc(b: ^NetHyperGraphBuilder, inst_name, cell_name: StringId32) -> VertexID32 {
	id := VertexID32(len(b.vertices))
	append(&b.vertices, Vertex{name = inst_name, cell = cell_name})
	return id
}

get_or_add_net :: proc(b: ^NetHyperGraphBuilder, net_name: StringId32) -> NetID32 {
	if net_id, ok := b.net_lookup[net_name]; ok {
		return net_id
	}
	new_id := NetID32(len(b.nets))
	append(&b.nets, Net{name = net_name})
	b.net_lookup[net_name] = new_id
	return new_id
}

emit_pin :: proc(
	b: ^NetHyperGraphBuilder,
	vertex: VertexID32,
	port_name: StringId32,
	net_name: StringId32,
) {
	net_id := get_or_add_net(b, net_name)
	append(&b.pins, BuilderPin{net = net_id, vertex = vertex, port = port_name})
}

// TODO(rahul): Review/Fix, LLM coded
freezeHyperGraph :: proc(b: ^NetHyperGraphBuilder) -> NetHyperGraph {
	hg: NetHyperGraph
	// Copy vertices (AoS → SoA)
	resize(&hg.vertices, len(b.vertices))
	for i in 0 ..< len(b.vertices) {
		hg.vertices[i] = b.vertices[i]
	}
	// Copy nets (AoS → SoA)
	resize(&hg.nets, len(b.nets))
	for i in 0 ..< len(b.nets) {
		hg.nets[i] = b.nets[i]
	}
	// ---- CSR BUILD START ----
	// 1. Count pins per net
	resize(&b.counts, len(b.nets))
	for i in 0 ..< len(b.counts) {
		b.counts[i] = 0
	}
	for p in b.pins {
		net_idx := int(p.net)
		ensure(net_idx < len(b.nets), "builder pin net index out of range")
		b.counts[net_idx] += 1
	}
	// 2. Prefix sum → first_pin
	resize(&b.offsets, len(b.nets))
	running: u32 = 0
	for i in 0 ..< len(b.nets) {
		b.offsets[i] = running
		hg.nets[i].first_pin = running
		hg.nets[i].pin_count = b.counts[i]
		running += b.counts[i]
	}
	ensure(running == u32(len(b.pins)), "pin count mismatch while freezing hypergraph")
	// 3. Allocate SoA pins
	resize(&hg.pins, len(b.pins))
	// 4. Scatter pins into CSR order
	resize(&b.next, len(b.nets))
	copy(b.next[:], b.offsets[:])
	for p in b.pins {
		net_idx := int(p.net)
		idx := b.next[net_idx]
		ensure(int(idx) < len(hg.pins), "pin scatter index out of range")

		hg.pins[idx] = Pin {
			vertex = p.vertex,
			port   = p.port,
		}
		b.next[net_idx] += 1
	}
	// ---- CSR BUILD END ----
	return hg
}

parse_instance_and_emit_graph :: proc(l: ^Lexer, resulting_graph: ^NetHyperGraphBuilder) {
	skip_trivia(l)
	if l.curr == 0 {return}
	if l.curr == '`' {
		skip_to_end_of_line(l)
		return
	}
	if l.curr == ';' {
		advance(l)
		return
	}

	if !(l.curr == '\\' || is_identifier(l.curr)) {
		skip_to_statement_end(l)
		return
	}

	cell_or_kw := read_name(l)
	if is_block_end_keyword(cell_or_kw) {
		return
	}
	if is_skip_statement_keyword(cell_or_kw) {
		skip_to_statement_end(l)
		return
	}

	skip_trivia(l)
	if l.curr == '#' {
		advance(l)
		skip_trivia(l)
		if l.curr != '(' {
			skip_to_statement_end(l)
			return
		}
		skip_balanced(l, '(', ')')
		skip_trivia(l)
	}

	if !(l.curr == '\\' || is_identifier(l.curr)) {
		skip_to_statement_end(l)
		return
	}

	inst_name := read_name(l)
	skip_trivia(l)
	if l.curr != '(' {
		skip_to_statement_end(l)
		return
	}

	vertex_id := add_vertex(resulting_graph, hash_string_id(inst_name), hash_string_id(cell_or_kw))

	advance(l) // skip opening paren of connection list
	positional_idx: u32 = 0
	for {
		skip_trivia(l)
		if l.curr == ')' {
			advance(l)
			break
		}
		if l.curr == 0 {
			break
		}

		port_name: StringId32
		named_connection := false
		if l.curr == '.' {
			named_connection = true
			advance(l)
			skip_trivia(l)
			if !(l.curr == '\\' || is_identifier(l.curr)) {
				skip_to_statement_end(l)
				return
			}
			port_name = hash_string_id(read_name(l))
			skip_trivia(l)
			if l.curr != '(' {
				skip_to_statement_end(l)
				return
			}
			advance(l)
			skip_trivia(l)
		} else {
			positional_idx += 1
			port_name = StringId32(0x8000_0000 | positional_idx)
		}

		net_token := read_connection_target(l)
		if len(net_token) > 0 {
			emit_pin(resulting_graph, vertex_id, port_name, hash_string_id(net_token))
		}

		skip_trivia(l)
		if named_connection {
			if l.curr != ')' {
				skip_to_statement_end(l)
				return
			}
			advance(l)
			skip_trivia(l)
		}

		if l.curr == ',' {
			advance(l)
			continue
		}
		if l.curr == ')' {
			advance(l)
			break
		}
		if l.curr == 0 {
			break
		}
		skip_to_statement_end(l)
		return
	}

	skip_trivia(l)
	if l.curr == ';' {
		advance(l)
	} else {
		skip_to_statement_end(l)
	}
}

parse_netlist :: proc(src: []byte) -> NetHyperGraph {
	l := init_lexer(src)
	builder := NetHyperGraphBuilder {
		net_lookup = make(map[StringId32]NetID32),
	}
	for {
		skip_trivia(&l)
		if l.curr == 0 {break}
		parse_instance_and_emit_graph(&l, &builder)
	}
	return freezeHyperGraph(&builder)
}
