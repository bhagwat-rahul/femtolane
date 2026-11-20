/*
Compact SystemVerilog parser over the preprocessed token stream.

This is the data-oriented replacement for the byte-scanning recursive descent
parser: the parser only ever indexes SVToken values, so there is no trivia
rescanning, no save/restore of the tokenizer for lookahead, and keyword dispatch is
an enum switch.

The AST is built directly in flat form: every node is appended to the chunked
node store and every child list is a span of the shared `ast.kids` buffer.
Child lists are gathered in reusable per-nesting-depth scratch buffers, so a
list costs no allocation after the first use of that depth. Chunks never move,
so a node pointer stays valid while nested constructs append more nodes.
*/

package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

SVParser2 :: struct {
	toks:           []SVToken,
	sources:        []SVSource, // token offsets index these source buffers
	i:              int,
	ast:            ^SystemVerilogAST,
	allocator:      mem.Allocator,
	module:         u32, // index into ast.modules, SV_NONE when outside a module
	iface:          u32, // index into ast.interfaces, SV_NONE when outside an interface
	port_map:       map[string]u32, // port name -> port node id for the open module/interface
	port_map_ready: bool,
	filepath:       string,

	// Child-list scratch storage, one slot per open nesting depth. Short lists
	// stay entirely inline; only lists over SV_LIST_INLINE spill to the overflow
	// array. Entries are committed to ast.kids when the list closes.
	list_inline:    [SV_LIST_MAX_DEPTH][SV_LIST_INLINE]u32,
	list_lens:      [SV_LIST_MAX_DEPTH]int,
	list_over:      [SV_LIST_MAX_DEPTH][dynamic]u32,
	list_depth:     int,

	// Incremental line lookup for diagnostics and retained attributes. Tokens are
	// visited in source order, so each source byte is scanned at most once.
	line_file:      u16,
	line_off:       u32,
	line_value:     u32,
	line_valid:     bool,
}

// The preprocessor appends four EOF sentinels, so the parser's maximum lookahead
// (three tokens) can index without bounds checks.
svp_peek :: #force_inline proc(p: ^SVParser2, n := 0) -> SVToken {
	return p.toks[p.i + n]
}

svp_at :: #force_inline proc(p: ^SVParser2, kind: SVTokenKind, n := 0) -> bool {
	return p.toks[p.i + n].kind == kind
}

svp_kw_at :: #force_inline proc(p: ^SVParser2, kw: SVKeyword, n := 0) -> bool {
	return p.toks[p.i + n].kw == kw
}

svp_advance :: #force_inline proc(p: ^SVParser2) -> SVToken {
	t := svp_peek(p)
	if t.kind != .EOF { p.i += 1 }
	return t
}

svp_text :: #force_inline proc(p: ^SVParser2, t: SVToken) -> string {
	#no_bounds_check return string(p.sources[t.file].data[t.off:t.off + u32(t.len)])
}

svp_token_line :: proc(p: ^SVParser2, t: SVToken) -> u32 {
	if !p.line_valid || p.line_file != t.file || t.off < p.line_off {
		p.line_file = t.file
		p.line_off = 0
		p.line_value = p.sources[t.file].line_base
		p.line_valid = true
	}
	#no_bounds_check src := p.sources[t.file].data
	#no_bounds_check for p.line_off < t.off {
		if src[p.line_off] == '\n' { p.line_value += 1 }
		p.line_off += 1
	}
	return p.line_value
}

svp_bump :: #force_inline proc(p: ^SVParser2) {
	#no_bounds_check if p.toks[p.i].kind != .EOF { p.i += 1 }
}

svp_accept :: #force_inline proc(p: ^SVParser2, kind: SVTokenKind) -> bool {
	if svp_at(p, kind) { p.i += 1; return true }
	return false
}

svp_accept_kw :: #force_inline proc(p: ^SVParser2, kw: SVKeyword) -> bool {
	if svp_kw_at(p, kw) { p.i += 1; return true }
	return false
}

svp_expect :: #force_inline proc(p: ^SVParser2, kind: SVTokenKind) -> SVToken {
	t := svp_peek(p)
	if t.kind != kind {
		svp_error(p, fmt.tprintf("expected %v, got %v '%s'", kind, t.kind, svp_text(p, t)))
	}
	return svp_advance(p)
}

svp_expect_kw :: #force_inline proc(p: ^SVParser2, kw: SVKeyword) -> SVToken {
	t := svp_peek(p)
	if t.kw != kw {
		svp_error(p, fmt.tprintf("expected '%s', got '%s'", sv_keyword_name(kw), svp_text(p, t)))
	}
	return svp_advance(p)
}

svp_is_ident :: #force_inline proc(t: SVToken) -> bool {
	return t.kind == .EscapedIdent || (t.kind == .Ident && t.kw == .None)
}

svp_expect_ident :: #force_inline proc(p: ^SVParser2) -> string {
	t := svp_peek(p)
	if !svp_is_ident(t) {
		svp_error(p, fmt.tprintf("expected an identifier, got '%s'", svp_text(p, t)))
	}
	return svp_text(p, svp_advance(p))
}

svp_error :: proc(p: ^SVParser2, msg: string) -> ! {
	t := svp_peek(p)
	panic(fmt.tprintf("SystemVerilog parse error at line %d: %s (near '%s')", svp_token_line(p, t), msg, svp_text(p, t)))
}

svp_at_eof :: #force_inline proc(p: ^SVParser2) -> bool { return svp_at(p, .EOF) }

// ---------------------------------------------------------------------------------------
// Flat node construction
// ---------------------------------------------------------------------------------------

// Chunks are allocated non-zeroed: every append writes the complete entry before
// it can be observed, so small files never pay to clear a whole block.
svp_chunk :: proc(p: ^SVParser2, $T: typeid) -> []T {
	bytes, err := mem.alloc_bytes_non_zeroed(size_of(T) * SV_CHUNK_SIZE, align_of(T), p.allocator)
	ensure(err == nil, "SystemVerilog AST allocation failed")
	return (cast([^]T)raw_data(bytes))[:SV_CHUNK_SIZE]
}

svp_node :: #force_inline proc(p: ^SVParser2, kind: SVNodeKind) -> u32 {
	id := p.ast.node_count
	p.ast.node_count = id + 1
	if id < SV_FIRST_NODE {
		p.ast.first_nodes[id] = SVNode {
			kind = kind,
		}
		return id
	}
	index := id - SV_FIRST_NODE
	if int(index >> SV_CHUNK_SHIFT) >= len(p.ast.node_chunks) {
		append(&p.ast.node_chunks, svp_chunk(p, SVNode))
	}
	#no_bounds_check chunk := p.ast.node_chunks[index >> SV_CHUNK_SHIFT]
	#no_bounds_check node := &chunk[index & SV_CHUNK_MASK]
	node^ = SVNode {
		kind = kind,
	}
	return id
}

svn :: #force_inline proc(p: ^SVParser2, id: u32) -> ^SVNode {
	if id < SV_FIRST_NODE { return &p.ast.first_nodes[id] }
	index := id - SV_FIRST_NODE
	return &p.ast.node_chunks[index >> SV_CHUNK_SHIFT][index & SV_CHUNK_MASK]
}

svp_str :: #force_inline proc(p: ^SVParser2, text: string) -> u32 {
	id := p.ast.string_count
	p.ast.string_count = id + 1
	if id < SV_FIRST_STRING {
		p.ast.first_strings[id] = text
		return id
	}
	index := id - SV_FIRST_STRING
	if int(index >> SV_CHUNK_SHIFT) >= len(p.ast.string_chunks) {
		append(&p.ast.string_chunks, svp_chunk(p, string))
	}
	#no_bounds_check p.ast.string_chunks[index >> SV_CHUNK_SHIFT][index & SV_CHUNK_MASK] = text
	return id
}

svp_str_node :: #force_inline proc(p: ^SVParser2, text: string) -> u32 {
	id := svp_node(p, .Aux_Str)
	svn(p, id).a = svp_str(p, text)
	return id
}

// Child lists are gathered at the nesting depth that is open while the list is
// built. Closing a list appends its ids to ast.kids in one go, so every span is
// contiguous. Most lists are short, so the first SV_LIST_INLINE entries stay in
// the parser; only longer lists touch the allocator.
SV_LIST_MAX_DEPTH :: 32
SV_LIST_INLINE :: 8

svp_list_open :: #force_inline proc(p: ^SVParser2) -> int {
	depth := p.list_depth
	p.list_depth = depth + 1
	ensure(depth < SV_LIST_MAX_DEPTH, "SystemVerilog child-list nesting too deep")
	p.list_lens[depth] = 0
	clear(&p.list_over[depth])
	return depth
}

svp_list_add :: #force_inline proc(p: ^SVParser2, depth: int, id: u32) {
	n := p.list_lens[depth]
	if n < SV_LIST_INLINE {
		p.list_inline[depth][n] = id
	} else {
		append(&p.list_over[depth], id)
	}
	p.list_lens[depth] = n + 1
}

svp_list_get :: #force_inline proc(p: ^SVParser2, depth: int, index: int) -> u32 {
	if index < SV_LIST_INLINE { return p.list_inline[depth][index] }
	return p.list_over[depth][index - SV_LIST_INLINE]
}

// Appends the scratch buffer to the shared child buffer without changing
// list_depth. Used by nodes such as blocks and instances that commit several
// sequentially built lists into one span.
svp_list_commit :: proc(p: ^SVParser2, depth: int) -> SVSpan {
	n := p.list_lens[depth]
	start := u32(len(p.ast.kids))
	inline_n := min(n, SV_LIST_INLINE)
	if inline_n > 0 { append(&p.ast.kids, ..p.list_inline[depth][:inline_n]) }
	if n > SV_LIST_INLINE { append(&p.ast.kids, ..p.list_over[depth][:n - SV_LIST_INLINE]) }
	return SVSpan{start = start, len = u32(n)}
}

svp_list_close :: #force_inline proc(p: ^SVParser2, depth: int) -> SVSpan {
	span := svp_list_commit(p, depth)
	p.list_depth = depth
	return span
}

svp_list_discard :: #force_inline proc(p: ^SVParser2, depth: int) {
	p.list_depth = depth
}

// Attributes are trivia: keep the raw text in the side array and leave the AST
// node stream untouched.
svp_attribute_text :: proc(p: ^SVParser2, start_i, end_i: int) -> string {
	if end_i <= start_i { return "" }
	start := p.toks[start_i]
	last := p.toks[end_i - 1]
	if start.file == last.file {
		#no_bounds_check return string(p.sources[start.file].data[start.off:last.off + u32(last.len)])
	}
	b := strings.builder_make(p.allocator)
	for i in start_i ..< end_i {
		strings.write_string(&b, svp_text(p, p.toks[i]))
	}
	return strings.to_string(b)
}

svp_skip_attributes :: #force_inline proc(p: ^SVParser2) {
	for svp_at(p, .AttrStart) {
		start_i := p.i
		start_tok := svp_peek(p)
		p.i += 1
		for !svp_at_eof(p) && !svp_at(p, .AttrEnd) { p.i += 1 }
		_ = svp_accept(p, .AttrEnd)
		text := svp_attribute_text(p, start_i, p.i)
		path := p.sources[start_tok.file].path
		line := svp_token_line(p, start_tok)
		owner_line := line
		if !svp_at_eof(p) {
			next := svp_peek(p)
			if next.file == start_tok.file { owner_line = svp_token_line(p, next) }
		}
		append(&p.ast.attributes, SVAttribute{text = text, path = path, line = line, owner_line = owner_line})
	}
}

svp_skip_until_kw :: proc(p: ^SVParser2, kw: SVKeyword) {
	for !svp_at_eof(p) {
		if svp_kw_at(p, kw) { svp_bump(p); return }
		svp_bump(p)
	}
	svp_error(p, fmt.tprintf("unterminated construct, expected '%s'", sv_keyword_name(kw)))
}

svp_skip_until_semicolon :: proc(p: ^SVParser2) {
	for !svp_at_eof(p) {
		if svp_accept(p, .Semicolon) { return }
		svp_bump(p)
	}
}

// ---------------------------------------------------------------------------------------
// Top level
// ---------------------------------------------------------------------------------------

svp_parse :: proc(p: ^SVParser2) {
	d := svp_list_open(p)
	for {
		svp_skip_attributes(p)
		if svp_at_eof(p) { break }
		t := svp_peek(p)
		#partial switch t.kw {
		case .Module, .Macromodule: _ = svp_parse_module(p)
		case .Package: _ = svp_parse_package(p)
		case .Interface: _ = svp_parse_interface(p)
		case .Typedef: svp_list_add(p, d, svp_parse_typedef(p))
		case .Parameter, .Localparam: svp_list_add(p, d, svp_parse_param_item(p, t.kw == .Localparam))
		case .Function: svp_list_add(p, d, svp_parse_subroutine(p, false))
		case .Task: svp_list_add(p, d, svp_parse_subroutine(p, true))
		case .Import:
			sp := svp_parse_import_list(p)
			if p.ast.unit_imports.len == 0 {
				p.ast.unit_imports = sp
			} else {
				p.ast.unit_imports.len += sp.len
			}
		case .Class:
			svp_skip_until_kw(p, .Endclass)
			svp_skip_end_label(p)
		case: svp_error(p, fmt.tprintf("unsupported top-level construct '%s'", svp_text(p, t)))
		}
	}
	p.ast.items = svp_list_close(p, d)
}

svp_skip_end_label :: proc(p: ^SVParser2) {
	if svp_accept(p, .Colon) { _ = svp_expect_ident(p) }
}

// ---------------------------------------------------------------------------------------
// Keywords to declaration classes
// ---------------------------------------------------------------------------------------

svp_var_type :: proc(kw: SVKeyword) -> (SVVarType, bool) {
	#partial switch kw {
	case .Logic: return .LOGIC, true
	case .Bit: return .BIT, true
	case .Reg: return .REG, true
	case .Int: return .INT, true
	case .Integer: return .INTEGER, true
	case .Shortint: return .SHORTINT, true
	case .Longint: return .LONGINT, true
	case .Byte: return .BYTE, true
	case .Time: return .TIME, true
	case .Real: return .REAL, true
	case .Shortreal: return .SHORTREAL, true
	case .Realtime: return .REALTIME, true
	case .String: return .STRING, true
	}
	return .IMPLICIT, false
}

svp_net_type :: proc(kw: SVKeyword) -> (SVNetType, bool) {
	#partial switch kw {
	case .Wire: return .WIRE, true
	case .Tri: return .TRI, true
	case .Wand: return .WAND, true
	case .Wor: return .WOR, true
	case .Triand: return .TRIAND, true
	case .Trior: return .TRIOR, true
	case .Tri0: return .TRI0, true
	case .Tri1: return .TRI1, true
	case .Trireg: return .TRIREG, true
	case .Supply0: return .SUPPLY0, true
	case .Supply1: return .SUPPLY1, true
	case .Uwire: return .UWIRE, true
	}
	return .NONE, false
}

svp_port_dir :: proc(kw: SVKeyword) -> (SVPortDir, bool) {
	#partial switch kw {
	case .Input: return .INPUT, true
	case .Output: return .OUTPUT, true
	case .Inout: return .INOUT, true
	case .Ref: return .REF, true
	}
	return .NONE, false
}

svp_is_decl_kw :: proc(kw: SVKeyword) -> bool {
	if _, ok := svp_var_type(kw); ok { return true }
	if _, ok := svp_net_type(kw); ok { return true }
	#partial switch kw {
	case .Var, .Const, .Automatic, .Static, .Signed, .Unsigned, .Enum, .Struct, .Union, .Parameter, .Localparam: return true
	}
	return false
}

svp_is_gate_kw :: proc(kw: SVKeyword) -> bool {
	#partial switch kw {
	case .And,
		 .Nand,
		 .Or,
		 .Nor,
		 .Xor,
		 .Xnor,
		 .Not,
		 .Buf,
		 .Bufif0,
		 .Bufif1,
		 .Notif0,
		 .Notif1,
		 .Nmos,
		 .Pmos,
		 .Cmos,
		 .Rnmos,
		 .Rpmos,
		 .Rcmos,
		 .Tran,
		 .Tranif0,
		 .Tranif1,
		 .Rtran,
		 .Rtranif0,
		 .Rtranif1,
		 .Pullup,
		 .Pulldown:
		return true
	}
	return false
}

// ---------------------------------------------------------------------------------------
// Types, ranges, declarators
// ---------------------------------------------------------------------------------------

svp_parse_range :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect(p, .LBracket)
	r := svp_node(p, .Aux_Range)
	if svp_at(p, .RBracket) {
		// dynamic array / queue-like dimension: no static bounds
		_ = svp_expect(p, .RBracket)
		return r
	}
	// Associative array index type (`[string]`, `[int]`, ...) or queue `[$]`.
	if svp_at(p, .RBracket, 1) {
		t := svp_peek(p)
		_, is_var_type := svp_var_type(t.kw)
		if is_var_type || (t.kind == .SystemIdent && svp_text(p, t) == "$") {
			svp_bump(p)
			_ = svp_expect(p, .RBracket)
			svn(p, r).flags |= SVF_RANGE_IS_SIZE
			return r
		}
	}
	msb := svp_parse_expr(p, 0)
	svn(p, r).a = msb
	if svp_accept(p, .Colon) {
		lsb := svp_parse_expr(p, 0)
		svn(p, r).b = lsb
	}
	_ = svp_expect(p, .RBracket)
	return r
}

svp_parse_type_signing_dims :: proc(p: ^SVParser2, data: u32) -> u32 {
	if svp_accept_kw(p, .Signed) {
		svn(p, data).flags |= SVF_DATA_SIGNED
	} else if svp_accept_kw(p, .Unsigned) {
		svn(p, data).flags &~= SVF_DATA_SIGNED
	}
	d := svp_list_open(p)
	for svp_at(p, .LBracket) {
		svp_list_add(p, d, svp_parse_range(p))
	}
	svn(p, data).span = svp_list_close(p, d)
	return data
}

svp_parse_type :: proc(p: ^SVParser2, allow_implicit := true) -> u32 {
	for {
		t := svp_peek(p)
		if t.kw == .Var || t.kw == .Const || t.kw == .Automatic || t.kw == .Static {
			svp_bump(p)
			continue
		}
		break
	}
	data := svp_node(p, .Aux_DataType)
	dn := svn(p, data)
	dn.a = SV_NONE
	dn.b = SV_NONE
	dn.c = SV_NONE
	t := svp_peek(p)
	if vt, ok := svp_var_type(t.kw); ok {
		svp_bump(p)
		dn.flags = u16(vt) & SVF_DATA_VARTYPE_MASK
	} else if t.kw == .Enum {
		svp_bump(p)
		spec := svp_parse_type_spec(p, .ENUM)
		dn.c = spec
	} else if t.kw == .Struct || t.kw == .Union {
		svp_bump(p)
		spec := svp_parse_type_spec(p, t.kw == .Struct ? .STRUCT : .UNION)
		dn.c = spec
	} else if svp_is_ident(t) {
		scope, name := svp_parse_scoped_type_name(p)
		dn.a = svp_str(p, name)
		dn.b = scope == "" ? SV_NONE : svp_str(p, scope)
	} else if !allow_implicit {
		svp_error(p, "expected a data type")
	}
	return svp_parse_type_signing_dims(p, data)
}

svp_parse_scoped_type_name :: proc(p: ^SVParser2) -> (scope: string, name: string) {
	name = svp_expect_ident(p)
	if svp_accept(p, .ColonColon) {
		scope = name
		name = svp_expect_ident(p)
	}
	return
}

svp_parse_type_spec :: proc(p: ^SVParser2, kind: SVTypeSpecKind) -> u32 {
	spec := svp_node(p, .Aux_TypeSpec)
	sn := svn(p, spec)
	sn.a = SV_NONE
	sn.flags = u16(kind) & SVF_TYPESPEC_KIND_MASK
	if kind == .ENUM {
		if !svp_at(p, .LBrace) {
			base := svp_parse_type(p)
			sn.a = base
		}
		_ = svp_expect(p, .LBrace)
		d := svp_list_open(p)
		for !svp_at(p, .RBrace) {
			entry := svp_node(p, .Aux_EnumName)
			en := svn(p, entry)
			en.b = SV_NONE
			name := svp_expect_ident(p)
			en.a = svp_str(p, name)
			if svp_accept(p, .LBracket) {
				for !svp_at(p, .RBracket) && !svp_at_eof(p) { svp_bump(p) }
				_ = svp_expect(p, .RBracket)
			}
			if svp_accept(p, .Assign) {
				value := svp_parse_expr(p, 0)
				en.b = value
			}
			svp_list_add(p, d, entry)
			if !svp_accept(p, .Comma) { break }
		}
		sn.span = svp_list_close(p, d)
		_ = svp_expect(p, .RBrace)
		return spec
	}
	if svp_accept_kw(p, .Packed) {
		sn.flags |= SVF_TYPESPEC_PACKED
		// IEEE 1800-2023 7.2.1: packed structs/unions may be signed or unsigned.
		if !svp_accept_kw(p, .Signed) { _ = svp_accept_kw(p, .Unsigned) }
	}
	_ = svp_expect(p, .LBrace)
	d := svp_list_open(p)
	for !svp_at(p, .RBrace) {
		data := svp_parse_type(p, false)
		member := svp_node(p, .Aux_StructMember)
		mn := svn(p, member)
		mn.a = data
		md := svp_list_open(p)
		for {
			decl := svp_parse_declarator(p)
			svp_list_add(p, md, decl)
			if !svp_accept(p, .Comma) { break }
		}
		mn.span = svp_list_close(p, md)
		_ = svp_expect(p, .Semicolon)
		svp_list_add(p, d, member)
	}
	sn.span = svp_list_close(p, d)
	_ = svp_expect(p, .RBrace)
	return spec
}

svp_parse_declarator :: #force_inline proc(p: ^SVParser2) -> u32 {
	decl := svp_node(p, .Aux_Declarator)
	n := svn(p, decl)
	n.b = SV_NONE
	name := svp_expect_ident(p)
	n.a = svp_str(p, name)
	d := svp_list_open(p)
	for svp_at(p, .LBracket) {
		svp_list_add(p, d, svp_parse_range(p))
	}
	n.span = svp_list_close(p, d)
	if svp_accept(p, .Assign) {
		n.b = svp_parse_expr(p, 0)
	}
	return decl
}

svp_parse_declarators :: proc(p: ^SVParser2, depth: int) {
	for {
		svp_list_add(p, depth, svp_parse_declarator(p))
		if !svp_accept(p, .Comma) { break }
	}
}

svp_parse_typedef :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Typedef)

	// Forward typedef forms, IEEE 1800-2023 6.18:
	//   typedef [enum|struct|union|class|interface class] type_identifier ;
	//   typedef type_identifier ;
	t := svp_peek(p)
	if t.kw == .Enum || t.kw == .Struct || t.kw == .Union || t.kw == .Class {
		if svp_is_ident(svp_peek(p, 1)) && svp_at(p, .Semicolon, 2) {
			name := svp_text(p, svp_peek(p, 1))
			p.i += 3
			p.ast.type_names[name] = true
			decl := svp_node(p, .Item_TypeDecl)
			svn(p, decl).a = svp_str(p, name)
			svn(p, decl).b = SV_NONE
			svn(p, decl).flags |= SVF_TYPE_FORWARD
			return decl
		}
	}
	if t.kw == .Interface && svp_kw_at(p, .Class, 1) && svp_is_ident(svp_peek(p, 2)) && svp_at(p, .Semicolon, 3) {
		name := svp_text(p, svp_peek(p, 2))
		p.i += 4
		p.ast.type_names[name] = true
		decl := svp_node(p, .Item_TypeDecl)
		svn(p, decl).a = svp_str(p, name)
		svn(p, decl).b = SV_NONE
		svn(p, decl).flags |= SVF_TYPE_FORWARD
		return decl
	}
	if svp_is_ident(t) && svp_at(p, .Semicolon, 1) {
		name := svp_text(p, t)
		p.i += 2
		p.ast.type_names[name] = true
		decl := svp_node(p, .Item_TypeDecl)
		svn(p, decl).a = svp_str(p, name)
		svn(p, decl).b = SV_NONE
		svn(p, decl).flags |= SVF_TYPE_FORWARD
		return decl
	}

	data := svp_parse_type(p, false)
	name := svp_expect_ident(p)
	d := svp_list_open(p)
	for svp_at(p, .LBracket) {
		svp_list_add(p, d, svp_parse_range(p))
	}
	dims := svp_list_close(p, d)
	_ = svp_expect(p, .Semicolon)
	p.ast.type_names[name] = true
	decl := svp_node(p, .Item_TypeDecl)
	svn(p, decl).a = svp_str(p, name)
	svn(p, decl).b = data
	svn(p, decl).span = dims
	return decl
}

svp_parse_param_item :: #force_inline proc(p: ^SVParser2, is_local: bool) -> u32 {
	svp_bump(p)
	decl := svp_parse_param_decl_after_keyword(p, is_local, false)
	_ = svp_expect(p, .Semicolon)
	return decl
}

svp_parse_net_decl_after_keyword :: proc(p: ^SVParser2, net_type: SVNetType, data: u32) -> u32 {
	d := svp_list_open(p)
	svp_parse_declarators(p, d)
	_ = svp_expect(p, .Semicolon)
	span := svp_list_close(p, d)
	decl := svp_node(p, .Item_NetDecl)
	n := svn(p, decl)
	n.a = data
	n.flags = u16(net_type) & 0xF
	n.span = span
	return decl
}

svp_parse_net_data_type :: proc(p: ^SVParser2) -> u32 {
	t := svp_peek(p)
	// IEEE 1800-2023 6.9.2: vectored/scalared are optional advisory keywords
	// on vector net declarations.
	for t.kw == .Scalared || t.kw == .Vectored {
		svp_bump(p)
		t = svp_peek(p)
	}
	if t.kind == .LBracket { return svp_parse_type(p, true) }
	if _, ok := svp_var_type(t.kw); ok { return svp_parse_type(p, true) }
	#partial switch t.kw {
	case .Enum, .Struct, .Union, .Signed, .Unsigned, .Var, .Const, .Automatic, .Static: return svp_parse_type(p, true)
	}
	if svp_is_ident(t) {
		n := svp_peek(p, 1)
		if svp_is_ident(n) || n.kind == .ColonColon { return svp_parse_type(p, false) }
	}
	data := svp_node(p, .Aux_DataType)
	n := svn(p, data)
	n.a = SV_NONE
	n.b = SV_NONE
	n.c = SV_NONE
	return data
}

svp_parse_net_decl :: proc(p: ^SVParser2) -> u32 {
	t := svp_peek(p)
	net_type := SVNetType.NONE
	data: u32
	if nt, ok := svp_net_type(t.kw); ok {
		svp_bump(p)
		net_type = nt
		if svp_accept(p, .Hash) {
			if svp_at(p, .LParen) {
				for !svp_at(p, .RParen) && !svp_at_eof(p) { svp_bump(p) }
				_ = svp_expect(p, .RParen)
			} else { svp_bump(p) }
		}
		svp_skip_strengths(p)
		data = svp_parse_net_data_type(p)
	} else {
		data = svp_parse_net_data_type(p)
	}
	return svp_parse_net_decl_after_keyword(p, net_type, data)
}

svp_parse_param_assignments :: proc(p: ^SVParser2, in_port_list: bool, depth: int, stop_at_group := false) {
	for {
		a := svp_node(p, .Aux_ParamAssign)
		svn(p, a).b = SV_NONE
		svn(p, a).c = SV_NONE
		name := svp_expect_ident(p)
		svn(p, a).a = svp_str(p, name)
		d := svp_list_open(p)
		for svp_at(p, .LBracket) {
			svp_list_add(p, d, svp_parse_range(p))
		}
		svn(p, a).span = svp_list_close(p, d)
		if svp_accept(p, .Assign) {
			value := svp_parse_expr(p, 0)
			svn(p, a).b = value
		}
		svp_list_add(p, depth, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
		if stop_at_group && in_port_list && svp_param_comma_starts_group(p) { p.i -= 1; break }
	}
}

svp_parse_type_param_decl :: proc(p: ^SVParser2, is_local: bool, in_port_list: bool) -> u32 {
	decl := svp_node(p, .Item_ParamDecl)
	svn(p, decl).a = SV_NONE
	svn(p, decl).flags = SVF_PARAM_TYPE | (is_local ? SVF_PARAM_LOCAL : 0)
	d := svp_list_open(p)
	for {
		a := svp_node(p, .Aux_ParamAssign)
		svn(p, a).b = SV_NONE
		svn(p, a).c = SV_NONE
		name := svp_expect_ident(p)
		svn(p, a).a = svp_str(p, name)
		p.ast.type_names[name] = true
		if svp_accept(p, .Assign) {
			v := svp_parse_type(p, true)
			svn(p, a).c = v
		}
		svp_list_add(p, d, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
		if in_port_list && svp_param_comma_starts_group(p) { p.i -= 1; break }
	}
	svn(p, decl).span = svp_list_close(p, d)
	return decl
}

svp_parse_param_decl_after_keyword :: proc(p: ^SVParser2, is_local: bool, in_port_list: bool) -> u32 {
	if svp_accept_kw(p, .Type) {
		return svp_parse_type_param_decl(p, is_local, in_port_list)
	}
	decl := svp_node(p, .Item_ParamDecl)
	svn(p, decl).flags = is_local ? SVF_PARAM_LOCAL : 0
	data := svp_parse_type_for_param(p)
	svn(p, decl).a = data
	d := svp_list_open(p)
	svp_parse_param_assignments(p, in_port_list, d)
	svn(p, decl).span = svp_list_close(p, d)
	return decl
}

// ---------------------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------------------

SVPBinInfo_Entry :: struct {
	kind: SVTokenKind,
	prec: u8,
	op:   SVBinOp,
}

svp_bin_prec_lut: [SVTokenKind]u8
svp_bin_op_lut: [SVTokenKind]SVBinOp

@(rodata)
svp_bin_table := [?]SVPBinInfo_Entry {
	{.Question, 1, .ADD}, // handled before the loop; keeps nested parses bounded
	{.PipePipe, 2, .LOG_OR},
	{.AmpAmp, 3, .LOG_AND},
	{.Pipe, 4, .BIT_OR},
	{.Caret, 5, .BIT_XOR},
	{.CaretTilde, 5, .BIT_XNOR},
	{.TildeCaret, 5, .BIT_XNOR},
	{.Amp, 6, .BIT_AND},
	{.EqEq, 7, .EQ},
	{.NotEq, 7, .NE},
	{.CaseEq, 7, .CASE_EQ},
	{.CaseNeq, 7, .CASE_NE},
	{.WildEq, 7, .WILD_EQ},
	{.WildNeq, 7, .WILD_NE},
	{.Lt, 8, .LT},
	{.Le, 8, .LE},
	{.Gt, 8, .GT},
	{.Ge, 8, .GE},
	{.Shl, 9, .SHL},
	{.Shr, 9, .SHR},
	{.Ashl, 9, .ASH_L},
	{.Ashr, 9, .ASH_R},
	{.Plus, 10, .ADD},
	{.Minus, 10, .SUB},
	{.Star, 11, .MUL},
	{.Slash, 11, .DIV},
	{.Percent, 11, .MOD},
	{.Pow, 12, .POW},
}

@(init)
svp_bin_init :: proc "contextless" () {
	for e in svp_bin_table {
		svp_bin_prec_lut[e.kind] = e.prec
		svp_bin_op_lut[e.kind] = e.op
	}
}

svp_expr_binary :: #force_inline proc(p: ^SVParser2, op: SVBinOp, lhs, rhs: u32) -> u32 {
	id := svp_node(p, .Expr_Binary)
	n := svn(p, id)
	n.a = u32(op)
	n.b = lhs
	n.c = rhs
	return id
}

svp_expr_unary :: #force_inline proc(p: ^SVParser2, op: SVUnOp, operand: u32) -> u32 {
	id := svp_node(p, .Expr_Unary)
	n := svn(p, id)
	n.a = u32(op)
	n.b = operand
	return id
}

svp_expr_incdec :: #force_inline proc(p: ^SVParser2, operand: u32, is_dec, is_prefix: bool) -> u32 {
	id := svp_node(p, .Expr_IncDec)
	n := svn(p, id)
	n.a = operand
	if is_dec { n.flags |= SVF_INCDEC_DEC }
	if is_prefix { n.flags |= SVF_INCDEC_PREFIX }
	return id
}

svp_expr_ident :: #force_inline proc(p: ^SVParser2, name: string) -> u32 {
	return sv_imm(SV_IMM_IDENT, svp_str(p, name))
}

svp_expr_string :: #force_inline proc(p: ^SVParser2, text: string) -> u32 {
	return sv_imm(SV_IMM_STRING, svp_str(p, text))
}

svp_small_number :: #force_inline proc(p: ^SVParser2, value: u64, width: u32, base: SVNumberBase, is_signed: bool, time_unit: SVTimeUnit) -> u32 {
	id := p.ast.small_number_count
	p.ast.small_number_count = id + 1
	small := SVSmallNumber {
		value     = value,
		width     = width,
		base      = base,
		is_signed = is_signed,
		time_unit = time_unit,
	}
	if id < SV_FIRST_SMALL {
		p.ast.first_small_numbers[id] = small
		return sv_imm(SV_IMM_NUMBER, id)
	}
	index := id - SV_FIRST_SMALL
	if int(index >> SV_CHUNK_SHIFT) >= len(p.ast.small_number_chunks) {
		append(&p.ast.small_number_chunks, svp_chunk(p, SVSmallNumber))
	}
	#no_bounds_check p.ast.small_number_chunks[index >> SV_CHUNK_SHIFT][index & SV_CHUNK_MASK] = small
	return sv_imm(SV_IMM_NUMBER, id)
}

// Most expressions are a single unary/primary with no following operator. Keep
// that case in a small inlined wrapper; the precedence loop's frame (inside,
// ternary and binary temporaries) is only built when an operator follows.
svp_parse_expr :: #force_inline proc(p: ^SVParser2, min_prec: u8 = 0) -> u32 {
	lhs := svp_parse_unary(p)
	kind := svp_peek(p).kind
	if !(kind == .Question && min_prec <= 1) && !(min_prec <= 8 && svp_kw_at(p, .Inside)) {
		prec := svp_bin_prec_lut[kind]
		if prec == 0 || prec < min_prec { return lhs }
	}
	return svp_parse_expr_slow(p, min_prec, lhs)
}

svp_parse_expr_slow :: proc(p: ^SVParser2, min_prec: u8, lhs_in: u32) -> u32 {
	lhs := lhs_in
	for {
		// inside { range_list }
		if min_prec <= 8 && svp_kw_at(p, .Inside) {
			svp_bump(p)
			_ = svp_expect(p, .LBrace)
			d := svp_list_open(p)
			for {
				r := svp_node(p, .Aux_InsideRange)
				rn := svn(p, r)
				rn.b = SV_NONE
				if svp_accept(p, .LBracket) {
					lo := svp_parse_expr(p, 0)
					rn.a = lo
					if svp_accept(p, .Colon) {
						hi := svp_parse_expr(p, 0)
						rn.b = hi
						rn.flags |= 0x1
					}
					_ = svp_expect(p, .RBracket)
				} else {
					lo := svp_parse_expr(p, 0)
					rn.a = lo
				}
				svp_list_add(p, d, r)
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .RBrace)
			inside := svp_node(p, .Expr_Inside)
			inn := svn(p, inside)
			inn.a = lhs
			inn.span = svp_list_close(p, d)
			lhs = inside
			continue
		}
		kind := svp_peek(p).kind
		if kind == .Question && min_prec <= 1 {
			svp_bump(p)
			t := svp_parse_expr(p, 0)
			_ = svp_expect(p, .Colon)
			f := svp_parse_expr(p, 1)
			id := svp_node(p, .Expr_Ternary)
			n := svn(p, id)
			n.a = lhs
			n.b = t
			n.c = f
			lhs = id
			continue
		}
		prec := svp_bin_prec_lut[kind]
		if prec == 0 || prec < min_prec { break }
		svp_bump(p)
		rhs := svp_parse_expr(p, prec + 1)
		lhs = svp_expr_binary(p, svp_bin_op_lut[kind], lhs, rhs)
	}
	return lhs
}

svp_is_unop_token :: #force_inline proc(kind: SVTokenKind) -> bool {
	#partial switch kind {
	case .Plus, .Minus, .Bang, .Tilde, .Amp, .TildeAmp, .Pipe, .TildePipe, .Caret, .CaretTilde, .TildeCaret, .Inc, .Dec: return true
	}
	return false
}

// Most operands have no unary operator and no attributes. Keep that case in a
// small inlined wrapper so the large recursive/sret frame is only built when a
// prefix operator or attribute actually appears.
svp_parse_unary :: #force_inline proc(p: ^SVParser2) -> u32 {
	if !svp_at(p, .AttrStart) {
		if !svp_is_unop_token(svp_peek(p).kind) {
			return svp_parse_postfix(p, svp_parse_primary(p))
		}
	}
	return svp_parse_unary_slow(p)
}

svp_parse_unary_slow :: proc(p: ^SVParser2) -> u32 {
	svp_skip_attributes(p)
	op: SVUnOp
	has_op := true
	t := svp_peek(p)
	#partial switch t.kind {
	case .Plus: op = .PLUS
	case .Minus: op = .MINUS
	case .Bang: op = .NOT
	case .Tilde: op = .BIT_NOT
	case .Amp: op = .RED_AND
	case .TildeAmp: op = .RED_NAND
	case .Pipe: op = .RED_OR
	case .TildePipe: op = .RED_NOR
	case .Caret: op = .RED_XOR
	case .CaretTilde, .TildeCaret: op = .RED_XNOR
	case .Inc, .Dec:
		is_dec := t.kind == .Dec
		svp_bump(p)
		operand := svp_parse_unary(p)
		return svp_expr_incdec(p, operand, is_dec, true)
	case: has_op = false
	}
	if !has_op { return svp_parse_postfix(p, svp_parse_primary(p)) }
	svp_bump(p)
	operand := svp_parse_unary(p)
	return svp_expr_unary(p, op, operand)
}

svp_parse_postfix :: #force_inline proc(p: ^SVParser2, prefix: u32) -> u32 {
	base := prefix
	if !svp_at(p, .LBracket) && !svp_at(p, .Dot) && !svp_at(p, .Tick) && !svp_at(p, .Inc) && !svp_at(p, .Dec) {
		if sv_node_kind(p.ast, base) != .Expr_Ident || (!svp_at(p, .ColonColon) && !svp_at(p, .LParen)) {
			return base
		}
	}
	return svp_parse_postfix_slow(p, base)
}

svp_parse_postfix_slow :: proc(p: ^SVParser2, base_in: u32) -> u32 {
	base := base_in
	parts_depth := -1

	// Scoped names and calls are handled here too, because statement-leading
	// identifiers arrive without going through primary's scoped-name branch.
	if sv_node_kind(p.ast, base) == .Expr_Ident {
		name := sv_text_of(p.ast, base)
		if svp_accept(p, .ColonColon) {
			member := svp_expect_ident(p)
			if svp_at(p, .LParen) {
				qual := strings.concatenate({name, "::", member}, p.allocator)
				base = svp_parse_call(p, qual, false)
			} else {
				scoped := svp_node(p, .Expr_ScopedName)
				svn(p, scoped).a = svp_str(p, name)
				svn(p, scoped).b = svp_str(p, member)
				base = scoped
			}
		} else if svp_at(p, .LParen) {
			base = svp_parse_call(p, name, false)
		}
	}

	for {
		if svp_accept(p, .LBracket) {
			if parts_depth < 0 { parts_depth = svp_list_open(p) }
			part := svp_node(p, .Aux_SelectPart)
			svn(p, part).a = SV_NONE
			first := svp_parse_expr(p, 0)
			svn(p, part).b = first
			if svp_accept(p, .Colon) {
				svn(p, part).flags = u16(SVSelectKind.PART) & SVF_SELECT_KIND_MASK
				second := svp_parse_expr(p, 0)
				svn(p, part).c = second
				svn(p, part).flags |= SVF_SELECT_HAS_SECOND
			} else if svp_accept(p, .PlusColon) {
				svn(p, part).flags = u16(SVSelectKind.INDEXED_PLUS) & SVF_SELECT_KIND_MASK
				second := svp_parse_expr(p, 0)
				svn(p, part).c = second
				svn(p, part).flags |= SVF_SELECT_HAS_SECOND
			} else if svp_accept(p, .MinusColon) {
				svn(p, part).flags = u16(SVSelectKind.INDEXED_MINUS) & SVF_SELECT_KIND_MASK
				second := svp_parse_expr(p, 0)
				svn(p, part).c = second
				svn(p, part).flags |= SVF_SELECT_HAS_SECOND
			}
			_ = svp_expect(p, .RBracket)
			svp_list_add(p, parts_depth, part)
			continue
		}
		if svp_accept(p, .Dot) {
			member := svp_expect_ident(p)
			if svp_at(p, .LParen) {
				// Method-style call: flatten the dotted path into the call name.
				if sv_node_kind(p.ast, base) == .Expr_Ident {
					b := strings.builder_make(p.allocator)
					strings.write_string(&b, sv_text_of(p.ast, base))
					if parts_depth >= 0 {
						for k in 0 ..< p.list_lens[parts_depth] {
							part := svp_list_get(p, parts_depth, k)
							pn := sv_node(p.ast, part)
							member_text := sv_text(p.ast, pn.a)
							if member_text == "" { svp_error(p, "unsupported method call target") }
							strings.write_byte(&b, '.')
							strings.write_string(&b, member_text)
						}
						svp_list_discard(p, parts_depth)
						parts_depth = -1
					}
					strings.write_byte(&b, '.')
					strings.write_string(&b, member)
					return svp_parse_call(p, strings.to_string(b), false)
				}
				svp_error(p, "method calls are not supported in the synthesizable subset")
			}
			if parts_depth < 0 { parts_depth = svp_list_open(p) }
			part := svp_node(p, .Aux_SelectPart)
			svn(p, part).a = svp_str(p, member)
			svp_list_add(p, parts_depth, part)
			continue
		}
		break
	}

	if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
		svp_bump(p)
		if parts_depth >= 0 { svp_list_discard(p, parts_depth) }
		return svp_parse_cast(p, "", base)
	}
	if svp_at(p, .Inc) || svp_at(p, .Dec) {
		is_dec := svp_at(p, .Dec)
		svp_bump(p)
		selected := base
		if parts_depth >= 0 {
			span := svp_list_close(p, parts_depth)
			if span.len > 0 {
				sel := svp_node(p, .Expr_Select)
				svn(p, sel).a = base
				svn(p, sel).span = span
				selected = sel
			}
		}
		return svp_expr_incdec(p, selected, is_dec, false)
	}
	if parts_depth < 0 { return base }
	span := svp_list_close(p, parts_depth)
	if span.len == 0 { return base }
	sel := svp_node(p, .Expr_Select)
	n := svn(p, sel)
	n.a = base
	n.span = span
	return sel
}

// Numbers and plain identifiers are the overwhelming majority of primaries.
// Handling them in a small inlined wrapper keeps the large switch below (casts,
// aggregates, calls, scoped names) out of the hot frame.
svp_parse_primary :: #force_inline proc(p: ^SVParser2) -> u32 {
	t := svp_peek(p)
	if t.kind == .Number { return svp_parse_number(p) }
	if (t.kind == .Ident || t.kind == .EscapedIdent) &&
	   t.kw == .None &&
	   !svp_at(p, .ColonColon, 1) &&
	   !svp_at(p, .LParen, 1) &&
	   !svp_at(p, .Tick, 1) {
		return svp_expr_ident(p, svp_text(p, svp_advance(p)))
	}
	return svp_parse_primary_slow(p, t)
}

svp_parse_primary_slow :: proc(p: ^SVParser2, t: SVToken) -> u32 {
	if t.kw != .None {
		_, is_var_type := svp_var_type(t.kw)
		if t.kw == .Signed || t.kw == .Unsigned || t.kw == .Void || (is_var_type && svp_at(p, .Tick, 1)) {
			target := svp_text(p, svp_advance(p))
			_ = svp_expect(p, .Tick)
			return svp_parse_cast(p, target, SV_NONE)
		}
	}
	#partial switch t.kind {
	case .LParen:
		svp_bump(p)
		e := svp_parse_expr(p, 0)
		_ = svp_expect(p, .RParen)
		if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
			svp_bump(p)
			return svp_parse_cast(p, "", e)
		}
		return e
	case .LBrace: return svp_parse_concat(p)
	case .Tick:
		if svp_at(p, .LBrace, 1) {
			svp_bump(p)
			return svp_parse_aggregate(p, "", "")
		}
		return svp_parse_number(p)
	case .Number: return svp_parse_number(p)
	case .String:
		svp_bump(p)
		return svp_expr_string(p, svp_text(p, t))
	case .SystemIdent:
		name := svp_text(p, svp_advance(p))
		if svp_at(p, .LParen) { return svp_parse_call(p, name, true) }
		id := svp_node(p, .Expr_Call)
		n := svn(p, id)
		n.a = svp_str(p, name)
		n.flags |= SVF_CALL_SYSTEM
		return id
	case .EscapedIdent, .Ident:
		if t.kw != .None { svp_error(p, fmt.tprintf("unexpected keyword '%s' in expression", svp_text(p, t))) }
		name := svp_text(p, svp_advance(p))
		if svp_accept(p, .ColonColon) {
			member := svp_expect_ident(p)
			if svp_at(p, .LParen) {
				qual := strings.concatenate({name, "::", member}, p.allocator)
				return svp_parse_call(p, qual, false)
			}
			if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
				svp_bump(p)
				qual := strings.concatenate({name, "::", member}, p.allocator)
				return svp_parse_cast(p, qual, SV_NONE)
			}
			if svp_at(p, .Tick) && svp_at(p, .LBrace, 1) {
				svp_bump(p)
				return svp_parse_aggregate(p, name, member)
			}
			scoped := svp_node(p, .Expr_ScopedName)
			svn(p, scoped).a = svp_str(p, name)
			svn(p, scoped).b = svp_str(p, member)
			return scoped
		}
		if svp_at(p, .LParen) { return svp_parse_call(p, name, false) }
		if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
			svp_bump(p)
			return svp_parse_cast(p, name, SV_NONE)
		}
		if svp_at(p, .Tick) && svp_at(p, .LBrace, 1) {
			svp_bump(p)
			return svp_parse_aggregate(p, "", name)
		}
		return svp_expr_ident(p, name)
	}
	svp_error(p, fmt.tprintf("unexpected token '%s' in expression", svp_text(p, t)))
}

svp_parse_cast :: proc(p: ^SVParser2, target: string, size: u32) -> u32 {
	_ = svp_expect(p, .LParen)
	operand := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	node := svp_node(p, .Expr_Cast)
	nn := svn(p, node)
	nn.b = target == "" ? SV_NONE : svp_str(p, target)
	nn.d = SV_NONE
	nn.c = operand
	if target == "signed" || target == "unsigned" {
		nn.a = u32(SVCastKind.SIGNING)
	} else if len(target) > 0 {
		nn.a = u32(SVCastKind.TYPE)
	} else {
		nn.a = u32(SVCastKind.SIZE)
		nn.d = size
	}
	return node
}

svp_parse_call :: proc(p: ^SVParser2, name: string, is_system: bool) -> u32 {
	_ = svp_expect(p, .LParen)
	call := svp_node(p, .Expr_Call)
	cn := svn(p, call)
	cn.a = svp_str(p, name)
	if is_system { cn.flags |= SVF_CALL_SYSTEM }
	d := svp_list_open(p)
	for !svp_at(p, .RParen) {
		arg := svp_node(p, .Aux_CallArg)
		an := svn(p, arg)
		an.a = SV_NONE
		an.b = SV_NONE
		if svp_at(p, .Dot) {
			svp_bump(p)
			aname := svp_expect_ident(p)
			an.a = svp_str(p, aname)
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) {
				value := svp_parse_expr(p, 0)
				an.b = value
			}
			_ = svp_expect(p, .RParen)
		} else if !svp_at(p, .Comma) {
			value := svp_parse_expr(p, 0)
			an.b = value
		}
		svp_list_add(p, d, arg)
		if !svp_accept(p, .Comma) { break }
	}
	cn.span = svp_list_close(p, d)
	_ = svp_expect(p, .RParen)
	return call
}

svp_parse_concat :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect(p, .LBrace)
	if svp_at(p, .RBrace) {
		svp_bump(p)
		empty := svp_node(p, .Expr_Concat)
		svn(p, empty).a = SV_NONE
		return empty
	}
	// Streaming concatenation: {<< [slice] { a, b }} / {>> ...}
	if (svp_at(p, .Shl) && svp_text(p, svp_peek(p)) == "<<") || (svp_at(p, .Shr) && svp_text(p, svp_peek(p)) == ">>") {
		stream := svp_node(p, .Expr_Stream)
		sn := svn(p, stream)
		if svp_at(p, .Shr) { sn.flags |= SVF_STREAM_RIGHT }
		svp_bump(p)
		if !svp_at(p, .LBrace) {
			slice := svp_parse_expr(p, 0)
			sn.a = slice
		}
		_ = svp_expect(p, .LBrace)
		d := svp_list_open(p)
		for {
			svp_list_add(p, d, svp_parse_expr(p, 0))
			if !svp_accept(p, .Comma) { break }
		}
		sn.span = svp_list_close(p, d)
		_ = svp_expect(p, .RBrace)
		_ = svp_expect(p, .RBrace)
		return stream
	}
	first := svp_parse_expr(p, 0)
	if svp_at(p, .LBrace) {
		// replication
		svp_bump(p)
		d := svp_list_open(p)
		for {
			svp_list_add(p, d, svp_parse_expr(p, 0))
			if !svp_accept(p, .Comma) { break }
		}
		span := svp_list_close(p, d)
		_ = svp_expect(p, .RBrace)
		_ = svp_expect(p, .RBrace)
		rep := svp_node(p, .Expr_Concat)
		n := svn(p, rep)
		n.a = first
		n.span = span
		return rep
	}
	d := svp_list_open(p)
	svp_list_add(p, d, first)
	for svp_accept(p, .Comma) {
		svp_list_add(p, d, svp_parse_expr(p, 0))
	}
	span := svp_list_close(p, d)
	_ = svp_expect(p, .RBrace)
	node := svp_node(p, .Expr_Concat)
	n := svn(p, node)
	n.a = SV_NONE
	n.span = span
	return node
}

svp_aggregate_is_replicated :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if !(svp_is_ident(t) || t.kind == .Number || t.kind == .LParen) { return false }
	if svp_at(p, .LBrace, 1) { return true }
	if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && svp_is_ident(svp_peek(p, 2)) && svp_at(p, .LBrace, 3) { return true }
	return false
}

svp_parse_aggregate :: proc(p: ^SVParser2, type_scope, type_name: string) -> u32 {
	_ = svp_expect(p, .LBrace)
	agg := svp_node(p, .Expr_Aggregate)
	an := svn(p, agg)
	an.a = SV_NONE
	an.b = SV_NONE
	an.c = SV_NONE
	if type_scope != "" { an.b = svp_str(p, type_scope) }
	if type_name != "" { an.a = svp_str(p, type_name) }
	if svp_at(p, .RBrace) {
		svp_bump(p)
		return agg
	}
	if svp_aggregate_is_replicated(p) {
		count := svp_parse_expr(p, 0)
		an.c = count
		_ = svp_expect(p, .LBrace)
	}
	d := svp_list_open(p)
	for !svp_at(p, .RBrace) {
		entry := svp_node(p, .Aux_AggregateEntry)
		en := svn(p, entry)
		en.a = SV_NONE
		en.b = SV_NONE
		if svp_is_ident(svp_peek(p)) && svp_at(p, .Colon, 1) {
			key := svp_expect_ident(p)
			en.a = svp_str(p, key)
			_ = svp_expect(p, .Colon)
		} else if (svp_at(p, .String) || svp_at(p, .Number)) && svp_at(p, .Colon, 1) {
			key := svp_text(p, svp_advance(p))
			en.a = svp_str(p, key)
			_ = svp_expect(p, .Colon)
		} else if svp_kw_at(p, .Default) {
			svp_bump(p)
			_ = svp_expect(p, .Colon)
			en.a = svp_str(p, "default")
		}
		value := svp_parse_expr(p, 0)
		en.b = value
		svp_list_add(p, d, entry)
		if !svp_accept(p, .Comma) { break }
	}
	an.span = svp_list_close(p, d)
	_ = svp_expect(p, .RBrace)
	if an.c != SV_NONE { _ = svp_expect(p, .RBrace) }
	return agg
}

sv_small_number_fits :: #force_inline proc(raw: string, base: SVNumberBase) -> bool {
	#partial switch base {
	case .BIN: return len(raw) <= 64
	case .OCT: return len(raw) <= 21
	case .HEX: return len(raw) <= 16
	}
	return len(raw) <= 19
}

// Fast path for the dominant RTL literal shape: [width]'[s]base digits, with
// no x/z/? digits and a width that fits the small-number representation. It
// decodes the prefix and the value in one pass and skips the generic literal
// machinery (real/exponent/unit/unbased checks and the second decode pass).
svp_fast_based_number :: #force_inline proc(text: string) -> (value: u64, width: u32, base: SVNumberBase, signed: bool, ok: bool) {
	n := len(text)
	if n < 4 { return 0, 0, .DEC, false, false }
	i := 0
	for i < n {
		c := text[i]
		if c == '_' { i += 1; continue }
		d := u32(c - '0')
		if d > 9 { break }
		width = width * 10 + d
		if width > 64 { return 0, 0, .DEC, false, false }
		i += 1
	}
	if i == 0 || i >= n || text[i] != '\'' { return 0, 0, .DEC, false, false }
	i += 1
	if i < n && (text[i] == 's' || text[i] == 'S') { signed = true; i += 1 }
	if i >= n { return 0, 0, .DEC, false, false }
	radix: u64
	max_digits: int
	switch text[i] {
	case 'b', 'B':
		base = .BIN; radix = 2; max_digits = 64
	case 'o', 'O':
		base = .OCT; radix = 8; max_digits = 21
	case 'd', 'D':
		base = .DEC; radix = 10; max_digits = 19
	case 'h', 'H':
		base = .HEX; radix = 16; max_digits = 16
	case: return 0, 0, .DEC, false, false
	}
	i += 1
	digits := 0
	for i < n {
		c := text[i]
		if c == '_' { i += 1; continue }
		d: u64
		switch c {
		case '0' ..= '9': d = u64(c - '0')
		case 'a' ..= 'f': d = u64(c - 'a' + 10)
		case 'A' ..= 'F': d = u64(c - 'A' + 10)
		case: return 0, 0, .DEC, false, false
		}
		if d >= radix { return 0, 0, .DEC, false, false }
		value = value * radix + d
		digits += 1
		if digits > max_digits { return 0, 0, .DEC, false, false }
		i += 1
	}
	if digits == 0 { return 0, 0, .DEC, false, false }
	return value, width, base, signed || width == 0, true
}

// Most literals in RTL are based integers. Detect those before entering the
// generic literal function, whose frame holds the real/unit/unbased state.
svp_parse_number :: #force_inline proc(p: ^SVParser2) -> u32 {
	text := svp_text(p, svp_peek(p))
	if value, width, base, signed, ok := svp_fast_based_number(text); ok {
		_ = svp_advance(p)
		return svp_small_number(p, value, width, base, signed, .NONE)
	}
	return svp_parse_number_slow(p)
}

svp_number_body :: #force_inline proc(text: string, start: int) -> (body: string, base: SVNumberBase, signed: bool, based: bool) {
	body = text[start:]
	if len(body) > 0 && (body[0] == 's' || body[0] == 'S') {
		signed = true
		body = body[1:]
	}
	if len(body) > 0 && svt_is_base_char(body[0]) {
		base = sv_number_base_of(body[0])
		body = body[1:]
		if len(body) > 0 && (body[0] == ' ' || body[0] == '\t' || body[len(body) - 1] == ' ' || body[len(body) - 1] == '\t') {
			body = strings.trim_space(body)
		}
		based = true
	}
	return
}

svp_parse_number_slow :: proc(p: ^SVParser2) -> u32 {
	t := svp_advance(p)
	text := svp_text(p, t)
	width: u32
	base := SVNumberBase.DEC
	signed := false
	is_unbased := false
	is_real := false
	real_value: f64
	raw := text
	time_unit := SVTimeUnit.NONE

	// One pass classifies the literal and accumulates the size prefix. Numbers are
	// short; a single loop avoids half a dozen string-search calls per token.
	apostrophe := -1
	has_dot := false
	has_exp := false
	prefix: u32
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '\'' {
			apostrophe = i
			width = prefix
			break // based literals end the prefix; their digits are decoded later
		}
		if c == '.' { has_dot = true }
		if c == 'e' || c == 'E' { has_exp = true }
		if c >= '0' && c <= '9' {
			prefix = prefix * 10 + u32(c - '0')
		}
	}

	// Macro-expanded size: XLEN'd4 arrives as Number("32") + Number("'d4").
	if apostrophe < 0 && svp_at(p, .Number) {
		next_text := svp_text(p, svp_peek(p))
		if len(next_text) > 0 && next_text[0] == '\'' {
			t2 := svp_advance(p)
			text = strings.concatenate({text, svp_text(p, t2)}, p.allocator)
			apostrophe = strings.index_byte(text, '\'')
		}
	}

	if apostrophe > 0 { width = prefix }
	if apostrophe == 0 {
		// unbased ('0/'1/'x/'z) or unsized based ('hFF)
		body, b, s, based := svp_number_body(text, 1)
		signed = s
		if based {
			base = b
			raw = body
		} else {
			is_unbased = true
			raw = body
		}
	} else if apostrophe > 0 {
		body, b, s, based := svp_number_body(text, apostrophe + 1)
		signed = s
		if based {
			base = b
			raw = body
		}
	} else {
		// Real literal?
		if has_dot || has_exp {
			if v, ok := strconv.parse_f64(text); ok {
				is_real = true
				real_value = v
			}
		}
		// trailing time unit
		n := len(text)
		if n >= 2 && text[n - 1] == 's' {
			switch text[n - 2] {
			case 'm':
				time_unit = .MS; raw = text[:n - 2]
			case 'u':
				time_unit = .US; raw = text[:n - 2]
			case 'n':
				time_unit = .NS; raw = text[:n - 2]
			case 'p':
				time_unit = .PS; raw = text[:n - 2]
			case 'f':
				time_unit = .FS; raw = text[:n - 2]
			}
		}
		if time_unit == .NONE && n >= 1 && text[n - 1] == 's' {
			time_unit = .S
			raw = text[:n - 1]
		}
	}
	value: u64
	has_x_z: bool
	if !is_real && !is_unbased {
		value, has_x_z = sv_decode_number(raw, base)
	} else if is_unbased {
		switch raw {
		case "0": value = 0
		case "1": value = 1
		case: has_x_z = true
		}
		signed = true
	}
	signed_value := signed || (width == 0 && !has_x_z)
	if !is_real && !is_unbased && !has_x_z && width <= 64 && sv_small_number_fits(raw, base) {
		return svp_small_number(p, value, width, base, signed_value, time_unit)
	}
	number_index := p.ast.number_count
	if int(number_index >> SV_CHUNK_SHIFT) >= len(p.ast.number_chunks) {
		append(&p.ast.number_chunks, svp_chunk(p, SVNumber))
	}
	p.ast.number_count = number_index + 1
	#no_bounds_check p.ast.number_chunks[number_index >> SV_CHUNK_SHIFT][number_index & SV_CHUNK_MASK] = SVNumber {
		raw        = raw,
		width      = width,
		base       = base,
		is_signed  = signed_value,
		is_unbased = is_unbased,
		is_real    = is_real,
		real_value = real_value,
		value      = value,
		has_x_z    = has_x_z,
		time_unit  = time_unit,
	}
	id := svp_node(p, .Aux_NumberFull)
	svn(p, id).a = number_index
	return id
}

// ---------------------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------------------

svp_parse_tokens :: proc(ast: ^SystemVerilogAST, toks: []SVToken, sources: []SVSource, filepath: string, allocator: mem.Allocator) {
	p := SVParser2 {
		toks      = toks,
		sources   = sources,
		ast       = ast,
		allocator = allocator,
		filepath  = filepath,
		module    = SV_NONE,
		iface     = SV_NONE,
	}
	// String ref 0 is reserved for "no text" so zero-initialized node slots are
	// always safe to read through sv_text. It needs no stored entry.
	if ast.string_count == 0 { ast.string_count = 1 }
	old := context.allocator
	context.allocator = allocator
	defer context.allocator = old
	svp_parse(&p)
}

// ---------------------------------------------------------------------------------------
// Imports, packages, interfaces, modules
// ---------------------------------------------------------------------------------------

// Parses one import statement (possibly several comma-separated imports) and
// appends Aux_Import nodes to ast.imports. Returns the span of newly added ids.
svp_parse_import_list :: proc(p: ^SVParser2) -> SVSpan {
	_ = svp_expect_kw(p, .Import)
	start := u32(len(p.ast.imports))
	if svp_at(p, .String) {
		// import "DPI-C" ...; (verification only)
		svp_skip_until_semicolon(p)
		return SVSpan{start = start, len = 0}
	}
	for {
		pkg := svp_expect_ident(p)
		_ = svp_expect(p, .ColonColon)
		name := "*"
		if svp_accept(p, .Star) {
			// wildcard
		} else {
			name = svp_expect_ident(p)
		}
		node := svp_node(p, .Aux_Import)
		svn(p, node).a = svp_str(p, pkg)
		svn(p, node).b = svp_str(p, name)
		append(&p.ast.imports, node)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
	return SVSpan{start = start, len = u32(len(p.ast.imports)) - start}
}

svp_add_imports :: proc(p: ^SVParser2, owner: enum {
		Module,
		Package,
		Interface,
		Block,
	}, owner_index: u32) {
	sp := svp_parse_import_list(p)
	if sp.len == 0 { return }
	switch owner {
	case .Module:
		m := &p.ast.modules[owner_index]
		if m.imports.len == 0 { m.imports.start = sp.start }
		m.imports.len += sp.len
	case .Package:
		pk := &p.ast.packages[owner_index]
		if pk.imports.len == 0 { pk.imports.start = sp.start }
		pk.imports.len += sp.len
	case .Interface:
		i := &p.ast.interfaces[owner_index]
		if i.imports.len == 0 { i.imports.start = sp.start }
		i.imports.len += sp.len
	case .Block:
		n := svn(p, owner_index)
		if n.c == 0 { n.b = sp.start }
		n.c += sp.len
	}
}

svp_parse_package :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Package)
	pkg_index := u32(len(p.ast.packages))
	append(&p.ast.packages, SVPackage{})
	name := svp_expect_ident(p)
	p.ast.packages[pkg_index].name = name
	_ = svp_expect(p, .Semicolon)
	d := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endpackage) {
		svp_parse_package_item(p, pkg_index, d)
	}
	p.ast.packages[pkg_index].items = svp_list_close(p, d)
	_ = svp_expect_kw(p, .Endpackage)
	svp_skip_end_label(p)
	if _, exists := p.ast.package_hash_map[name]; exists {
		svp_error(p, fmt.tprintf("duplicate package '%s'", name))
	}
	p.ast.package_hash_map[name] = pkg_index
	return pkg_index
}

svp_parse_package_item :: proc(p: ^SVParser2, pkg_index: u32, depth: int) {
	svp_skip_attributes(p)
	if svp_accept(p, .Semicolon) { return }
	t := svp_peek(p)
	#partial switch t.kw {
	case .Typedef: svp_list_add(p, depth, svp_parse_typedef(p))
	case .Parameter, .Localparam: svp_list_add(p, depth, svp_parse_param_item(p, t.kw == .Localparam))
	case .Function: svp_list_add(p, depth, svp_parse_subroutine(p, false))
	case .Task: svp_list_add(p, depth, svp_parse_subroutine(p, true))
	case .Import: svp_add_imports(p, .Package, pkg_index)
	case .Export, .Timeunit, .Timeprecision, .Nettype: svp_skip_until_semicolon(p)
	case .Class:
		svp_skip_until_kw(p, .Endclass)
		svp_skip_end_label(p)
	case .Covergroup:
		svp_skip_until_kw(p, .Endgroup)
		svp_skip_end_label(p)
	case .Property:
		svp_skip_until_kw(p, .Endproperty)
		svp_skip_end_label(p)
	case .Sequence:
		svp_skip_until_kw(p, .Endsequence)
		svp_skip_end_label(p)
	case .Clocking:
		svp_skip_until_kw(p, .Endclocking)
		svp_skip_end_label(p)
	case: if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
				svp_list_add(p, depth, svp_parse_net_decl(p))
			} else if svp_is_ident(t) {
				// user-defined type declaration
				data := svp_parse_type(p, false)
				decl := svp_parse_net_decl_after_keyword(p, .NONE, data)
				svp_list_add(p, depth, decl)
			} else {
				svp_error(p, fmt.tprintf("unsupported package item '%s'", svp_text(p, t)))
			}
	}
}

svp_port_list_is_ansi :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if t.kind == .LBracket { return true }
	if _, ok := svp_port_dir(t.kw); ok { return true }
	if svp_is_decl_kw(t.kw) { return true }
	if t.kw == .Interface { return true }
	if svp_is_ident(t) {
		if svp_text(p, t) in p.ast.type_names || svp_text(p, t) in p.ast.iface_names { return true }
		n := svp_peek(p, 1)
		if svp_is_ident(n) || n.kind == .Dot { return true }
	}
	return false
}

// Adds a port node to the open module/interface port list. Ports live in the
// dedicated ast.ports buffer so later body declarations can extend the owner's
// list without invalidating any node span.
svp_port_add :: proc(p: ^SVParser2, port: u32) {
	append(&p.ast.ports, port)
	if p.iface != SV_NONE {
		i := &p.ast.interfaces[p.iface]
		i.ports.len += 1
	} else if p.module != SV_NONE {
		m := &p.ast.modules[p.module]
		m.ports.len += 1
	}
}

svp_port_new :: proc(p: ^SVParser2) -> u32 {
	port := svp_node(p, .Aux_Port)
	svn(p, port).a = SV_NONE
	svn(p, port).b = SV_NONE
	svn(p, port).c = SV_NONE
	svp_port_add(p, port)
	return port
}

svp_port_extra :: #force_inline proc(p: ^SVParser2, port: u32) -> SVPortExtra {
	ref := svn(p, port).c
	if ref == SV_NONE { return SVPortExtra{iface_name = SV_NONE, modport = SV_NONE, expr = SV_NONE, default_value = SV_NONE} }
	return p.ast.port_extra_chunks[ref >> SV_CHUNK_SHIFT][ref & SV_CHUNK_MASK]
}

svp_port_set_extra :: #force_inline proc(p: ^SVParser2, port: u32, extra: SVPortExtra) {
	ref := svn(p, port).c
	if ref == SV_NONE {
		ref = p.ast.port_extra_count
		if int(ref >> SV_CHUNK_SHIFT) >= len(p.ast.port_extra_chunks) {
			append(&p.ast.port_extra_chunks, svp_chunk(p, SVPortExtra))
		}
		p.ast.port_extra_count = ref + 1
		svn(p, port).c = ref
	}
	#no_bounds_check p.ast.port_extra_chunks[ref >> SV_CHUNK_SHIFT][ref & SV_CHUNK_MASK] = extra
}

svp_parse_module :: proc(p: ^SVParser2) -> u32 {
	svp_bump(p) // module/macromodule
	clear(&p.port_map)
	p.port_map_ready = false
	module_index := u32(len(p.ast.modules))
	append(&p.ast.modules, SVModule{})
	name := svp_expect_ident(p)
	p.ast.modules[module_index].name = name
	p.ast.modules[module_index].source_path = p.filepath
	p.module = module_index
	for svp_kw_at(p, .Import) { svp_add_imports(p, .Module, module_index) }
	if svp_at(p, .Hash) {
		d := svp_list_open(p)
		svp_parse_param_port_list(p, d)
		p.ast.modules[module_index].params = svp_list_close(p, d)
	}
	ports_start := u32(len(p.ast.ports))
	if svp_at(p, .LParen) { svp_parse_module_ports(p, module_index) }
	p.ast.modules[module_index].ports = SVSpan {
		start = ports_start,
		len   = u32(len(p.ast.ports)) - ports_start,
	}
	_ = svp_expect(p, .Semicolon)
	d := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endmodule) {
		svp_parse_module_item(p, d)
	}
	p.ast.modules[module_index].items = svp_list_close(p, d)
	_ = svp_expect_kw(p, .Endmodule)
	svp_skip_end_label(p)
	if _, exists := p.ast.module_hash_map[name]; exists {
		svp_error(p, fmt.tprintf("duplicate module '%s'", name))
	}
	p.ast.module_hash_map[name] = module_index
	p.module = SV_NONE
	return module_index
}

svp_parse_interface :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Interface)
	clear(&p.port_map)
	p.port_map_ready = false
	iface_index := u32(len(p.ast.interfaces))
	append(&p.ast.interfaces, SVInterface{})
	name := svp_expect_ident(p)
	p.ast.interfaces[iface_index].name = name
	old_iface := p.iface
	p.iface = iface_index
	for svp_kw_at(p, .Import) { svp_add_imports(p, .Interface, iface_index) }
	if svp_at(p, .Hash) {
		d := svp_list_open(p)
		svp_parse_param_port_list(p, d)
		p.ast.interfaces[iface_index].params = svp_list_close(p, d)
	}
	ports_start := u32(len(p.ast.ports))
	if svp_at(p, .LParen) { svp_parse_interface_ports(p) }
	p.ast.interfaces[iface_index].ports = SVSpan {
		start = ports_start,
		len   = u32(len(p.ast.ports)) - ports_start,
	}
	_ = svp_expect(p, .Semicolon)
	d := svp_list_open(p)
	md := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endinterface) {
		if svp_kw_at(p, .Modport) {
			svp_list_add(p, md, svp_parse_modport(p))
			continue
		}
		svp_parse_module_item(p, d)
	}
	p.ast.interfaces[iface_index].modports = svp_list_close(p, md)
	p.ast.interfaces[iface_index].items = svp_list_close(p, d)
	_ = svp_expect_kw(p, .Endinterface)
	svp_skip_end_label(p)
	p.iface = old_iface
	if _, exists := p.ast.interface_hash_map[name]; exists {
		svp_error(p, fmt.tprintf("duplicate interface '%s'", name))
	}
	p.ast.interface_hash_map[name] = iface_index
	p.ast.iface_names[name] = true
	return iface_index
}

svp_parse_modport :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Modport)
	mp := svp_node(p, .Aux_Modport)
	name := svp_expect_ident(p)
	svn(p, mp).a = svp_str(p, name)
	_ = svp_expect(p, .LParen)
	d := svp_list_open(p)
	for !svp_at(p, .RParen) {
		dir := SVPortDir.NONE
		if pd, ok := svp_port_dir(svp_peek(p).kw); ok {
			dir = pd
			svp_bump(p)
		} else if svp_accept_kw(p, .Ref) {
			dir = .REF
		}
		port := svp_node(p, .Aux_ModportPort)
		svn(p, port).a = svp_str(p, svp_expect_ident(p))
		svn(p, port).flags = u16(dir) & SVF_DIR_MASK
		svp_list_add(p, d, port)
		if !svp_accept(p, .Comma) { break }
	}
	svn(p, mp).span = svp_list_close(p, d)
	_ = svp_expect(p, .RParen)
	_ = svp_expect(p, .Semicolon)
	return mp
}

svp_parse_param_port_list :: proc(p: ^SVParser2, depth: int) {
	_ = svp_expect(p, .Hash)
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		svp_list_add(p, depth, svp_parse_param_group(p, true))
		if !svp_accept(p, .Comma) { break }
		if svp_at(p, .RParen) { break }
	}
	_ = svp_expect(p, .RParen)
}

svp_param_comma_starts_group :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if t.kw == .Parameter || t.kw == .Localparam || t.kw == .Type { return true }
	if _, ok := svp_var_type(t.kw); ok { return true }
	if _, ok := svp_net_type(t.kw); ok { return true }
	if t.kw == .Enum || t.kw == .Struct || t.kw == .Union || t.kw == .Signed || t.kw == .Unsigned { return true }
	if t.kind == .LBracket { return true }
	if svp_is_ident(t) {
		n := svp_peek(p, 1)
		if svp_is_ident(n) { return true }
		if n.kind == .ColonColon {
			// pkg::T x
			if svp_is_ident(svp_peek(p, 2)) && svp_is_ident(svp_peek(p, 3)) { return true }
		}
	}
	return false
}

svp_parse_param_group :: proc(p: ^SVParser2, in_port_list: bool) -> u32 {
	is_local := false
	if svp_accept_kw(p, .Localparam) { is_local = true } else { _ = svp_accept_kw(p, .Parameter) }
	if svp_accept_kw(p, .Type) { return svp_parse_type_param_decl(p, is_local, in_port_list) }

	decl := svp_node(p, .Item_ParamDecl)
	svn(p, decl).flags = is_local ? SVF_PARAM_LOCAL : 0
	data := svp_parse_type_for_param(p)
	svn(p, decl).a = data
	d := svp_list_open(p)
	svp_parse_param_assignments(p, in_port_list, d, true)
	svn(p, decl).span = svp_list_close(p, d)
	return decl
}

svp_parse_type_for_param :: proc(p: ^SVParser2) -> u32 {
	t := svp_peek(p)
	if t.kind == .LBracket {
		data := svp_node(p, .Aux_DataType)
		svn(p, data).a = SV_NONE
		svn(p, data).b = SV_NONE
		svn(p, data).c = SV_NONE
		d := svp_list_open(p)
		for svp_at(p, .LBracket) {
			svp_list_add(p, d, svp_parse_range(p))
		}
		svn(p, data).span = svp_list_close(p, d)
		return data
	}
	if _, ok := svp_var_type(t.kw); ok { return svp_parse_type(p, true) }
	if t.kw == .Enum || t.kw == .Struct || t.kw == .Union || t.kw == .Signed || t.kw == .Unsigned {
		return svp_parse_type(p, true)
	}
	if svp_is_ident(t) {
		n := svp_peek(p, 1)
		if svp_is_ident(n) { return svp_parse_type(p, false) }
		if n.kind == .ColonColon {
			if svp_is_ident(svp_peek(p, 2)) && (svp_is_ident(svp_peek(p, 3)) || svp_at(p, .LBracket, 3)) {
				return svp_parse_type(p, false)
			}
		}
		if n.kind == .LBracket {
			// T [dims] name: a user type with packed dimensions
			j := p.i + 1
			for j < len(p.toks) && p.toks[j].kind == .LBracket {
				depth := 0
				for j < len(p.toks) {
					if p.toks[j].kind == .LBracket { depth += 1 }
					if p.toks[j].kind == .RBracket { depth -= 1; if depth == 0 { j += 1; break } }
					j += 1
				}
			}
			if j < len(p.toks) && svp_is_ident(p.toks[j]) { return svp_parse_type(p, false) }
		}
	}
	data := svp_node(p, .Aux_DataType)
	n := svn(p, data)
	n.a = SV_NONE
	n.b = SV_NONE
	n.c = SV_NONE
	return data
}

svp_parse_module_ports :: proc(p: ^SVParser2, module_index: u32) {
	_ = svp_expect(p, .LParen)
	svp_skip_attributes(p)
	if svp_accept(p, .DotStar) {
		_ = svp_expect(p, .RParen)
		p.ast.modules[module_index].wildcard_ports = true
		p.ast.modules[module_index].is_ansi = true
		return
	}
	if svp_at(p, .RParen) {
		svp_bump(p)
		p.ast.modules[module_index].is_ansi = true
		return
	}
	if svp_port_list_is_ansi(p) {
		p.ast.modules[module_index].is_ansi = true
		svp_parse_ansi_ports(p)
	} else {
		svp_parse_nonansi_ports(p)
	}
	_ = svp_expect(p, .RParen)
}

svp_parse_nonansi_ports :: proc(p: ^SVParser2) {
	for {
		svp_skip_attributes(p)
		port := svp_port_new(p)
		if svp_accept(p, .Dot) {
			svn(p, port).b = svp_str(p, svp_expect_ident(p))
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) {
				expr := svp_parse_expr(p, 0)
				extra := svp_port_extra(p, port)
				extra.expr = expr
				svp_port_set_extra(p, port, extra)
			}
			_ = svp_expect(p, .RParen)
		} else if svp_at(p, .LBrace) {
			expr := svp_parse_concat(p)
			extra := svp_port_extra(p, port)
			extra.expr = expr
			svp_port_set_extra(p, port, extra)
		} else {
			svn(p, port).b = svp_str(p, svp_expect_ident(p))
			d := svp_list_open(p)
			for svp_at(p, .LBracket) {
				svp_list_add(p, d, svp_parse_range(p))
			}
			svn(p, port).span = svp_list_close(p, d)
		}
		if !svp_accept(p, .Comma) { break }
		if svp_at(p, .RParen) { break }
	}
}

svp_parse_interface_ports :: proc(p: ^SVParser2) {
	_ = svp_expect(p, .LParen)
	svp_skip_attributes(p)
	if svp_at(p, .RParen) { svp_bump(p); return }
	if svp_port_list_is_ansi(p) {
		svp_parse_ansi_ports(p)
	} else {
		svp_parse_nonansi_ports(p)
	}
	_ = svp_expect(p, .RParen)
}

svp_parse_ansi_ports :: proc(p: ^SVParser2) {
	prev_dir := SVPortDir.NONE
	prev_net := SVNetType.NONE
	prev_data := u32(SV_NONE)
	for {
		svp_skip_attributes(p)
		if svp_at(p, .RParen) { break }
		port := svp_port_new(p)
		pn := svn(p, port)
		given_dir := false
		given_net := false
		given_data := false

		if svp_at(p, .Dot) {
			// explicit port `.name(expr)`
			svp_bump(p)
			pn.b = svp_str(p, svp_expect_ident(p))
			if svp_accept(p, .LParen) {
				if !svp_at(p, .RParen) {
					expr := svp_parse_expr(p, 0)
					extra := svp_port_extra(p, port)
					extra.expr = expr
					svp_port_set_extra(p, port, extra)
				}
				_ = svp_expect(p, .RParen)
			}
			if !svp_accept(p, .Comma) { break }
			continue
		}

		if d, ok := svp_port_dir(svp_peek(p).kw); ok {
			pn.flags |= u16(d) & SVF_DIR_MASK
			svp_bump(p)
			given_dir = true
		} else {
			pn.flags |= u16(prev_dir) & SVF_DIR_MASK
		}

		if nt, ok := svp_net_type(svp_peek(p).kw); ok {
			pn.flags |= (u16(nt) << SVF_NET_SHIFT) & SVF_NET_MASK
			svp_bump(p)
			given_net = true
		} else {
			pn.flags |= (u16(prev_net) << SVF_NET_SHIFT) & SVF_NET_MASK
		}
		for svp_kw_at(p, .Scalared) || svp_kw_at(p, .Vectored) { svp_bump(p) }

		if svp_at(p, .Dot) {
			svp_bump(p)
			pn.b = svp_str(p, svp_expect_ident(p))
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) {
				expr := svp_parse_expr(p, 0)
				extra := svp_port_extra(p, port)
				extra.expr = expr
				svp_port_set_extra(p, port, extra)
			}
			_ = svp_expect(p, .RParen)
			if given_dir { prev_dir = SVPortDir(pn.flags & SVF_DIR_MASK) }
			if given_net { prev_net = SVNetType((pn.flags & SVF_NET_MASK) >> SVF_NET_SHIFT) }
			if !svp_accept(p, .Comma) { break }
			continue
		}

		// Interface port: iface.modport name, generic `interface name`, or a known
		// interface name followed by the port name.
		if svp_kw_at(p, .Interface) {
			svp_bump(p)
			port_name := svp_expect_ident(p)
			extra := svp_port_extra(p, port)
			extra.iface_name = svp_str(p, "interface")
			svp_port_set_extra(p, port, extra)
			pn.b = svp_str(p, port_name)
			given_data = true
		} else if t := svp_peek(p); svp_is_ident(t) && svp_at(p, .Dot, 1) {
			iface_name := svp_text(p, t)
			svp_bump(p)
			_ = svp_expect(p, .Dot)
			modport_name := svp_expect_ident(p)
			port_name := svp_expect_ident(p)
			extra := svp_port_extra(p, port)
			extra.iface_name = svp_str(p, iface_name)
			extra.modport = svp_str(p, modport_name)
			svp_port_set_extra(p, port, extra)
			pn.b = svp_str(p, port_name)
			given_data = true
		} else if t := svp_peek(p); svp_is_ident(t) && svp_text(p, t) in p.ast.iface_names && svp_is_ident(svp_peek(p, 1)) {
			iface_name := svp_text(p, t)
			svp_bump(p)
			port_name := svp_expect_ident(p)
			extra := svp_port_extra(p, port)
			extra.iface_name = svp_str(p, iface_name)
			svp_port_set_extra(p, port, extra)
			pn.b = svp_str(p, port_name)
			given_data = true
		} else if svp_starts_port_type(p) {
			data := svp_parse_type(p, true)
			pn.a = data
			given_data = true
			pn.b = svp_str(p, svp_expect_ident(p))
		} else {
			if given_dir || given_net {
				pn.a = svp_node(p, .Aux_DataType)
			} else {
				pn.a = prev_data
			}
			if svp_is_decl_kw(svp_peek(p).kw) || svp_at(p, .LBracket) {
				data := svp_parse_type(p, true)
				pn.a = data
				given_data = true
			}
			pn.b = svp_str(p, svp_expect_ident(p))
		}

		d := svp_list_open(p)
		for svp_at(p, .LBracket) {
			svp_list_add(p, d, svp_parse_range(p))
		}
		pn.span = svp_list_close(p, d)
		if svp_accept(p, .Assign) {
			value := svp_parse_expr(p, 0)
			extra := svp_port_extra(p, port)
			extra.default_value = value
			svp_port_set_extra(p, port, extra)
		}
		if given_dir { prev_dir = SVPortDir(pn.flags & SVF_DIR_MASK) }
		if given_net { prev_net = SVNetType((pn.flags & SVF_NET_MASK) >> SVF_NET_SHIFT) }
		if given_data { prev_data = pn.a }
		if !svp_accept(p, .Comma) { break }
	}
}

svp_starts_port_type :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if t.kind == .LBracket { return true }
	if _, ok := svp_var_type(t.kw); ok { return true }
	if _, ok := svp_net_type(t.kw); ok { return true }
	if t.kw == .Var || t.kw == .Const || t.kw == .Signed || t.kw == .Unsigned || t.kw == .Enum || t.kw == .Struct || t.kw == .Union { return true }
	if svp_is_ident(t) {
		if svp_text(p, t) in p.ast.type_names { return true }
		n := svp_peek(p, 1)
		if n.kind == .ColonColon { return true }
		if svp_is_ident(n) { return true }
		if n.kind == .LBracket && svp_ident_dims_then_ident(p) { return true }
	}
	return false
}

svp_parse_port_declaration :: proc(p: ^SVParser2, dir: SVPortDir) -> u32 {
	svp_bump(p) // direction keyword
	net_type := SVNetType.NONE
	if nt, ok := svp_net_type(svp_peek(p).kw); ok {
		net_type = nt
		svp_bump(p)
	}
	data := svp_parse_net_data_type(p)
	d := svp_list_open(p)
	svp_parse_declarators(p, d)
	declarators := svp_list_close(p, d)
	_ = svp_expect(p, .Semicolon)
	net_decl := svp_node(p, .Item_NetDecl)
	netn := svn(p, net_decl)
	netn.a = data
	netn.flags = u16(net_type) & 0xF
	netn.span = declarators

	owner_ports_ready := p.module != SV_NONE || p.iface != SV_NONE
	if owner_ports_ready && !p.port_map_ready {
		count := 0
		if p.iface != SV_NONE {
			count = int(p.ast.interfaces[p.iface].ports.len)
		} else {
			count = int(p.ast.modules[p.module].ports.len)
		}
		start := u32(len(p.ast.ports)) - u32(count)
		for k in 0 ..< count {
			pid := p.ast.ports[start + u32(k)]
			p.port_map[sv_text(p.ast, svn(p, pid).b)] = pid
		}
		p.port_map_ready = true
	}
	if owner_ports_ready {
		given_data := svp_data_type_is_given(p, data)
		for k in 0 ..< int(declarators.len) {
			dnode := p.ast.kids[declarators.start + u32(k)]
			dn := svn(p, dnode)^
			dname := sv_text(p.ast, dn.a)
			port, found := p.port_map[dname]
			if !found {
				port = svp_port_new(p)
				pn := svn(p, port)
				pn.b = svp_str(p, dname)
				pn.flags |= u16(dir) & SVF_DIR_MASK
				pn.flags |= (u16(net_type) << SVF_NET_SHIFT) & SVF_NET_MASK
				if given_data { pn.a = data }
				pn.span = dn.span
				extra := svp_port_extra(p, port)
				extra.default_value = dn.b
				svp_port_set_extra(p, port, extra)
				p.port_map[dname] = port
			} else {
				pn := svn(p, port)
				pn.flags &~= (SVF_DIR_MASK | SVF_NET_MASK)
				pn.flags |= u16(dir) & SVF_DIR_MASK
				pn.flags |= (u16(net_type) << SVF_NET_SHIFT) & SVF_NET_MASK
				if given_data { pn.a = data }
				pn.span = dn.span
				extra := svp_port_extra(p, port)
				extra.default_value = dn.b
				svp_port_set_extra(p, port, extra)
			}
		}
	}
	node := svp_node(p, .Item_PortDecl)
	nn := svn(p, node)
	nn.a = u32(dir)
	nn.b = net_decl
	return node
}

svp_data_type_is_given :: #force_inline proc(p: ^SVParser2, data: u32) -> bool {
	n := svn(p, data)^
	return n.a != SV_NONE || n.b != SV_NONE || n.c != SV_NONE || n.span.len > 0
}

// ---------------------------------------------------------------------------------------
// Module items, assignments, instances, generate
// ---------------------------------------------------------------------------------------

svp_is_instantiation_ahead :: proc(p: ^SVParser2) -> bool {
	j := p.i
	toks := p.toks
	if j >= len(toks) { return false }
	if toks[j].kind == .Hash {
		// skip #( ... )
		j += 1
		if j < len(toks) && toks[j].kind == .LParen {
			depth := 0
			for j < len(toks) {
				if toks[j].kind == .LParen { depth += 1 }
				if toks[j].kind == .RParen { depth -= 1; if depth == 0 { j += 1; break } }
				j += 1
			}
		} else {
			j += 1 // simple delay
		}
	}
	if j >= len(toks) || !svp_is_ident(toks[j]) { return false }
	j += 1
	for j < len(toks) && toks[j].kind == .LBracket {
		depth := 0
		for j < len(toks) {
			if toks[j].kind == .LBracket { depth += 1 }
			if toks[j].kind == .RBracket { depth -= 1; if depth == 0 { j += 1; break } }
			j += 1
		}
	}
	return j < len(toks) && toks[j].kind == .LParen
}

svp_parse_module_item :: proc(p: ^SVParser2, depth: int) {
	svp_skip_attributes(p)
	if svp_accept(p, .Semicolon) { return }
	t := svp_peek(p)
	if svp_is_ident(t) && svp_at(p, .Colon, 1) {
		n := svp_peek(p, 2)
		if n.kw == .Assert || n.kw == .Assume || n.kw == .Cover {
			svp_bump(p)
			_ = svp_expect(p, .Colon)
			svp_list_add(p, depth, svp_parse_assertion(p, n.kw == .Assert ? .ASSERT : (n.kw == .Assume ? .ASSUME : .COVER)))
			return
		}
		if n.kw == .Begin {
			label := svp_expect_ident(p)
			_ = svp_expect(p, .Colon)
			block := svp_parse_gen_block_after_begin(p, label)
			svp_list_add(p, depth, svp_gen_region_from_block(p, block))
			return
		}
	}
	#partial switch t.kw {
	case .Input: svp_list_add(p, depth, svp_parse_port_declaration(p, .INPUT))
	case .Output: svp_list_add(p, depth, svp_parse_port_declaration(p, .OUTPUT))
	case .Inout: svp_list_add(p, depth, svp_parse_port_declaration(p, .INOUT))
	case .Ref: svp_list_add(p, depth, svp_parse_port_declaration(p, .REF))
	case .Parameter, .Localparam: svp_list_add(p, depth, svp_parse_param_item(p, t.kw == .Localparam))
	case .Typedef: svp_list_add(p, depth, svp_parse_typedef(p))
	case .Import:
		if p.module != SV_NONE { svp_add_imports(p, .Module, p.module) }
			else if p.iface != SV_NONE { svp_add_imports(p, .Interface, p.iface) }
			else { svp_parse_import_list(p) }
	case .Assign: svp_list_add(p, depth, svp_parse_cont_assign(p))
	case .Alias: svp_list_add(p, depth, svp_parse_alias(p))
	case .Defparam: svp_list_add(p, depth, svp_parse_defparam(p))
	case .Initial: svp_list_add(p, depth, svp_parse_proc(p, .INITIAL))
	case .Final:
		svp_bump(p)
		proc_node := svp_node(p, .Item_Proc)
		prn := svn(p, proc_node)
		prn.a = u32(SVProcKind.FINAL)
		body := svp_parse_statement(p)
		prn.b = body
		svp_list_add(p, depth, proc_node)
	case .Always: svp_list_add(p, depth, svp_parse_proc(p, .ALWAYS))
	case .AlwaysComb: svp_list_add(p, depth, svp_parse_proc(p, .ALWAYS_COMB))
	case .AlwaysFf: svp_list_add(p, depth, svp_parse_proc(p, .ALWAYS_FF))
	case .AlwaysLatch: svp_list_add(p, depth, svp_parse_proc(p, .ALWAYS_LATCH))
	case .Function: svp_list_add(p, depth, svp_parse_subroutine(p, false))
	case .Task: svp_list_add(p, depth, svp_parse_subroutine(p, true))
	case .Generate: svp_list_add(p, depth, svp_parse_gen_region(p))
	case .For: svp_list_add(p, depth, svp_parse_gen_loop(p))
	case .If: svp_list_add(p, depth, svp_parse_gen_if(p))
	case .Case, .Casez, .Casex: svp_list_add(p, depth, svp_parse_gen_case(p))
	case .Genvar:
		svp_bump(p)
		gv := svp_node(p, .Item_GenvarDecl)
		d := svp_list_open(p)
		for {
			name := svp_expect_ident(p)
			svp_list_add(p, d, svp_str_node(p, name))
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .Semicolon)
		svn(p, gv).span = svp_list_close(p, d)
		svp_list_add(p, depth, gv)
	case .Assert: svp_list_add(p, depth, svp_parse_assertion(p, .ASSERT))
	case .Assume: svp_list_add(p, depth, svp_parse_assertion(p, .ASSUME))
	case .Cover: svp_list_add(p, depth, svp_parse_assertion(p, .COVER))
	case .Restrict:
		svp_bump(p)
		if svp_kw_at(p, .Property) {
			svp_bump(p)
			if svp_at(p, .LParen) { svp_skip_parens(p) }
		}
		_ = svp_expect(p, .Semicolon)
	case .Class:
		svp_skip_until_kw(p, .Endclass)
		svp_skip_end_label(p)
	case .Covergroup:
		svp_skip_until_kw(p, .Endgroup)
		svp_skip_end_label(p)
	case .Property:
		svp_skip_until_kw(p, .Endproperty)
		svp_skip_end_label(p)
	case .Sequence:
		svp_skip_until_kw(p, .Endsequence)
		svp_skip_end_label(p)
	case .Clocking:
		svp_skip_until_kw(p, .Endclocking)
		svp_skip_end_label(p)
	case .Specify: svp_skip_until_kw(p, .Endspecify)
	case .Default:
		svp_bump(p)
		if svp_kw_at(p, .Clocking) {
			svp_skip_until_kw(p, .Endclocking)
			svp_skip_end_label(p)
		} else {
			svp_skip_until_semicolon(p)
		}
	case .Timeunit, .Timeprecision: svp_skip_until_semicolon(p)
	case .Begin:
		block := svp_parse_gen_block(p)
		svp_list_add(p, depth, svp_gen_region_from_block(p, block))
	case .Module, .Macromodule: _ = svp_parse_module(p)
	case:
		if svp_is_gate_kw(t.kw) {
			name := svp_text(p, t)
			svp_bump(p)
			svp_parse_instantiation(p, name, true, depth)
			return
		}
		if t.kind == .SystemIdent {
			name := svp_text(p, svp_advance(p))
			call: u32
			if svp_at(p, .LParen) {
				call = svp_parse_call(p, name, true)
			} else {
				call = svp_node(p, .Expr_Call)
				svn(p, call).a = svp_str(p, name)
				svn(p, call).flags |= SVF_CALL_SYSTEM
			}
			_ = svp_expect(p, .Semicolon)
			svp_list_add(p, depth, call)
			return
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			svp_list_add(p, depth, svp_parse_net_decl(p))
			return
		}
		if svp_is_ident(t) {
			name := svp_expect_ident(p)
			if svp_is_instantiation_ahead(p) {
				svp_parse_instantiation(p, name, svp_is_gate_kw(t.kw), depth)
				return
			}
			// `type_t name;` / `pkg::type_t name;`
			if svp_is_ident(svp_peek(p)) || svp_at(p, .LBracket) {
				data := svp_type_from_name(p, "", name)
				decl := svp_parse_net_decl_after_keyword(p, .NONE, data)
				svp_list_add(p, depth, decl)
				return
			}
			if svp_at(p, .ColonColon) {
				scope := name
				svp_bump(p)
				member := svp_expect_ident(p)
				if svp_is_ident(svp_peek(p)) || svp_at(p, .LBracket) {
					data := svp_type_from_name(p, scope, member)
					decl := svp_parse_net_decl_after_keyword(p, .NONE, data)
					svp_list_add(p, depth, decl)
					return
				}
				// scoped task call
				if svp_at(p, .Semicolon) {
					svp_bump(p)
					call := svp_node(p, .Expr_Call)
					svn(p, call).a = svp_str(p, strings.concatenate({scope, "::", member}, p.allocator))
					svp_list_add(p, depth, call)
					return
				}
				svp_error(p, "unsupported scoped module item")
			}
			is_gate := svp_is_gate_kw(t.kw)
			svp_parse_instantiation(p, name, is_gate, depth)
			return
		}
		svp_error(p, fmt.tprintf("unexpected token '%s' in module body", svp_text(p, t)))
	}
}

svp_skip_strengths :: proc(p: ^SVParser2) {
	if svp_at(p, .LParen) && svp_is_strength_token(p) { svp_skip_parens(p) }
}

svp_skip_parens :: proc(p: ^SVParser2) {
	depth := 0
	for !svp_at_eof(p) {
		if svp_at(p, .LParen) { depth += 1 }
		if svp_at(p, .RParen) { depth -= 1; if depth == 0 { svp_bump(p); break } }
		svp_bump(p)
	}
}

svp_parse_cont_assign :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Assign)
	if svp_accept(p, .Hash) {
		if svp_at(p, .LParen) { svp_skip_parens(p) } else { svp_bump(p) }
	}
	svp_skip_strengths(p)
	node := svp_node(p, .Item_ContAssign)
	d := svp_list_open(p)
	for {
		pair := svp_node(p, .Aux_AssignPair)
		lhs := svp_parse_expr(p, 0)
		_ = svp_expect(p, .Assign)
		rhs := svp_parse_expr(p, 0)
		svn(p, pair).a = lhs
		svn(p, pair).b = rhs
		svp_list_add(p, d, pair)
		if !svp_accept(p, .Comma) { break }
	}
	svn(p, node).span = svp_list_close(p, d)
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_alias :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Alias)
	node := svp_node(p, .Item_Alias)
	d := svp_list_open(p)
	for {
		svp_list_add(p, d, svp_parse_expr(p, 0))
		if !svp_accept(p, .Assign) { break }
	}
	svn(p, node).span = svp_list_close(p, d)
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_defparam :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Defparam)
	node := svp_node(p, .Item_Defparam)
	d := svp_list_open(p)
	for {
		pair := svp_node(p, .Aux_AssignPair)
		lhs := svp_parse_expr(p, 0)
		_ = svp_expect(p, .Assign)
		rhs := svp_parse_expr(p, 0)
		svn(p, pair).a = lhs
		svn(p, pair).b = rhs
		svp_list_add(p, d, pair)
		if !svp_accept(p, .Comma) { break }
	}
	svn(p, node).span = svp_list_close(p, d)
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_type_from_name :: proc(p: ^SVParser2, scope, name: string) -> u32 {
	data := svp_node(p, .Aux_DataType)
	svn(p, data).a = svp_str(p, name)
	svn(p, data).b = scope == "" ? SV_NONE : svp_str(p, scope)
	d := svp_list_open(p)
	for svp_at(p, .LBracket) {
		svp_list_add(p, d, svp_parse_range(p))
	}
	svn(p, data).span = svp_list_close(p, d)
	return data
}

svp_parse_param_overrides :: proc(p: ^SVParser2, depth: int) {
	if !svp_accept(p, .Hash) { return }
	if svp_at(p, .Number) {
		// delay control, not a parameter list
		svp_bump(p)
		return
	}
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		o := svp_node(p, .Aux_ParamOverride)
		on := svn(p, o)
		on.a = SV_NONE
		on.b = SV_NONE
		on.c = SV_NONE
		if svp_accept(p, .Dot) {
			name := svp_expect_ident(p)
			on.a = svp_str(p, name)
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) {
				if svp_starts_type_token(p) {
					v := svp_parse_type(p, true)
					on.c = v
				} else {
					value := svp_parse_expr(p, 0)
					on.b = value
				}
			}
			_ = svp_expect(p, .RParen)
		} else if svp_starts_type_token(p) {
			v := svp_parse_type(p, true)
			on.c = v
		} else {
			value := svp_parse_expr(p, 0)
			on.b = value
		}
		svp_list_add(p, depth, o)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RParen)
}

svp_starts_type_token :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if t.kind == .LBracket { return true }
	if _, ok := svp_var_type(t.kw); ok { return !svp_at(p, .Tick, 1) }
	if t.kw == .Enum || t.kw == .Struct || t.kw == .Union || t.kw == .Signed || t.kw == .Unsigned { return !svp_at(p, .Tick, 1) }
	if svp_is_ident(t) {
		if svp_text(p, t) in p.ast.type_names || svp_text(p, t) in p.ast.iface_names { return true }
		if svp_at(p, .ColonColon, 1) {
			// `pkg::type)` / `pkg::type [..]` is a type argument; anything else
			// (`pkg::CONST - x`, `pkg::type'(x)`) is an expression.
			n3 := svp_peek(p, 3).kind
			return n3 == .RParen || n3 == .Comma || n3 == .LBracket
		}
	}
	return false
}

svp_parse_instantiation :: proc(p: ^SVParser2, cell: string, is_gate: bool, depth: int) {
	// Optional gate strengths: (strong0, strong1)
	if is_gate && svp_at(p, .LParen) && svp_is_strength_token(p) {
		for !svp_at(p, .RParen) && !svp_at_eof(p) { svp_bump(p) }
		_ = svp_expect(p, .RParen)
	}
	for {
		inst := svp_node(p, .Item_Instance)
		svn(p, inst).a = svp_str(p, cell)
		svn(p, inst).b = SV_NONE
		if is_gate { svn(p, inst).flags |= SVF_INSTANCE_GATE }
		base := p.list_depth

		d_params := svp_list_open(p)
		if svp_at(p, .Hash) { svp_parse_param_overrides(p, d_params) }
		if svp_at(p, .Hash) {
			// gate delay triple / `#delay
			svp_bump(p)
			if svp_at(p, .LParen) {
				for !svp_at(p, .RParen) && !svp_at_eof(p) { svp_bump(p) }
				_ = svp_expect(p, .RParen)
			} else {
				svp_bump(p)
			}
		}
		d_dims := svp_list_open(p)
		if svp_is_ident(svp_peek(p)) || svp_at(p, .EscapedIdent) {
			svn(p, inst).b = svp_str(p, svp_expect_ident(p))
		} else if !is_gate {
			svp_error(p, "expected an instance name")
		}
		for svp_at(p, .LBracket) {
			svp_list_add(p, d_dims, svp_parse_range(p))
		}
		d_conns := svp_list_open(p)
		if svp_at(p, .LParen) { svp_parse_port_connections(p, inst, d_conns) }

		params := svp_list_commit(p, d_params)
		dims := svp_list_commit(p, d_dims)
		conns := svp_list_commit(p, d_conns)
		p.list_depth = base

		svn(p, inst).c = params.len
		svn(p, inst).d = dims.len
		svn(p, inst).span = SVSpan {
			start = params.start,
			len   = params.len + dims.len + conns.len,
		}
		svp_list_add(p, depth, inst)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
}

svp_is_strength_token :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p, 1)
	#partial switch t.kw {
	case .Strong0, .Strong1, .Weak0, .Weak1, .Highz0, .Highz1, .Pull0, .Pull1, .Supply0, .Supply1: return true
	}
	return false
}

svp_ident_dims_then_ident :: proc(p: ^SVParser2) -> bool {
	toks := p.toks
	j := p.i + 1
	if j >= len(toks) || toks[j].kind != .LBracket { return false }
	for j < len(toks) && toks[j].kind == .LBracket {
		depth := 0
		for j < len(toks) {
			if toks[j].kind == .LBracket { depth += 1 }
			if toks[j].kind == .RBracket { depth -= 1; if depth == 0 { j += 1; break } }
			j += 1
		}
	}
	return j < len(toks) && svp_is_ident(toks[j])
}

svp_parse_port_connections :: proc(p: ^SVParser2, inst: u32, depth: int) {
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		svp_skip_attributes(p)
		conn := svp_node(p, .Aux_PortConn)
		cn := svn(p, conn)
		cn.a = SV_NONE
		cn.b = SV_NONE
		if svp_accept(p, .DotStar) {
			svn(p, inst).flags |= SVF_INSTANCE_WILDCARD
			if !svp_accept(p, .Comma) { break }
			continue
		}
		if svp_accept(p, .Dot) {
			if svp_accept(p, .Star) {
				svn(p, inst).flags |= SVF_INSTANCE_WILDCARD
				if !svp_accept(p, .Comma) { break }
				continue
			}
			cn.a = svp_str(p, svp_expect_ident(p))
			if svp_accept(p, .LParen) {
				if !svp_at(p, .RParen) {
					value := svp_parse_expr(p, 0)
					cn.b = value
				}
				_ = svp_expect(p, .RParen)
			}
		} else if !svp_at(p, .Comma) {
			value := svp_parse_expr(p, 0)
			cn.b = value
		}
		svp_list_add(p, depth, conn)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RParen)
}

svp_gen_region_from_block :: proc(p: ^SVParser2, block: u32) -> u32 {
	bn := sv_node(p.ast, block)
	region := svp_node(p, .Item_GenRegion)
	svn(p, region).a = bn.a
	svn(p, region).span = bn.span
	return region
}

svp_parse_gen_region :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Generate)
	region := svp_node(p, .Item_GenRegion)
	svn(p, region).a = SV_NONE
	d := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endgenerate) {
		svp_parse_module_item(p, d)
	}
	svn(p, region).span = svp_list_close(p, d)
	_ = svp_expect_kw(p, .Endgenerate)
	return region
}

svp_parse_gen_block :: proc(p: ^SVParser2) -> u32 {
	block := svp_node(p, .Stmt_Block)
	bn := svn(p, block)
	bn.a = SV_NONE
	if svp_accept_kw(p, .Begin) {
		if svp_accept(p, .Colon) {
			svn(p, block).a = svp_str(p, svp_expect_ident(p))
		}
		d := svp_list_open(p)
		for !svp_at_eof(p) && !svp_kw_at(p, .End) {
			svp_parse_module_item(p, d)
		}
		svn(p, block).span = svp_list_close(p, d)
		_ = svp_expect_kw(p, .End)
		svp_skip_end_label(p)
	} else {
		d := svp_list_open(p)
		svp_parse_module_item(p, d)
		svn(p, block).span = svp_list_close(p, d)
	}
	return block
}

svp_parse_gen_loop :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .For)
	_ = svp_expect(p, .LParen)
	_ = svp_accept_kw(p, .Genvar)
	var := svp_expect_ident(p)
	_ = svp_expect(p, .Assign)
	init := svp_parse_expr(p, 0)
	_ = svp_expect(p, .Semicolon)
	cond := svp_parse_expr(p, 0)
	_ = svp_expect(p, .Semicolon)
	step := svp_parse_stmt_no_semi(p)
	_ = svp_expect(p, .RParen)
	body := svp_parse_gen_block(p)
	node := svp_node(p, .Item_GenLoop)
	svn(p, node).a = svp_str(p, var)
	svn(p, node).b = init
	svn(p, node).c = cond
	svn(p, node).d = step
	d := svp_list_open(p)
	svp_list_add(p, d, body)
	svn(p, node).span = svp_list_close(p, d)
	return node
}

svp_parse_gen_if :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .If)
	_ = svp_expect(p, .LParen)
	cond := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	then_blk := svp_parse_gen_block(p)
	else_blk := u32(SV_NONE)
	if svp_accept_kw(p, .Else) { else_blk = svp_parse_gen_block(p) }
	node := svp_node(p, .Item_GenIf)
	svn(p, node).c = SV_NONE
	svn(p, node).a = cond
	svn(p, node).b = then_blk
	svn(p, node).c = else_blk
	return node
}

svp_parse_gen_case :: proc(p: ^SVParser2) -> u32 {
	kind := SVCaseKind.CASE
	#partial switch svp_peek(p).kw {
	case .Casez: kind = .CASEZ
	case .Casex: kind = .CASEX
	}
	svp_bump(p)
	node := svp_node(p, .Item_GenCase)
	nn := svn(p, node)
	nn.a = u32(kind)
	_ = svp_expect(p, .LParen)
	subject := svp_parse_expr(p, 0)
	nn.b = subject
	_ = svp_expect(p, .RParen)
	d := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endcase) {
		item := svp_node(p, .Aux_GenCaseItem)
		it := svn(p, item)
		it.a = SV_NONE
		if svp_accept_kw(p, .Default) {
			it.flags |= 0x1
			_ = svp_accept(p, .Colon)
		} else {
			ed := svp_list_open(p)
			for {
				svp_list_add(p, ed, svp_parse_expr(p, 0))
				if !svp_accept(p, .Comma) { break }
			}
			it.span = svp_list_close(p, ed)
			_ = svp_expect(p, .Colon)
		}
		body := svp_parse_gen_block(p)
		it.a = body
		svp_list_add(p, d, item)
	}
	nn.span = svp_list_close(p, d)
	_ = svp_expect_kw(p, .Endcase)
	return node
}

// ---------------------------------------------------------------------------------------
// Procedures, statements, subroutines
// ---------------------------------------------------------------------------------------

svp_parse_proc :: proc(p: ^SVParser2, kind: SVProcKind) -> u32 {
	svp_bump(p)
	node := svp_node(p, .Item_Proc)
	nn := svn(p, node)
	nn.a = u32(kind)
	if svp_at(p, .At) {
		ctl := svp_parse_timing_ctl(p)
		cn := svn(p, ctl)
		nn.span = cn.span
		nn.flags = 0
		if (cn.flags & SVF_TIMING_ANY) != 0 { nn.flags |= SVF_PROC_ANY_EVENT }
		body := svp_parse_statement(p)
		nn.b = body
		return node
	}
	if svp_at(p, .Hash) {
		ctl := svp_parse_timing_ctl(p)
		body := svp_parse_statement_or_null(p)
		timing := svp_node(p, .Stmt_Timing)
		tn := svn(p, timing)
		tn.a = ctl
		tn.b = body
		nn.b = timing
		return node
	}
	body := svp_parse_statement(p)
	nn.b = body
	return node
}

svp_parse_timing_ctl :: proc(p: ^SVParser2) -> u32 {
	ctl := svp_node(p, .Aux_TimingCtl)
	cn := svn(p, ctl)
	if svp_accept(p, .Hash) {
		cn.flags |= SVF_TIMING_DELAY
		if svp_at(p, .LParen) {
			depth := 0
			start := p.i
			for !svp_at_eof(p) {
				if svp_at(p, .LParen) { depth += 1 }
				if svp_at(p, .RParen) { depth -= 1; if depth == 0 { p.i += 1; break } }
				p.i += 1
			}
			if p.i > start + 2 {
				old_i := p.i
				p.i = start + 1
				delay := svp_parse_expr(p, 0)
				cn.a = delay
				p.i = old_i
			}
		} else if !svp_at(p, .Semicolon) {
			delay := svp_parse_primary(p)
			cn.a = delay
		}
		return ctl
	}
	_ = svp_expect(p, .At)
	if svp_accept(p, .Star) {
		cn.flags |= SVF_TIMING_ANY
		return ctl
	}
	if svp_accept(p, .AttrStart) {
		_ = svp_expect(p, .RParen)
		cn.flags |= SVF_TIMING_ANY
		return ctl
	}
	if svp_accept(p, .LParen) {
		if svp_accept(p, .Star) {
			_ = svp_expect(p, .RParen)
			cn.flags |= SVF_TIMING_ANY
			return ctl
		}
		d := svp_list_open(p)
		for {
			ev := svp_node(p, .Aux_Event)
			en := svn(p, ev)
			en.b = SV_NONE
			if svp_accept_kw(p, .Posedge) {
				en.flags = u16(SVEdgeKind.POSEDGE) & 0x3
			} else if svp_accept_kw(p, .Negedge) {
				en.flags = u16(SVEdgeKind.NEGEDGE) & 0x3
			} else if svp_accept_kw(p, .Edge) {
				en.flags = u16(SVEdgeKind.EDGE) & 0x3
			}
			expr := svp_parse_expr(p, 0)
			en.a = expr
			if svp_accept_kw(p, .Iff) {
				iff := svp_parse_expr(p, 0)
				en.b = iff
			}
			svp_list_add(p, d, ev)
			if svp_accept(p, .Comma) { continue }
			if svp_accept_kw(p, .Or) { continue }
			break
		}
		cn.span = svp_list_close(p, d)
		_ = svp_expect(p, .RParen)
		return ctl
	}
	ev := svp_node(p, .Aux_Event)
	en := svn(p, ev)
	en.b = SV_NONE
	if svp_accept_kw(p, .Posedge) {
		en.flags = u16(SVEdgeKind.POSEDGE) & 0x3
	} else if svp_accept_kw(p, .Negedge) {
		en.flags = u16(SVEdgeKind.NEGEDGE) & 0x3
	}
	expr := svp_parse_expr(p, 0)
	en.a = expr
	d := svp_list_open(p)
	svp_list_add(p, d, ev)
	cn.span = svp_list_close(p, d)
	return ctl
}

svp_parse_statement_or_null :: proc(p: ^SVParser2) -> u32 {
	svp_skip_attributes(p)
	if svp_accept(p, .Semicolon) { return SV_NONE }
	return svp_parse_statement(p)
}

svp_parse_statement :: proc(p: ^SVParser2) -> u32 {
	svp_skip_attributes(p)
	if svp_at(p, .Semicolon) {
		svp_bump(p)
		return svp_node(p, .Stmt_Block)
	}
	// optional statement label
	if svp_is_ident(svp_peek(p)) && svp_at(p, .Colon, 1) {
		svp_bump(p)
		_ = svp_expect(p, .Colon)
		return svp_parse_statement(p)
	}

	t := svp_peek(p)
	#partial switch t.kw {
	case .Begin: return svp_parse_block(p)
	case .If: return svp_parse_if(p, .NONE)
	case .Unique, .Unique0, .Priority:
		q: SVQualifier = .UNIQUE
		if t.kw == .Unique0 { q = .UNIQUE0 }
		if t.kw == .Priority { q = .PRIORITY }
		svp_bump(p)
		if svp_kw_at(p, .If) { return svp_parse_if(p, q) }
		if svp_kw_at(p, .Case) || svp_kw_at(p, .Casez) || svp_kw_at(p, .Casex) { return svp_parse_case(p, q) }
		svp_error(p, "expected if or case after unique/priority")
	case .Case, .Casez, .Casex: return svp_parse_case(p, .NONE)
	case .For: return svp_parse_for(p)
	case .While: return svp_parse_while(p, false)
	case .Do: return svp_parse_while(p, true)
	case .Repeat: return svp_parse_repeat(p)
	case .Forever: return svp_parse_forever(p)
	case .Foreach: return svp_parse_foreach(p)
	case .Break:
		svp_bump(p)
		_ = svp_expect(p, .Semicolon)
		jump := svp_node(p, .Stmt_Jump)
		jn := svn(p, jump)
		jn.a = u32(SVJumpKind.BREAK)
		jn.b = SV_NONE
		return jump
	case .Continue:
		svp_bump(p)
		_ = svp_expect(p, .Semicolon)
		jump := svp_node(p, .Stmt_Jump)
		jn := svn(p, jump)
		jn.a = u32(SVJumpKind.CONTINUE)
		jn.b = SV_NONE
		return jump
	case .Return:
		svp_bump(p)
		value := u32(SV_NONE)
		if !svp_at(p, .Semicolon) { value = svp_parse_expr(p, 0) }
		_ = svp_expect(p, .Semicolon)
		jump := svp_node(p, .Stmt_Jump)
		jn := svn(p, jump)
		jn.a = u32(SVJumpKind.RETURN)
		jn.b = value
		return jump
	case .Void:
		svp_bump(p)
		_ = svp_expect(p, .Tick)
		_ = svp_expect(p, .LParen)
		e := svp_parse_expr(p, 0)
		_ = svp_expect(p, .RParen)
		_ = svp_expect(p, .Semicolon)
		if sv_node_kind(p.ast, e) == .Expr_Call { return e }
		svp_error(p, "void' expects a subroutine call")
	case .Assert: return svp_parse_assertion(p, .ASSERT)
	case .Assume: return svp_parse_assertion(p, .ASSUME)
	case .Cover: return svp_parse_assertion(p, .COVER)
	case .Expect: return svp_parse_assertion(p, .EXPECT)
	case .Wait, .Fork, .Join, .JoinAny, .JoinNone, .Disable, .Force, .Release, .Deassign, .Randcase, .Randsequence:
		svp_error(p, fmt.tprintf("unsupported procedural construct '%s'", svp_text(p, t)))
	case:
	}

	if svp_at(p, .At) || svp_at(p, .Hash) {
		ctl := svp_parse_timing_ctl(p)
		body := svp_parse_statement_or_null(p)
		timing := svp_node(p, .Stmt_Timing)
		svn(p, timing).a = ctl
		svn(p, timing).b = body
		return timing
	}
	if svp_at(p, .SystemIdent) {
		name := svp_text(p, svp_advance(p))
		call: u32
		if svp_at(p, .LParen) {
			call = svp_parse_call(p, name, true)
		} else {
			call = svp_node(p, .Expr_Call)
			svn(p, call).a = svp_str(p, name)
			svn(p, call).flags |= SVF_CALL_SYSTEM
		}
		_ = svp_expect(p, .Semicolon)
		return call
	}
	if svp_is_ident(t) || t.kind == .EscapedIdent {
		name := svp_text(p, svp_advance(p))
		escaped := t.kind == .EscapedIdent
		return svp_parse_assignment_or_call(p, name, escaped)
	}
	if t.kind == .Inc || t.kind == .Dec {
		return svp_parse_assignment_or_call_expr(p, svp_parse_unary(p))
	}
	base := svp_parse_primary(p)
	return svp_parse_assignment_or_call_expr(p, base)
}

svp_parse_assignment_or_call :: proc(p: ^SVParser2, name: string, escaped: bool) -> u32 {
	if escaped {
		return svp_parse_assignment_or_call_expr(p, svp_expr_ident(p, name))
	}
	// scoped call / scoped name in statement position
	if svp_at(p, .ColonColon) {
		svp_bump(p)
		member := svp_expect_ident(p)
		qual := strings.concatenate({name, "::", member}, p.allocator)
		if svp_at(p, .LParen) {
			e := svp_parse_call(p, qual, false)
			_ = svp_expect(p, .Semicolon)
			return e
		}
		_ = svp_expect(p, .Semicolon)
		call := svp_node(p, .Expr_Call)
		svn(p, call).a = svp_str(p, qual)
		return call
	}
	if svp_at(p, .LParen) {
		e := svp_parse_call(p, name, false)
		_ = svp_expect(p, .Semicolon)
		return e
	}
	if svp_at(p, .Semicolon) {
		svp_bump(p)
		call := svp_node(p, .Expr_Call)
		svn(p, call).a = svp_str(p, name)
		return call
	}
	return svp_parse_assignment_or_call_expr(p, svp_expr_ident(p, name))
}

svp_parse_assignment_or_call_expr :: proc(p: ^SVParser2, prefix: u32) -> u32 {
	base := svp_parse_postfix(p, prefix)
	if svp_accept(p, .Semicolon) {
		#partial switch sv_node_kind(p.ast, base) {
		case .Expr_Call, .Expr_IncDec: return base
		case .Expr_Ident:
			call := svp_node(p, .Expr_Call)
			svn(p, call).a = sv_node(p.ast, base).a
			return call
		case .Expr_ScopedName:
			n := sv_node(p.ast, base)
			scope := sv_text(p.ast, n.a)
			name := sv_text(p.ast, n.b)
			call := svp_node(p, .Expr_Call)
			svn(p, call).a = svp_str(p, strings.concatenate({scope, "::", name}, p.allocator))
			return call
		case: svp_error(p, "only subroutine calls and ++/-- can stand alone as expressions")
		}
	}
	op := SVAssignOp.EQ
	nonblocking := false
	#partial switch svp_peek(p).kind {
	case .Assign: op = .EQ
	case .Le: // `<=` is nonblocking only when not followed by a delay/event control of a comparison
			nonblocking = true
	case .PlusEq: op = .ADD_EQ
	case .MinusEq: op = .SUB_EQ
	case .StarEq: op = .MUL_EQ
	case .SlashEq: op = .DIV_EQ
	case .PercentEq: op = .MOD_EQ
	case .AmpEq: op = .AND_EQ
	case .PipeEq: op = .OR_EQ
	case .CaretEq: op = .XOR_EQ
	case .ShlEq: op = .SHL_EQ
	case .ShrEq: op = .SHR_EQ
	case .AshlEq: op = .ASH_L_EQ
	case .AshrEq: op = .ASH_R_EQ
	case: svp_error(p, "expected an assignment or a call")
	}
	svp_bump(p)
	timing := u32(SV_NONE)
	if svp_at(p, .Hash) || svp_at(p, .At) {
		timing = svp_parse_timing_ctl(p)
	}
	rhs := svp_parse_expr(p, 0)
	_ = svp_expect(p, .Semicolon)
	assign := svp_node(p, .Stmt_Assign)
	an := svn(p, assign)
	an.a = base
	an.b = u32(op)
	an.c = rhs
	an.d = timing
	if nonblocking { an.flags |= SVF_ASSIGN_NONBLOCKING }
	return assign
}

svp_parse_block :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Begin)
	block := svp_node(p, .Stmt_Block)
	bn := svn(p, block)
	bn.a = SV_NONE
	if svp_accept(p, .Colon) {
		svn(p, block).a = svp_str(p, svp_expect_ident(p))
	}
	base := p.list_depth
	d_decls := svp_list_open(p)
	d_stmts := svp_list_open(p)
	for !svp_at_eof(p) {
		svp_skip_attributes(p)
		if svp_kw_at(p, .End) {
			svp_bump(p)
			svp_skip_end_label(p)
			break
		}
		if svp_accept(p, .Semicolon) { continue }
		t := svp_peek(p)
		if t.kw == .Import {
			sp := svp_parse_import_list(p)
			n := svn(p, block)
			if n.c == 0 { n.b = sp.start }
			n.c += sp.len
			continue
		}
		if t.kw == .Typedef {
			svp_list_add(p, d_decls, svp_parse_typedef(p))
			continue
		}
		if t.kw == .Parameter || t.kw == .Localparam {
			svp_bump(p)
			decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
			_ = svp_expect(p, .Semicolon)
			svp_list_add(p, d_decls, decl)
			continue
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			svp_list_add(p, d_decls, svp_parse_net_decl(p))
			continue
		}
		if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && (svp_is_ident(svp_peek(p, 3)) || svp_at(p, .LBracket, 3)) {
			scope := svp_expect_ident(p)
			_ = svp_expect(p, .ColonColon)
			member := svp_expect_ident(p)
			data := svp_type_from_name(p, scope, member)
			svp_list_add(p, d_decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		if svp_is_ident(t) && (svp_is_ident(svp_peek(p, 1)) || (svp_at(p, .LBracket, 1) && svp_ident_dims_then_ident(p))) {
			name := svp_expect_ident(p)
			data := svp_type_from_name(p, "", name)
			svp_list_add(p, d_decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		svp_list_add(p, d_stmts, svp_parse_statement(p))
	}
	svp_list_discard(p, base)
	decls := svp_list_commit(p, d_decls)
	stmts := svp_list_commit(p, d_stmts)
	p.list_depth = base
	bn.d = decls.len
	bn.span = SVSpan {
		start = decls.start,
		len   = decls.len + stmts.len,
	}
	return block
}

svp_parse_if :: proc(p: ^SVParser2, q: SVQualifier) -> u32 {
	_ = svp_expect_kw(p, .If)
	_ = svp_expect(p, .LParen)
	cond := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	then_body := svp_parse_statement_or_null(p)
	else_body := u32(SV_NONE)
	if svp_accept_kw(p, .Else) { else_body = svp_parse_statement_or_null(p) }
	node := svp_node(p, .Stmt_If)
	svn(p, node).d = SV_NONE
	svn(p, node).a = u32(q)
	svn(p, node).b = cond
	svn(p, node).c = then_body
	svn(p, node).d = else_body
	return node
}

svp_parse_case :: proc(p: ^SVParser2, q: SVQualifier) -> u32 {
	kind := SVCaseKind.CASE
	#partial switch svp_peek(p).kw {
	case .Casez: kind = .CASEZ
	case .Casex: kind = .CASEX
	}
	svp_bump(p)
	node := svp_node(p, .Stmt_Case)
	nn := svn(p, node)
	nn.flags = (u16(kind) & SVF_CASE_KIND_MASK) | ((u16(q) << SVF_CASE_QUAL_SHIFT) & SVF_CASE_QUAL_MASK)
	_ = svp_expect(p, .LParen)
	subject := svp_parse_expr(p, 0)
	nn.a = subject
	_ = svp_expect(p, .RParen)
	if svp_accept_kw(p, .Inside) { nn.flags |= SVF_CASE_INSIDE }
	is_inside := (nn.flags & SVF_CASE_INSIDE) != 0
	d := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endcase) {
		item := svp_node(p, .Aux_CaseItem)
		it := svn(p, item)
		it.a = SV_NONE
		if svp_accept_kw(p, .Default) {
			it.flags |= 0x1
			_ = svp_accept(p, .Colon)
		} else {
			ed := svp_list_open(p)
			for {
				if is_inside && svp_at(p, .LBracket) {
					r := svp_node(p, .Aux_InsideRange)
					rn := svn(p, r)
					rn.b = SV_NONE
					svp_bump(p)
					lo := svp_parse_expr(p, 0)
					rn.a = lo
					if svp_accept(p, .Colon) {
						hi := svp_parse_expr(p, 0)
						rn.b = hi
						rn.flags |= 0x1
					}
					_ = svp_expect(p, .RBracket)
					svp_list_add(p, ed, r)
				} else {
					svp_list_add(p, ed, svp_parse_expr(p, 0))
				}
				if !svp_accept(p, .Comma) { break }
			}
			it.span = svp_list_close(p, ed)
			_ = svp_expect(p, .Colon)
		}
		body := svp_parse_statement_or_null(p)
		it.a = body
		svp_list_add(p, d, item)
	}
	svn(p, node).span = svp_list_close(p, d)
	_ = svp_expect_kw(p, .Endcase)
	return node
}

svp_parse_for :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .For)
	node := svp_node(p, .Stmt_For)
	_ = svp_expect(p, .LParen)
	d_decls := svp_list_open(p)
	d_inits := svp_list_open(p)
	if !svp_at(p, .Semicolon) {
		t := svp_peek(p)
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket || (svp_is_ident(t) && svp_is_ident(svp_peek(p, 1))) {
			decl := svp_node(p, .Item_NetDecl)
			dn := svn(p, decl)
			data := svp_parse_type(p, true)
			dn.a = data
			dd := svp_list_open(p)
			for {
				declarator := svp_parse_declarator(p)
				svp_list_add(p, dd, declarator)
				if !svp_accept(p, .Comma) { break }
			}
			dn.span = svp_list_close(p, dd)
			svp_list_add(p, d_decls, decl)
		} else {
			for {
				svp_list_add(p, d_inits, svp_parse_for_assign(p))
				if !svp_accept(p, .Comma) { break }
			}
		}
	}
	_ = svp_expect(p, .Semicolon)
	cond := u32(SV_NONE)
	if !svp_at(p, .Semicolon) { cond = svp_parse_expr(p, 0) }
	_ = svp_expect(p, .Semicolon)
	d_steps := svp_list_open(p)
	if !svp_at(p, .RParen) {
		for {
			svp_list_add(p, d_steps, svp_parse_stmt_no_semi(p))
			if !svp_accept(p, .Comma) { break }
		}
	}
	_ = svp_expect(p, .RParen)
	body := svp_parse_statement_or_null(p)
	decls := svp_list_commit(p, d_decls)
	inits := svp_list_commit(p, d_inits)
	steps := svp_list_commit(p, d_steps)
	p.list_depth = d_decls
	nn := svn(p, node)
	nn.a = cond
	nn.b = body
	nn.c = decls.len
	nn.d = inits.len
	nn.span = SVSpan {
		start = decls.start,
		len   = decls.len + inits.len + steps.len,
	}
	return node
}

svp_parse_for_assign :: proc(p: ^SVParser2) -> u32 {
	base := svp_parse_postfix(p, svp_parse_primary(p))
	rhs := u32(SV_NONE)
	if svp_accept(p, .Assign) {
		rhs = svp_parse_expr(p, 0)
	}
	node := svp_node(p, .Stmt_Assign)
	svn(p, node).a = base
	svn(p, node).c = rhs
	svn(p, node).d = SV_NONE
	return node
}

svp_parse_stmt_no_semi :: proc(p: ^SVParser2) -> u32 {
	t := svp_peek(p)
	if t.kind == .Inc || t.kind == .Dec {
		e := svp_parse_unary(p)
		if sv_node_kind(p.ast, e) == .Expr_IncDec { return e }
		return svp_parse_assignment_no_semi_expr(p, e)
	}
	if svp_is_ident(t) || t.kind == .EscapedIdent {
		name := svp_text(p, svp_advance(p))
		if svp_at(p, .LParen) { return svp_parse_call(p, name, false) }
		if svp_at(p, .Inc) || svp_at(p, .Dec) {
			is_dec := svp_at(p, .Dec)
			svp_bump(p)
			return svp_expr_incdec(p, svp_expr_ident(p, name), is_dec, false)
		}
		return svp_parse_assignment_no_semi(p, svp_expr_ident(p, name))
	}
	return svp_parse_assignment_no_semi_expr(p, svp_parse_primary(p))
}

svp_parse_assignment_no_semi :: proc(p: ^SVParser2, prefix: u32) -> u32 {
	return svp_parse_assignment_no_semi_expr(p, svp_parse_postfix(p, prefix))
}

svp_parse_assignment_no_semi_expr :: proc(p: ^SVParser2, base: u32) -> u32 {
	if svp_at(p, .Inc) || svp_at(p, .Dec) {
		is_dec := svp_at(p, .Dec)
		svp_bump(p)
		return svp_expr_incdec(p, base, is_dec, false)
	}
	op := SVAssignOp.EQ
	nonblocking := false
	#partial switch svp_peek(p).kind {
	case .Assign: op = .EQ
	case .Le: nonblocking = true
	case .PlusEq: op = .ADD_EQ
	case .MinusEq: op = .SUB_EQ
	case .StarEq: op = .MUL_EQ
	case .SlashEq: op = .DIV_EQ
	case .PercentEq: op = .MOD_EQ
	case .AmpEq: op = .AND_EQ
	case .PipeEq: op = .OR_EQ
	case .CaretEq: op = .XOR_EQ
	case .ShlEq: op = .SHL_EQ
	case .ShrEq: op = .SHR_EQ
	case .AshlEq: op = .ASH_L_EQ
	case .AshrEq: op = .ASH_R_EQ
	case: svp_error(p, "expected an assignment")
	}
	svp_bump(p)
	rhs := svp_parse_expr(p, 0)
	node := svp_node(p, .Stmt_Assign)
	svn(p, node).a = base
	svn(p, node).b = u32(op)
	svn(p, node).c = rhs
	svn(p, node).d = SV_NONE
	if nonblocking { svn(p, node).flags |= SVF_ASSIGN_NONBLOCKING }
	return node
}

svp_parse_while :: proc(p: ^SVParser2, do_while: bool) -> u32 {
	body := u32(SV_NONE)
	if do_while {
		_ = svp_expect_kw(p, .Do)
		body = svp_parse_statement_or_null(p)
		_ = svp_expect_kw(p, .While)
	} else {
		_ = svp_expect_kw(p, .While)
	}
	_ = svp_expect(p, .LParen)
	cond := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	if !do_while { body = svp_parse_statement_or_null(p) } else { _ = svp_expect(p, .Semicolon) }
	node := svp_node(p, .Stmt_While)
	svn(p, node).a = cond
	svn(p, node).b = body
	if do_while { svn(p, node).flags |= SVF_WHILE_DO }
	return node
}

svp_parse_repeat :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Repeat)
	_ = svp_expect(p, .LParen)
	count := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	body := svp_parse_statement_or_null(p)
	node := svp_node(p, .Stmt_Repeat)
	svn(p, node).a = count
	svn(p, node).b = body
	return node
}

svp_parse_forever :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Forever)
	node := svp_node(p, .Stmt_Forever)
	body := svp_parse_statement_or_null(p)
	svn(p, node).a = body
	return node
}

svp_parse_foreach :: proc(p: ^SVParser2) -> u32 {
	_ = svp_expect_kw(p, .Foreach)
	node := svp_node(p, .Stmt_Foreach)
	nn := svn(p, node)
	nn.a = SV_NONE
	nn.b = SV_NONE
	_ = svp_expect(p, .LParen)
	array := svp_parse_primary(p)
	for svp_accept(p, .Dot) {
		member := svp_expect_ident(p)
		part := svp_node(p, .Aux_SelectPart)
		svn(p, part).a = svp_str(p, member)
		d := svp_list_open(p)
		svp_list_add(p, d, part)
		span := svp_list_close(p, d)
		sel := svp_node(p, .Expr_Select)
		sn := svn(p, sel)
		sn.a = array
		sn.span = span
		array = sel
	}
	nn.a = array
	_ = svp_expect(p, .LBracket)
	d := svp_list_open(p)
	for !svp_at(p, .RBracket) {
		if svp_at(p, .Comma) {
			svp_list_add(p, d, svp_str_node(p, ""))
			svp_bump(p)
			continue
		}
		name := svp_expect_ident(p)
		svp_list_add(p, d, svp_str_node(p, name))
		_ = svp_accept(p, .Comma)
	}
	_ = svp_expect(p, .RBracket)
	svn(p, node).span = svp_list_close(p, d)
	_ = svp_expect(p, .RParen)
	body := svp_parse_statement_or_null(p)
	svn(p, node).b = body
	return node
}

svp_parse_assertion :: proc(p: ^SVParser2, kind: SVAssertKind) -> u32 {
	svp_bump(p)
	node := svp_node(p, .Stmt_Assert)
	nn := svn(p, node)
	nn.a = SV_NONE
	nn.b = SV_NONE
	nn.c = SV_NONE
	nn.flags = u16(kind) & SVF_ASSERT_KIND_MASK
	if svp_accept_kw(p, .Final) {
		// deferred assertion
	} else if svp_accept(p, .Hash) {
		svp_bump(p) // #0
	}
	if svp_accept_kw(p, .Property) {
		nn.flags |= SVF_ASSERT_PROPERTY
		if svp_accept(p, .LParen) {
			depth := 1
			b := strings.builder_make(p.allocator)
			for !svp_at_eof(p) && depth > 0 {
				if svp_at(p, .LParen) { depth += 1 }
				if svp_at(p, .RParen) {
					depth -= 1
					if depth == 0 { svp_bump(p); break }
				}
				if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
				strings.write_string(&b, svp_text(p, svp_peek(p)))
				svp_bump(p)
			}
			nn.a = svp_str(p, strings.to_string(b))
		}
		if svp_accept_kw(p, .Else) {
			else_body := svp_parse_statement_or_null(p)
			nn.c = else_body
			return node
		}
		if !svp_at(p, .Semicolon) {
			pass_body := svp_parse_statement_or_null(p)
			nn.b = pass_body
			return node
		}
		_ = svp_expect(p, .Semicolon)
		return node
	}
	if svp_at(p, .LParen) {
		svp_bump(p)
		cond := svp_parse_expr(p, 0)
		svn(p, node).a = cond
		_ = svp_expect(p, .RParen)
	} else {
		cond := svp_parse_expr(p, 0)
		svn(p, node).a = cond
	}
	if svp_accept_kw(p, .Else) {
		else_body := svp_parse_statement_or_null(p)
		svn(p, node).c = else_body
		return node
	}
	if !svp_at(p, .Semicolon) {
		pass_body := svp_parse_statement_or_null(p)
		svn(p, node).b = pass_body
		return node
	}
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_subroutine :: proc(p: ^SVParser2, is_task: bool) -> u32 {
	svp_bump(p) // function/task
	sub := svp_node(p, .Item_Subroutine)
	sn := svn(p, sub)
	sn.b = SV_NONE
	if is_task { sn.flags |= SVF_SUB_TASK }
	if svp_accept_kw(p, .Automatic) {
		sn.flags |= SVF_SUB_AUTOMATIC
	} else {
		_ = svp_accept_kw(p, .Static)
	}

	if !is_task {
		t := svp_peek(p)
		if t.kw == .Void {
			svp_bump(p)
			void_type := svp_node(p, .Aux_DataType)
			svn(p, void_type).flags = u16(SVVarType.VOID) & SVF_DATA_VARTYPE_MASK
			sn.b = void_type
		} else if svp_starts_return_type(p) {
			data := svp_parse_type(p, true)
			sn.b = data
		}
	}
	name := svp_expect_ident(p)
	sn.a = svp_str(p, name)
	d := svp_list_open(p)
	if svp_at(p, .LParen) {
		svp_parse_tf_ports(p, d)
	}
	_ = svp_expect(p, .Semicolon)
	body := svp_parse_subroutine_body(p, d)
	sn.span = svp_list_close(p, d)
	sn.c = body
	svp_bump(p) // endfunction/endtask
	svp_skip_end_label(p)
	return sub
}

svp_starts_return_type :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if t.kind == .LBracket { return true }
	if _, ok := svp_var_type(t.kw); ok { return true }
	if t.kw == .Enum || t.kw == .Struct || t.kw == .Union || t.kw == .Signed || t.kw == .Unsigned || t.kw == .Var { return true }
	if svp_is_ident(t) {
		n := svp_peek(p, 1)
		if n.kind == .ColonColon { return true }
		// `T name` is a return type; `name (` / `name ;` is an implicit-return function.
		if svp_is_ident(n) { return true }
		if n.kind == .LBracket { return true }
	}
	return false
}

svp_parse_tf_ports :: proc(p: ^SVParser2, depth: int) {
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		port := svp_node(p, .Aux_TFPort)
		pn := svn(p, port)
		pn.a = SV_NONE
		pn.c = SV_NONE
		if d, ok := svp_port_dir(svp_peek(p).kw); ok {
			svn(p, port).flags |= u16(d) & SVF_DIR_MASK
			svp_bump(p)
		} else if svp_accept_kw(p, .Ref) {
			pn.flags |= u16(SVPortDir.REF) & SVF_DIR_MASK
		}
		if svp_starts_tf_type(p) {
			data := svp_parse_type(p, true)
			svn(p, port).a = data
		}
		name := svp_expect_ident(p)
		pn.b = svp_str(p, name)
		dd := svp_list_open(p)
		for svp_at(p, .LBracket) {
			svp_list_add(p, dd, svp_parse_range(p))
		}
		pn.span = svp_list_close(p, dd)
		if svp_accept(p, .Assign) {
			value := svp_parse_expr(p, 0)
			pn.c = value
		}
		svp_list_add(p, depth, port)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RParen)
}

svp_starts_tf_type :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if t.kind == .LBracket { return true }
	if _, ok := svp_var_type(t.kw); ok { return true }
	if t.kw == .Enum || t.kw == .Struct || t.kw == .Union || t.kw == .Signed || t.kw == .Unsigned || t.kw == .Var { return true }
	if svp_is_ident(t) {
		n := svp_peek(p, 1)
		if svp_is_ident(n) || n.kind == .ColonColon { return true }
		if n.kind == .LBracket && svp_ident_dims_then_ident(p) { return true }
	}
	return false
}

svp_parse_subroutine_body :: proc(p: ^SVParser2, ports_depth: int) -> u32 {
	block := svp_node(p, .Stmt_Block)
	bn := svn(p, block)
	bn.a = SV_NONE
	base := p.list_depth
	d_decls := svp_list_open(p)
	d_stmts := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endfunction) && !svp_kw_at(p, .Endtask) {
		svp_skip_attributes(p)
		t := svp_peek(p)
		if t.kw == .Import {
			sp := svp_parse_import_list(p)
			n := svn(p, block)
			if n.c == 0 { n.b = sp.start }
			n.c += sp.len
			continue
		}
		if t.kw == .Typedef {
			svp_list_add(p, d_decls, svp_parse_typedef(p))
			continue
		}
		if t.kw == .Parameter || t.kw == .Localparam {
			svp_bump(p)
			decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
			_ = svp_expect(p, .Semicolon)
			svp_list_add(p, d_decls, decl)
			continue
		}
		if d, ok := svp_port_dir(t.kw); ok {
			// Legacy task/function port declaration.
			svp_bump(p)
			data := u32(SV_NONE)
			if svp_starts_tf_type(p) { data = svp_parse_type(p, true) }
			for {
				port := svp_node(p, .Aux_TFPort)
				svn(p, port).a = SV_NONE
				svn(p, port).c = SV_NONE
				svn(p, port).flags = u16(d) & SVF_DIR_MASK
				if data != SV_NONE { svn(p, port).a = data }
				name := svp_expect_ident(p)
				svn(p, port).b = svp_str(p, name)
				dd := svp_list_open(p)
				for svp_at(p, .LBracket) {
					svp_list_add(p, dd, svp_parse_range(p))
				}
				svn(p, port).span = svp_list_close(p, dd)
				svp_list_add(p, ports_depth, port)
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .Semicolon)
			continue
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			svp_list_add(p, d_decls, svp_parse_net_decl(p))
			continue
		}
		if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && (svp_is_ident(svp_peek(p, 3)) || svp_at(p, .LBracket, 3)) {
			scope := svp_expect_ident(p)
			_ = svp_expect(p, .ColonColon)
			member := svp_expect_ident(p)
			data := svp_type_from_name(p, scope, member)
			svp_list_add(p, d_decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		if svp_is_ident(t) && (svp_is_ident(svp_peek(p, 1)) || (svp_at(p, .LBracket, 1) && svp_ident_dims_then_ident(p))) {
			name := svp_expect_ident(p)
			data := svp_type_from_name(p, "", name)
			svp_list_add(p, d_decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		svp_list_add(p, d_stmts, svp_parse_statement(p))
	}
	decls := svp_list_commit(p, d_decls)
	stmts := svp_list_commit(p, d_stmts)
	p.list_depth = base
	bn.d = decls.len
	bn.span = SVSpan {
		start = decls.start,
		len   = decls.len + stmts.len,
	}
	return block
}

// Parse bytes through the tokenizer/preprocessor and compact parser.
svp_parse_source_to_ast :: proc(data: []byte, filepath: string, ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	old := context.allocator
	context.allocator = allocator
	defer context.allocator = old
	dir := sv_path_directory(filepath)
	if len(dir) > 0 {
		known := false
		for existing in ast.file_dirs { if existing == dir { known = true; break } }
		if !known { append(&ast.file_dirs, dir) }
	}
	pp := svpp_init(ast, allocator)
	toks := svpp_preprocess(&pp, data, filepath)
	svp_parse_tokens(ast, toks, pp.source_data[:], filepath, allocator)
}

svp_parse_gen_block_after_begin :: proc(p: ^SVParser2, label: string) -> u32 {
	block := svp_node(p, .Stmt_Block)
	svn(p, block).a = svp_str(p, label)
	if svp_accept(p, .Colon) {
		svn(p, block).a = svp_str(p, svp_expect_ident(p))
	}
	d := svp_list_open(p)
	for !svp_at_eof(p) && !svp_kw_at(p, .End) {
		svp_parse_module_item(p, d)
	}
	svn(p, block).span = svp_list_close(p, d)
	_ = svp_expect_kw(p, .End)
	svp_skip_end_label(p)
	return block
}
