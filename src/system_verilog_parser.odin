/*
Compact SystemVerilog parser over the preprocessed token stream.

This is the data-oriented replacement for the byte-scanning recursive descent
parser: the parser only ever indexes SVToken values, so there is no trivia
rescanning, no save/restore of the lexer for lookahead, and keyword dispatch is
an enum switch. AST nodes keep the same public types used by the rest of the
frontend.
*/

package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

SVParser2 :: struct {
	toks:      []SVToken,
	sources:   []SVSource, // token offsets index these source buffers

	i:         int,
	ast:       ^SystemVerilogAST,
	allocator: mem.Allocator,
	module:    ^SVModule,
	iface:     ^SVInterface,
	port_map:  map[string]^SVPort,
	port_map_ready: bool,
	filepath:  string,

	// AST nodes are bump-allocated from large chunks. This avoids one arena
	// allocator call per node and keeps sibling nodes close in memory.
	node_buf:  []byte,
	node_off:  int,

	// Incremental line lookup for diagnostics and retained attributes. Tokens are
	// visited in source order, so each source byte is scanned at most once.
	line_file:  u16,
	line_off:   u32,
	line_value: u32,
	line_valid: bool,
}

// The preprocessor appends four EOF sentinels, so the parser's maximum lookahead
// (three tokens) can index without bounds checks.
svp_peek :: #force_inline proc(p: ^SVParser2, n := 0) -> SVToken {
	#no_bounds_check return p.toks[p.i + n]
}

svp_at :: #force_inline proc(p: ^SVParser2, kind: SVTokenKind, n := 0) -> bool {
	#no_bounds_check return p.toks[p.i + n].kind == kind
}

svp_kw_at :: #force_inline proc(p: ^SVParser2, kw: SVKeyword, n := 0) -> bool {
	#no_bounds_check return p.toks[p.i + n].kw == kw
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

svp_node_alloc :: #force_inline proc(p: ^SVParser2, size, alignment: int) -> rawptr {
	if p.node_off + size + alignment > len(p.node_buf) {
		chunk, err := mem.alloc_bytes_non_zeroed(16 << 10, 16, p.allocator)
		ensure(err == nil, "SystemVerilog AST allocation failed")
		p.node_buf = chunk
		p.node_off = 0
	}
	off := (p.node_off + alignment - 1) & ~(alignment - 1)
	p.node_off = off + size
	return rawptr(&p.node_buf[off])
}

svp_new :: proc(p: ^SVParser2, $T: typeid) -> ^T {
	ptr := cast(^T)svp_node_alloc(p, size_of(T), align_of(T))
	mem.zero_slice(mem.byte_slice(ptr, size_of(T)))
	return ptr
}

svp_set :: proc(p: ^SVParser2, value: $T) -> ^T {
	// The value initializes every byte, so the chunk does not need zeroing first.
	ptr := cast(^T)svp_node_alloc(p, size_of(T), align_of(T))
	ptr^ = value
	return ptr
}

svp_expr :: proc(p: ^SVParser2, e: SVExpr) -> ^SVExpr {
	return svp_set(p, e)
}

// Small AST lists (one or two ports, one range, one call argument, ...) are the
// common case. Odin's default dynamic-array growth starts at eight elements, so
// reserving a small initial capacity avoids a large amount of wasted arena and
// the zeroing/copying that comes with it.
svp_add :: #force_inline proc(p: ^SVParser2, list: ^[dynamic]$T, value: T, initial_cap := 1) {
	if len(list^) == cap(list^) {
		new_cap := initial_cap
		if cap(list^) > 0 { new_cap = cap(list^) * 2 }
		// The appended element initializes its slot, so growth can skip zeroing the
		// new capacity instead of asking the arena to clear memory we overwrite.
		non_zero_reserve(list, new_cap)
	}
	// Capacity was just ensured, so this append only writes the element.
	append(list, value)
}

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
		append(&p.ast.attributes, SVAttribute{
			text = text,
			path = path,
			line = line,
			owner_line = owner_line,
		})
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
	for {
		svp_skip_attributes(p)
		if svp_at_eof(p) { break }
		t := svp_peek(p)
		#partial switch t.kw {
		case .Module, .Macromodule: _ = svp_parse_module(p)
		case .Package: _ = svp_parse_package(p)
		case .Interface: _ = svp_parse_interface(p)
		case .Typedef: append(&p.ast.items, svp_parse_typedef(p))
		case .Parameter, .Localparam:
			svp_bump(p)
			decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
			_ = svp_expect(p, .Semicolon)
			append(&p.ast.items, decl)
		case .Function: append(&p.ast.items, svp_parse_subroutine(p, false))
		case .Task: append(&p.ast.items, svp_parse_subroutine(p, true))
		case .Import: svp_parse_import_list(p, &p.ast.imports)
		case .Class:
			svp_skip_until_kw(p, .Endclass)
			svp_skip_end_label(p)
		case:
			svp_error(p, fmt.tprintf("unsupported top-level construct '%s'", svp_text(p, t)))
		}
	}
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
	case .Var, .Const, .Automatic, .Static, .Signed, .Unsigned, .Enum, .Struct, .Union, .Parameter, .Localparam:
		return true
	}
	return false
}

svp_is_gate_kw :: proc(kw: SVKeyword) -> bool {
	#partial switch kw {
	case .And, .Nand, .Or, .Nor, .Xor, .Xnor, .Not, .Buf, .Bufif0, .Bufif1,
	     .Notif0, .Notif1, .Nmos, .Pmos, .Cmos, .Rnmos, .Rpmos, .Rcmos,
	     .Tran, .Tranif0, .Tranif1, .Rtran, .Rtranif0, .Rtranif1, .Pullup, .Pulldown:
		return true
	}
	return false
}

// ---------------------------------------------------------------------------------------
// Types, ranges, declarators
// ---------------------------------------------------------------------------------------

svp_parse_range :: proc(p: ^SVParser2) -> SVRange {
	_ = svp_expect(p, .LBracket)
	r: SVRange
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
			r.is_size = true
			return r
		}
	}
	r.msb = svp_parse_expr(p, 0)
	if svp_accept(p, .Colon) {
		r.lsb = svp_parse_expr(p, 0)
	}
	_ = svp_expect(p, .RBracket)
	return r
}

svp_parse_type_signing_dims :: proc(p: ^SVParser2, data: SVDataType) -> SVDataType {
	d := data
	if svp_accept_kw(p, .Signed) {
		d.is_signed = true
	} else if svp_accept_kw(p, .Unsigned) {
		d.is_signed = false
	}
	for svp_at(p, .LBracket) {
		svp_add(p, &d.packed_dims, svp_parse_range(p))
	}
	return d
}

svp_parse_type :: proc(p: ^SVParser2, allow_implicit := true) -> SVDataType {
	data: SVDataType
	for {
		t := svp_peek(p)
		if t.kw == .Var || t.kw == .Const || t.kw == .Automatic || t.kw == .Static {
			svp_bump(p)
			continue
		}
		break
	}
	t := svp_peek(p)
	if vt, ok := svp_var_type(t.kw); ok {
		svp_bump(p)
		data.var_type = vt
	} else if t.kw == .Enum {
		svp_bump(p)
		data.spec = svp_parse_type_spec(p, .ENUM)
	} else if t.kw == .Struct || t.kw == .Union {
		svp_bump(p)
		data.spec = svp_parse_type_spec(p, t.kw == .Struct ? .STRUCT : .UNION)
	} else if svp_is_ident(t) {
		scope, name := svp_parse_scoped_type_name(p)
		data.type_scope = scope
		data.type_name = name
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

svp_parse_type_spec :: proc(p: ^SVParser2, kind: SVTypeSpecKind) -> ^SVTypeSpec {
	spec := svp_new(p, SVTypeSpec)
	spec.kind = kind
	if kind == .ENUM {
		if !svp_at(p, .LBrace) { spec.base = svp_parse_type(p) }
		_ = svp_expect(p, .LBrace)
		for !svp_at(p, .RBrace) {
			entry := SVEnumName{name = svp_expect_ident(p)}
			if svp_accept(p, .LBracket) {
				for !svp_at(p, .RBracket) && !svp_at_eof(p) { svp_bump(p) }
				_ = svp_expect(p, .RBracket)
			}
			if svp_accept(p, .Assign) { entry.value = svp_expr(p, svp_parse_expr(p, 0)) }
			svp_add(p, &spec.enum_names, entry)
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .RBrace)
		return spec
	}
	if svp_accept_kw(p, .Packed) {
		spec.is_packed = true
		_ = svp_accept_kw(p, .Signed)
	}
	_ = svp_expect(p, .LBrace)
	for !svp_at(p, .RBrace) {
		data := svp_parse_type(p, false)
		member := SVStructMember{data = data}
		for {
			decl := SVDeclarator{name = svp_expect_ident(p)}
			for svp_at(p, .LBracket) { svp_add(p, &decl.unpacked_dims, svp_parse_range(p)) }
			if svp_accept(p, .Assign) { decl.init = svp_expr(p, svp_parse_expr(p, 0)) }
			svp_add(p, &member.declarators, decl)
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .Semicolon)
		svp_add(p, &spec.members, member)
	}
	_ = svp_expect(p, .RBrace)
	return spec
}

svp_parse_declarators :: proc(p: ^SVParser2) -> [dynamic]SVDeclarator {
	decls: [dynamic]SVDeclarator
	for {
		decl := SVDeclarator{name = svp_expect_ident(p)}
		for svp_at(p, .LBracket) { svp_add(p, &decl.unpacked_dims, svp_parse_range(p)) }
		if svp_accept(p, .Assign) { decl.init = svp_expr(p, svp_parse_expr(p, 0)) }
		svp_add(p, &decls, decl)
		if !svp_accept(p, .Comma) { break }
	}
	return decls
}

svp_parse_typedef :: proc(p: ^SVParser2) -> ^SVTypeDecl {
	_ = svp_expect_kw(p, .Typedef)
	data := svp_parse_type(p, false)
	name := svp_expect_ident(p)
	dims: [dynamic]SVRange
	for svp_at(p, .LBracket) { svp_add(p, &dims, svp_parse_range(p)) }
	_ = svp_expect(p, .Semicolon)
	p.ast.type_names[name] = true
	return svp_set(p, SVTypeDecl{name = name, data = data, unpacked_dims = dims})
}

svp_parse_net_decl_after_keyword :: proc(p: ^SVParser2, net_type: SVNetType, data: SVDataType) -> ^SVNetDecl {
	declarators := svp_parse_declarators(p)
	_ = svp_expect(p, .Semicolon)
	return svp_set(p, SVNetDecl{data = data, declarators = declarators, net_type = net_type})
}

svp_parse_net_data_type :: proc(p: ^SVParser2) -> SVDataType {
	t := svp_peek(p)
	if t.kind == .LBracket { return svp_parse_type(p, true) }
	if _, ok := svp_var_type(t.kw); ok { return svp_parse_type(p, true) }
	#partial switch t.kw {
	case .Enum, .Struct, .Union, .Signed, .Unsigned, .Var, .Const, .Automatic, .Static:
		return svp_parse_type(p, true)
	}
	if svp_is_ident(t) {
		n := svp_peek(p, 1)
		if svp_is_ident(n) || n.kind == .ColonColon { return svp_parse_type(p, false) }
	}
	return {}
}

svp_parse_net_decl :: proc(p: ^SVParser2) -> ^SVNetDecl {
	t := svp_peek(p)
	net_type := SVNetType.NONE
	data: SVDataType
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

svp_parse_param_assignments :: proc(p: ^SVParser2, decl: ^SVParamDecl, in_port_list: bool, stop_at_group := false) {
	for {
		a := SVParamAssign{name = svp_expect_ident(p)}
		for svp_at(p, .LBracket) { svp_add(p, &a.unpacked_dims, svp_parse_range(p)) }
		if svp_accept(p, .Assign) { a.value = svp_expr(p, svp_parse_expr(p, 0)) }
		svp_add(p, &decl.assignments, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
		if stop_at_group && in_port_list && svp_param_comma_starts_group(p) { p.i -= 1; break }
	}
}

svp_parse_type_param_decl :: proc(p: ^SVParser2, is_local: bool, in_port_list: bool) -> ^SVParamDecl {
	decl := svp_new(p, SVParamDecl)
	decl.is_local = is_local
	decl.is_type = true
	for {
		a := SVParamAssign{name = svp_expect_ident(p)}
		p.ast.type_names[a.name] = true
		if svp_accept(p, .Assign) {
			v := svp_new(p, SVDataType)
			v^ = svp_parse_type(p, true)
			a.type_value = v
		}
		svp_add(p, &decl.assignments, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
		if in_port_list && svp_param_comma_starts_group(p) { p.i -= 1; break }
	}
	return decl
}

svp_parse_param_decl_after_keyword :: proc(p: ^SVParser2, is_local: bool, in_port_list: bool) -> ^SVParamDecl {
	if svp_accept_kw(p, .Type) {
		return svp_parse_type_param_decl(p, is_local, in_port_list)
	}
	decl := svp_new(p, SVParamDecl)
	decl.is_local = is_local
	decl.data = svp_parse_type_for_param(p)
	svp_parse_param_assignments(p, decl, in_port_list)
	return decl
}

// ---------------------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------------------

svp_bin_prec_lut: [SVTokenKind]u8

@(init)
svp_bin_prec_init :: proc "contextless" () {
	svp_bin_prec_lut[.Question] = 1
	svp_bin_prec_lut[.PipePipe] = 2
	svp_bin_prec_lut[.AmpAmp] = 3
	svp_bin_prec_lut[.Pipe] = 4
	svp_bin_prec_lut[.Caret] = 5
	svp_bin_prec_lut[.CaretTilde] = 5
	svp_bin_prec_lut[.TildeCaret] = 5
	svp_bin_prec_lut[.Amp] = 6
	svp_bin_prec_lut[.EqEq] = 7
	svp_bin_prec_lut[.NotEq] = 7
	svp_bin_prec_lut[.CaseEq] = 7
	svp_bin_prec_lut[.CaseNeq] = 7
	svp_bin_prec_lut[.WildEq] = 7
	svp_bin_prec_lut[.WildNeq] = 7
	svp_bin_prec_lut[.Lt] = 8
	svp_bin_prec_lut[.Le] = 8
	svp_bin_prec_lut[.Gt] = 8
	svp_bin_prec_lut[.Ge] = 8
	svp_bin_prec_lut[.Shl] = 9
	svp_bin_prec_lut[.Shr] = 9
	svp_bin_prec_lut[.Ashl] = 9
	svp_bin_prec_lut[.Ashr] = 9
	svp_bin_prec_lut[.Plus] = 10
	svp_bin_prec_lut[.Minus] = 10
	svp_bin_prec_lut[.Star] = 11
	svp_bin_prec_lut[.Slash] = 11
	svp_bin_prec_lut[.Percent] = 11
	svp_bin_prec_lut[.Pow] = 12
}

svp_bin_op :: proc(kind: SVTokenKind) -> SVBinOp {
	#partial switch kind {
	case .Pow: return .POW
	case .Star: return .MUL
	case .Slash: return .DIV
	case .Percent: return .MOD
	case .Plus: return .ADD
	case .Minus: return .SUB
	case .Ashl: return .ASH_L
	case .Ashr: return .ASH_R
	case .Shl: return .SHL
	case .Shr: return .SHR
	case .Le: return .LE
	case .Ge: return .GE
	case .Lt: return .LT
	case .Gt: return .GT
	case .CaseEq: return .CASE_EQ
	case .CaseNeq: return .CASE_NE
	case .WildEq: return .WILD_EQ
	case .WildNeq: return .WILD_NE
	case .EqEq: return .EQ
	case .NotEq: return .NE
	case .Amp: return .BIT_AND
	case .CaretTilde, .TildeCaret: return .BIT_XNOR
	case .Caret: return .BIT_XOR
	case .Pipe: return .BIT_OR
	case .AmpAmp: return .LOG_AND
	case .PipePipe: return .LOG_OR
	}
	return .ADD
}

// Most expressions are a single unary/primary with no following operator. Keep
// that case in a small inlined wrapper; the precedence loop's frame (inside,
// ternary and binary temporaries) is only built when an operator follows.
svp_parse_expr :: #force_inline proc(p: ^SVParser2, min_prec: u8 = 0) -> SVExpr {
	lhs := svp_parse_unary(p)
	kind := svp_peek(p).kind
	if !(kind == .Question && min_prec <= 1) &&
	   !(min_prec <= 8 && svp_kw_at(p, .Inside)) {
		prec := svp_bin_prec_lut[kind]
		if prec == 0 || prec < min_prec { return lhs }
	}
	return svp_parse_expr_slow(p, min_prec, lhs)
}

svp_parse_expr_slow :: proc(p: ^SVParser2, min_prec: u8, lhs_in: SVExpr) -> SVExpr {
	lhs := lhs_in
	for {
		// inside { range_list }
		if min_prec <= 8 && svp_kw_at(p, .Inside) {
			svp_bump(p)
			_ = svp_expect(p, .LBrace)
			ranges: [dynamic]SVInsideRange
			for {
				r: SVInsideRange
				if svp_accept(p, .LBracket) {
					r.lo = svp_parse_expr(p, 0)
					if svp_accept(p, .Colon) {
						r.hi = svp_parse_expr(p, 0)
						r.has_hi = true
					}
					_ = svp_expect(p, .RBracket)
				} else {
					r.lo = svp_parse_expr(p, 0)
				}
				svp_add(p, &ranges, r)
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .RBrace)
			lhs = svp_set(p, SVInside{subject = lhs, ranges = ranges})
			continue
		}
		kind := svp_peek(p).kind
		if kind == .Question && min_prec <= 1 {
			svp_bump(p)
			t := svp_parse_expr(p, 0)
			_ = svp_expect(p, .Colon)
			f := svp_parse_expr(p, 1)
			lhs = svp_set(p, SVTernary{cond = lhs, lhs = t, rhs = f})
			continue
		}
		prec := svp_bin_prec_lut[kind]
		if prec == 0 || prec < min_prec { break }
		svp_bump(p)
		rhs := svp_parse_expr(p, prec + 1)
		lhs = svp_set(p, SVBinary{op = svp_bin_op(kind), lhs = lhs, rhs = rhs})
	}
	return lhs
}

svp_is_unop_token :: #force_inline proc(kind: SVTokenKind) -> bool {
	#partial switch kind {
	case .Plus, .Minus, .Bang, .Tilde, .Amp, .TildeAmp, .Pipe, .TildePipe,
	     .Caret, .CaretTilde, .TildeCaret, .Inc, .Dec:
		return true
	}
	return false
}

// Most operands have no unary operator and no attributes. Keep that case in a
// small inlined wrapper so the large recursive/sret frame is only built when a
// prefix operator or attribute actually appears.
svp_parse_unary :: #force_inline proc(p: ^SVParser2) -> SVExpr {
	if !svp_at(p, .AttrStart) {
		if !svp_is_unop_token(svp_peek(p).kind) {
			return svp_parse_postfix(p, svp_parse_primary(p))
		}
	}
	return svp_parse_unary_slow(p)
}

svp_parse_unary_slow :: proc(p: ^SVParser2) -> SVExpr {
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
		return svp_set(p, SVIncDec{operand = operand, is_dec = is_dec, is_prefix = true})
	case:
		has_op = false
	}
	if !has_op { return svp_parse_postfix(p, svp_parse_primary(p)) }
	svp_bump(p)
	operand := svp_parse_unary(p)
	return svp_set(p, SVUnary{op = op, operand = operand})
}

svp_parse_postfix :: #force_inline proc(p: ^SVParser2, prefix: SVExpr) -> SVExpr {
	base := prefix
	if !svp_at(p, .LBracket) && !svp_at(p, .Dot) && !svp_at(p, .Tick) && !svp_at(p, .Inc) && !svp_at(p, .Dec) {
		if name, is_ident := base.(string); !is_ident || (!svp_at(p, .ColonColon) && !svp_at(p, .LParen)) {
			return base
		}
	}
	return svp_parse_postfix_slow(p, base)
}

svp_parse_postfix_slow :: proc(p: ^SVParser2, base_in: SVExpr) -> SVExpr {
	base := base_in
	parts: [dynamic]SVSelectPart

	// Scoped names and calls are handled here too, because statement-leading
	// identifiers arrive without going through primary's scoped-name branch.
	if name, is_ident := base.(string); is_ident {
		if svp_accept(p, .ColonColon) {
			member := svp_expect_ident(p)
			if svp_at(p, .LParen) {
				qual := strings.concatenate({name, "::", member}, p.allocator)
				base = svp_parse_call(p, qual, false)
			} else {
				base = svp_set(p, SVScopedName{scope = name, name = member})
			}
		} else if svp_at(p, .LParen) {
			base = svp_parse_call(p, name, false)
		}
	}

	for {
		if svp_accept(p, .LBracket) {
			part := SVSelectPart{kind = .BIT, first = svp_parse_expr(p, 0)}
			if svp_accept(p, .Colon) {
				part.kind = .PART
				part.second = svp_parse_expr(p, 0)
				part.has_second = true
			} else if svp_accept(p, .PlusColon) {
				part.kind = .INDEXED_PLUS
				part.second = svp_parse_expr(p, 0)
				part.has_second = true
			} else if svp_accept(p, .MinusColon) {
				part.kind = .INDEXED_MINUS
				part.second = svp_parse_expr(p, 0)
				part.has_second = true
			}
			_ = svp_expect(p, .RBracket)
			svp_add(p, &parts, part)
			continue
		}
		if svp_accept(p, .Dot) {
			member := svp_expect_ident(p)
			if svp_at(p, .LParen) {
				// Method-style call: flatten the dotted path into the call name.
				if ident, ok := base.(string); ok {
					b := strings.builder_make(p.allocator)
					strings.write_string(&b, ident)
					for part in parts {
						if part.member == "" { svp_error(p, "unsupported method call target") }
						strings.write_byte(&b, '.')
						strings.write_string(&b, part.member)
					}
					strings.write_byte(&b, '.')
					strings.write_string(&b, member)
					return svp_parse_call(p, strings.to_string(b), false)
				}
				svp_error(p, "method calls are not supported in the synthesizable subset")
			}
			svp_add(p, &parts, SVSelectPart{member = member})
			continue
		}
		break
	}

	if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
		svp_bump(p)
		return svp_parse_cast(p, "", base)
	}
	if svp_at(p, .Inc) || svp_at(p, .Dec) {
		is_dec := svp_at(p, .Dec)
		svp_bump(p)
		selected := base
		if len(parts) > 0 { selected = svp_set(p, SVSelect{base = base, parts = parts}) }
		return svp_set(p, SVIncDec{operand = selected, is_dec = is_dec})
	}
	if len(parts) == 0 { return base }
	return svp_set(p, SVSelect{base = base, parts = parts})
}

// Numbers and plain identifiers are the overwhelming majority of primaries.
// Handling them in a small inlined wrapper keeps the large switch below (casts,
// aggregates, calls, scoped names) out of the hot frame.
svp_parse_primary :: #force_inline proc(p: ^SVParser2) -> SVExpr {
	t := svp_peek(p)
	if t.kind == .Number { return svp_parse_number(p) }
	if (t.kind == .Ident || t.kind == .EscapedIdent) && t.kw == .None &&
	   !svp_at(p, .ColonColon, 1) && !svp_at(p, .LParen, 1) && !svp_at(p, .Tick, 1) {
		return svp_text(p, svp_advance(p))
	}
	return svp_parse_primary_slow(p, t)
}

svp_parse_primary_slow :: proc(p: ^SVParser2, t: SVToken) -> SVExpr {
	if t.kw != .None {
		_, is_var_type := svp_var_type(t.kw)
		if t.kw == .Signed || t.kw == .Unsigned || t.kw == .Void || (is_var_type && svp_at(p, .Tick, 1)) {
			target := svp_text(p, svp_advance(p))
			_ = svp_expect(p, .Tick)
			return svp_parse_cast(p, target, nil)
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
	case .LBrace:
		return svp_parse_concat(p)
	case .Tick:
		if svp_at(p, .LBrace, 1) {
			svp_bump(p)
			return svp_parse_aggregate(p, "", "")
		}
		return svp_parse_number(p)
	case .Number:
		return svp_parse_number(p)
	case .String:
		svp_bump(p)
		return SVStringLit(svp_text(p, t))
	case .SystemIdent:
		name := svp_text(p, svp_advance(p))
		if svp_at(p, .LParen) { return svp_parse_call(p, name, true) }
		return svp_set(p, SVCall{name = name, is_system = true})
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
				return svp_parse_cast(p, qual, nil)
			}
			if svp_at(p, .Tick) && svp_at(p, .LBrace, 1) {
				svp_bump(p)
				return svp_parse_aggregate(p, name, member)
			}
			return svp_set(p, SVScopedName{scope = name, name = member})
		}
		if svp_at(p, .LParen) { return svp_parse_call(p, name, false) }
		if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
			svp_bump(p)
			return svp_parse_cast(p, name, nil)
		}
		if svp_at(p, .Tick) && svp_at(p, .LBrace, 1) {
			svp_bump(p)
			return svp_parse_aggregate(p, "", name)
		}
		return name
	}
	svp_error(p, fmt.tprintf("unexpected token '%s' in expression", svp_text(p, t)))
}

svp_parse_cast :: proc(p: ^SVParser2, target: string, size: SVExpr) -> SVExpr {
	_ = svp_expect(p, .LParen)
	operand := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	c := svp_new(p, SVCast)
	c.operand = operand
	if target == "signed" || target == "unsigned" {
		c.kind = .SIGNING
		c.target = target
	} else if len(target) > 0 {
		c.kind = .TYPE
		c.target = target
	} else {
		c.kind = .SIZE
		c.size = svp_expr(p, size)
	}
	return c
}

svp_parse_call :: proc(p: ^SVParser2, name: string, is_system: bool) -> SVExpr {
	_ = svp_expect(p, .LParen)
	call := svp_new(p, SVCall)
	call.name = name
	call.is_system = is_system
	for !svp_at(p, .RParen) {
		arg: SVCallArg
		if svp_at(p, .Dot) {
			svp_bump(p)
			arg.name = svp_expect_ident(p)
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) { arg.value = svp_expr(p, svp_parse_expr(p, 0)) }
			_ = svp_expect(p, .RParen)
		} else if !svp_at(p, .Comma) {
			arg.value = svp_expr(p, svp_parse_expr(p, 0))
		}
		svp_add(p, &call.args, arg)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RParen)
	return call
}

svp_parse_concat :: proc(p: ^SVParser2) -> SVExpr {
	_ = svp_expect(p, .LBrace)
	if svp_at(p, .RBrace) {
		svp_bump(p)
		return svp_set(p, SVConcat{})
	}
	// Streaming concatenation: {<< [slice] { a, b }} / {>> ...}
	if (svp_at(p, .Shl) && svp_text(p, svp_peek(p)) == "<<") || (svp_at(p, .Shr) && svp_text(p, svp_peek(p)) == ">>") {
		stream := svp_new(p, SVStream)
		stream.dir = svp_at(p, .Shl) ? .LEFT : .RIGHT
		svp_bump(p)
		if !svp_at(p, .LBrace) { stream.slice = svp_expr(p, svp_parse_expr(p, 0)) }
		_ = svp_expect(p, .LBrace)
		for {
			svp_add(p, &stream.parts, svp_parse_expr(p, 0))
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .RBrace)
		_ = svp_expect(p, .RBrace)
		return stream
	}
	first := svp_parse_expr(p, 0)
	if svp_at(p, .LBrace) {
		// replication
		svp_bump(p)
		parts: [dynamic]SVExpr
		for {
			svp_add(p, &parts, svp_parse_expr(p, 0))
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .RBrace)
		_ = svp_expect(p, .RBrace)
		rep := svp_new(p, SVConcat)
		rep.count = svp_expr(p, first)
		rep.parts = parts
		return rep
	}
	node := svp_new(p, SVConcat)
	svp_add(p, &node.parts, first)
	for svp_accept(p, .Comma) {
		svp_add(p, &node.parts, svp_parse_expr(p, 0))
	}
	_ = svp_expect(p, .RBrace)
	return node
}

svp_aggregate_is_replicated :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if !(svp_is_ident(t) || t.kind == .Number || t.kind == .LParen) { return false }
	if svp_at(p, .LBrace, 1) { return true }
	if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && svp_is_ident(svp_peek(p, 2)) && svp_at(p, .LBrace, 3) { return true }
	return false
}

svp_parse_aggregate :: proc(p: ^SVParser2, type_scope, type_name: string) -> SVExpr {
	_ = svp_expect(p, .LBrace)
	agg := svp_new(p, SVAggregate)
	agg.type_scope = type_scope
	agg.type_name = type_name
	if svp_at(p, .RBrace) {
		svp_bump(p)
		return agg
	}
	if svp_aggregate_is_replicated(p) {
		agg.count = svp_expr(p, svp_parse_expr(p, 0))
		_ = svp_expect(p, .LBrace)
	}
	for !svp_at(p, .RBrace) {
		entry: SVAggregateEntry
		if svp_is_ident(svp_peek(p)) && svp_at(p, .Colon, 1) {
			entry.key = svp_expect_ident(p)
			_ = svp_expect(p, .Colon)
		} else if (svp_at(p, .String) || svp_at(p, .Number)) && svp_at(p, .Colon, 1) {
			entry.key = svp_text(p, svp_advance(p))
			_ = svp_expect(p, .Colon)
		} else if svp_kw_at(p, .Default) {
			svp_bump(p)
			_ = svp_expect(p, .Colon)
			entry.key = "default"
		}
		entry.value = svp_parse_expr(p, 0)
		svp_add(p, &agg.entries, entry)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RBrace)
	if agg.count != nil { _ = svp_expect(p, .RBrace) }
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
svp_fast_based_number :: #force_inline proc(text: string) -> (SVSmallNumber, bool) {
	n := len(text)
	if n < 4 { return {}, false }
	width: u32
	i := 0
	for i < n {
		c := text[i]
		if c == '_' { i += 1; continue }
		d := u32(c - '0')
		if d > 9 { break }
		width = width * 10 + d
		if width > 64 { return {}, false }
		i += 1
	}
	if i == 0 || i >= n || text[i] != '\'' { return {}, false }
	i += 1
	signed := false
	if i < n && (text[i] == 's' || text[i] == 'S') { signed = true; i += 1 }
	if i >= n { return {}, false }
	base: SVNumberBase
	radix: u64
	max_digits: int
	switch text[i] {
	case 'b', 'B': base = .BIN; radix = 2; max_digits = 64
	case 'o', 'O': base = .OCT; radix = 8; max_digits = 21
	case 'd', 'D': base = .DEC; radix = 10; max_digits = 19
	case 'h', 'H': base = .HEX; radix = 16; max_digits = 16
	case: return {}, false
	}
	i += 1
	value: u64
	digits := 0
	for i < n {
		c := text[i]
		if c == '_' { i += 1; continue }
		d: u64
		switch c {
		case '0' ..= '9': d = u64(c - '0')
		case 'a' ..= 'f': d = u64(c - 'a' + 10)
		case 'A' ..= 'F': d = u64(c - 'A' + 10)
		case: return {}, false
		}
		if d >= radix { return {}, false }
		value = value * radix + d
		digits += 1
		if digits > max_digits { return {}, false }
		i += 1
	}
	if digits == 0 { return {}, false }
	return SVSmallNumber{
		value = value,
		width = width,
		base = base,
		is_signed = signed || width == 0,
		time_unit = .NONE,
	}, true
}

// Most literals in RTL are based integers. Detect those before entering the
// generic literal function, whose frame holds the real/unit/unbased state.
svp_parse_number :: #force_inline proc(p: ^SVParser2) -> SVExpr {
	text := svp_text(p, svp_peek(p))
	if small, ok := svp_fast_based_number(text); ok {
		_ = svp_advance(p)
		return small
	}
	return svp_parse_number_slow(p)
}

svp_parse_number_slow :: proc(p: ^SVParser2) -> SVExpr {
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
		body := text[1:]
		if len(body) > 0 && (body[0] == 's' || body[0] == 'S') {
			signed = true
			body = body[1:]
		}
		if len(body) > 0 && svl_is_base_char(body[0]) {
			base = sv_number_base_of(body[0])
			raw = body[1:]
			if len(raw) > 0 && (raw[0] == ' ' || raw[0] == '\t' || raw[len(raw) - 1] == ' ' || raw[len(raw) - 1] == '\t') {
				raw = strings.trim_space(raw)
			}
		} else {
			is_unbased = true
			raw = body
		}
	} else if apostrophe > 0 {
		body := text[apostrophe + 1:]
		if len(body) > 0 && (body[0] == 's' || body[0] == 'S') {
			signed = true
			body = body[1:]
		}
		if len(body) > 0 && svl_is_base_char(body[0]) {
			base = sv_number_base_of(body[0])
			raw = body[1:]
			if len(raw) > 0 && (raw[0] == ' ' || raw[0] == '\t' || raw[len(raw) - 1] == ' ' || raw[len(raw) - 1] == '\t') {
				raw = strings.trim_space(raw)
			}
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
			case 'm': time_unit = .MS; raw = text[:n - 2]
			case 'u': time_unit = .US; raw = text[:n - 2]
			case 'n': time_unit = .NS; raw = text[:n - 2]
			case 'p': time_unit = .PS; raw = text[:n - 2]
			case 'f': time_unit = .FS; raw = text[:n - 2]
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
		return SVSmallNumber{
			value = value,
			width = width,
			base = base,
			is_signed = signed_value,
			time_unit = time_unit,
		}
	}
	return svp_set(p, SVNumber {
		raw = raw,
		width = width,
		base = base,
		is_signed = signed_value,
		is_unbased = is_unbased,
		is_real = is_real,
		real_value = real_value,
		value = value,
		has_x_z = has_x_z,
		time_unit = time_unit,
	})
}

// ---------------------------------------------------------------------------------------
// Entry point (temporary name; the public API switches to this once it covers the suite)
// ---------------------------------------------------------------------------------------

svp_parse_tokens :: proc(ast: ^SystemVerilogAST, toks: []SVToken, sources: []SVSource, filepath: string, allocator: mem.Allocator) {
	p := SVParser2{toks = toks, sources = sources, ast = ast, allocator = allocator, filepath = filepath}
	old := context.allocator
	context.allocator = allocator
	defer context.allocator = old
	svp_parse(&p)
}

// ---------------------------------------------------------------------------------------
// Imports, packages, interfaces, modules
// ---------------------------------------------------------------------------------------

svp_parse_import_list :: proc(p: ^SVParser2, imports: ^[dynamic]SVImport) {
	_ = svp_expect_kw(p, .Import)
	if svp_at(p, .String) {
		// import "DPI-C" ...; (verification only)
		svp_skip_until_semicolon(p)
		return
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
		append(imports, SVImport{package_name = pkg, name = name})
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
}

svp_parse_package :: proc(p: ^SVParser2) -> ^SVPackage {
	_ = svp_expect_kw(p, .Package)
	pkg := svp_new(p, SVPackage)
	pkg.name = svp_expect_ident(p)
	_ = svp_expect(p, .Semicolon)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endpackage) {
		svp_parse_package_item(p, pkg)
	}
	_ = svp_expect_kw(p, .Endpackage)
	svp_skip_end_label(p)
	if existing := p.ast.package_hash_map[pkg.name]; existing != nil {
		svp_error(p, fmt.tprintf("duplicate package '%s'", pkg.name))
	}
	p.ast.package_hash_map[pkg.name] = pkg
	append(&p.ast.packages, pkg)
	return pkg
}

svp_parse_package_item :: proc(p: ^SVParser2, pkg: ^SVPackage) {
	svp_skip_attributes(p)
	if svp_accept(p, .Semicolon) { return }
	t := svp_peek(p)
	#partial switch t.kw {
	case .Typedef: append(&pkg.items, svp_parse_typedef(p))
	case .Parameter, .Localparam:
		svp_bump(p)
		decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
		_ = svp_expect(p, .Semicolon)
		append(&pkg.items, decl)
	case .Function: append(&pkg.items, svp_parse_subroutine(p, false))
	case .Task: append(&pkg.items, svp_parse_subroutine(p, true))
	case .Import: svp_parse_import_list(p, &pkg.imports)
	case .Export, .Timeunit, .Timeprecision, .Nettype:
		svp_skip_until_semicolon(p)
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
	case:
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			append(&pkg.items, svp_parse_net_decl(p))
		} else if svp_is_ident(t) {
			// user-defined type declaration
			data := svp_parse_type(p, false)
			decl := svp_parse_net_decl_after_keyword(p, .NONE, data)
			append(&pkg.items, decl)
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

svp_parse_module :: proc(p: ^SVParser2) -> ^SVModule {
	svp_bump(p) // module/macromodule
	clear(&p.port_map)
	p.port_map_ready = false
	module := svp_new(p, SVModule)
	module.name = svp_expect_ident(p)
	module.source_path = p.filepath
	p.module = module
	for svp_kw_at(p, .Import) { svp_parse_import_list(p, &module.imports) }
	if svp_at(p, .Hash) { svp_parse_param_port_list(p, &module.params) }
	if svp_at(p, .LParen) { svp_parse_module_ports(p, module) }
	_ = svp_expect(p, .Semicolon)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endmodule) {
		svp_parse_module_item(p, &module.items)
	}
	_ = svp_expect_kw(p, .Endmodule)
	svp_skip_end_label(p)
	if existing := p.ast.module_hash_map[module.name]; existing != nil {
		svp_error(p, fmt.tprintf("duplicate module '%s'", module.name))
	}
	p.ast.module_hash_map[module.name] = module
	append(&p.ast.modules, module)
	p.module = nil
	return module
}

svp_parse_interface :: proc(p: ^SVParser2) -> ^SVInterface {
	_ = svp_expect_kw(p, .Interface)
	clear(&p.port_map)
	p.port_map_ready = false
	iface := svp_new(p, SVInterface)
	iface.name = svp_expect_ident(p)
	for svp_kw_at(p, .Import) { svp_parse_import_list(p, &iface.imports) }
	if svp_at(p, .Hash) { svp_parse_param_port_list(p, &iface.params) }
	if svp_at(p, .LParen) { svp_parse_interface_ports(p, iface) }
	_ = svp_expect(p, .Semicolon)
	old_iface := p.iface
	p.iface = iface
	for !svp_at_eof(p) && !svp_kw_at(p, .Endinterface) {
		if svp_kw_at(p, .Modport) {
			svp_add(p, &iface.modports, svp_parse_modport(p))
			continue
		}
		svp_parse_module_item(p, &iface.items)
	}
	_ = svp_expect_kw(p, .Endinterface)
	svp_skip_end_label(p)
	p.iface = old_iface
	if existing := p.ast.interface_hash_map[iface.name]; existing != nil {
		svp_error(p, fmt.tprintf("duplicate interface '%s'", iface.name))
	}
	p.ast.interface_hash_map[iface.name] = iface
	append(&p.ast.interfaces, iface)
	p.ast.iface_names[iface.name] = true
	return iface
}

svp_parse_modport :: proc(p: ^SVParser2) -> SVModport {
	_ = svp_expect_kw(p, .Modport)
	mp := SVModport{name = svp_expect_ident(p)}
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		dir := SVPortDir.NONE
		if d, ok := svp_port_dir(svp_peek(p).kw); ok {
			dir = d
			svp_bump(p)
		} else if svp_accept_kw(p, .Ref) {
			dir = .REF
		}
		svp_add(p, &mp.ports, SVModportPort{dir = dir, name = svp_expect_ident(p)})
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RParen)
	_ = svp_expect(p, .Semicolon)
	return mp
}

svp_parse_param_port_list :: proc(p: ^SVParser2, params: ^[dynamic]^SVParamDecl) {
	_ = svp_expect(p, .Hash)
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		append(params, svp_parse_param_group(p, true))
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

svp_parse_param_group :: proc(p: ^SVParser2, in_port_list: bool) -> ^SVParamDecl {
	is_local := false
	if svp_accept_kw(p, .Localparam) { is_local = true } else { _ = svp_accept_kw(p, .Parameter) }
	if svp_accept_kw(p, .Type) { return svp_parse_type_param_decl(p, is_local, in_port_list) }

	decl := svp_new(p, SVParamDecl)
	decl.is_local = is_local
	decl.data = svp_parse_type_for_param(p)
	svp_parse_param_assignments(p, decl, in_port_list, true)
	return decl
}

svp_parse_type_for_param :: proc(p: ^SVParser2) -> SVDataType {
	t := svp_peek(p)
	if t.kind == .LBracket {
		data: SVDataType
		for svp_at(p, .LBracket) { svp_add(p, &data.packed_dims, svp_parse_range(p)) }
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
	return {}
}

svp_parse_module_ports :: proc(p: ^SVParser2, module: ^SVModule) {
	_ = svp_expect(p, .LParen)
	svp_skip_attributes(p)
	if svp_accept(p, .DotStar) {
		_ = svp_expect(p, .RParen)
		module.wildcard_ports = true
		module.is_ansi = true
		return
	}
	if svp_at(p, .RParen) {
		svp_bump(p)
		module.is_ansi = true
		return
	}
	if svp_port_list_is_ansi(p) {
		module.is_ansi = true
		svp_parse_ansi_ports(p, &module.ports)
	} else {
		svp_parse_nonansi_ports(p, &module.ports)
	}
	_ = svp_expect(p, .RParen)
}

svp_parse_nonansi_ports :: proc(p: ^SVParser2, ports: ^[dynamic]^SVPort) {
	for {
		svp_skip_attributes(p)
		port := svp_new(p, SVPort)
		if svp_accept(p, .Dot) {
			port.name = svp_expect_ident(p)
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) { port.expr = svp_expr(p, svp_parse_expr(p, 0)) }
			_ = svp_expect(p, .RParen)
		} else if svp_at(p, .LBrace) {
			port.expr = svp_expr(p, svp_parse_concat(p))
		} else {
			port.name = svp_expect_ident(p)
			for svp_at(p, .LBracket) { svp_add(p, &port.unpacked_dims, svp_parse_range(p)) }
		}
		svp_add(p, ports, port, 4)
		if !svp_accept(p, .Comma) { break }
		if svp_at(p, .RParen) { break }
	}
}

svp_parse_interface_ports :: proc(p: ^SVParser2, iface: ^SVInterface) {
	_ = svp_expect(p, .LParen)
	svp_skip_attributes(p)
	if svp_at(p, .RParen) { svp_bump(p); return }
	if svp_port_list_is_ansi(p) {
		svp_parse_ansi_ports(p, &iface.ports)
	} else {
		svp_parse_nonansi_ports(p, &iface.ports)
	}
	_ = svp_expect(p, .RParen)
}

svp_parse_ansi_ports :: proc(p: ^SVParser2, ports: ^[dynamic]^SVPort) {
	prev_dir := SVPortDir.NONE
	prev_net := SVNetType.NONE
	prev_data: SVDataType
	for {
		svp_skip_attributes(p)
		if svp_at(p, .RParen) { break }
		port := svp_new(p, SVPort)
		given_dir := false
		given_net := false
		given_data := false

		if svp_at(p, .Dot) {
			// explicit port `.name(expr)`
			svp_bump(p)
			port.name = svp_expect_ident(p)
			if svp_accept(p, .LParen) {
				if !svp_at(p, .RParen) { port.expr = svp_expr(p, svp_parse_expr(p, 0)) }
				_ = svp_expect(p, .RParen)
			}
			append(ports, port)
			if !svp_accept(p, .Comma) { break }
			continue
		}

		if d, ok := svp_port_dir(svp_peek(p).kw); ok {
			port.dir = d
			svp_bump(p)
			given_dir = true
		} else {
			port.dir = prev_dir
		}

		if nt, ok := svp_net_type(svp_peek(p).kw); ok {
			port.net_type = nt
			svp_bump(p)
			given_net = true
		} else {
			port.net_type = prev_net
		}

		if svp_at(p, .Dot) {
			svp_bump(p)
			port.name = svp_expect_ident(p)
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) { port.expr = svp_expr(p, svp_parse_expr(p, 0)) }
			_ = svp_expect(p, .RParen)
			append(ports, port)
			if given_dir { prev_dir = port.dir }
			if given_net { prev_net = port.net_type }
			if !svp_accept(p, .Comma) { break }
			continue
		}

		// Interface port: iface.modport name, generic `interface name`, or a known
		// interface name followed by the port name.
		if svp_kw_at(p, .Interface) {
			svp_bump(p)
			port.iface_name = "interface"
			port.name = svp_expect_ident(p)
			given_data = true
		} else if t := svp_peek(p); svp_is_ident(t) && svp_at(p, .Dot, 1) {
			port.iface_name = svp_text(p, t)
			svp_bump(p)
			_ = svp_expect(p, .Dot)
			port.modport = svp_expect_ident(p)
			port.name = svp_expect_ident(p)
			given_data = true
		} else if t := svp_peek(p); svp_is_ident(t) && svp_text(p, t) in p.ast.iface_names && svp_is_ident(svp_peek(p, 1)) {
			port.iface_name = svp_text(p, t)
			svp_bump(p)
			port.name = svp_expect_ident(p)
			given_data = true
		} else if svp_starts_port_type(p) {
			port.data = svp_parse_type(p, true)
			given_data = true
			port.name = svp_expect_ident(p)
		} else {
			port.data = prev_data
			if svp_is_decl_kw(svp_peek(p).kw) || svp_at(p, .LBracket) {
				port.data = svp_parse_type(p, true)
				given_data = true
			}
			port.name = svp_expect_ident(p)
		}

		for svp_at(p, .LBracket) { svp_add(p, &port.unpacked_dims, svp_parse_range(p)) }
		if svp_accept(p, .Assign) { port.default_value = svp_expr(p, svp_parse_expr(p, 0)) }
		append(ports, port)
		if given_dir { prev_dir = port.dir }
		if given_net { prev_net = port.net_type }
		if given_data { prev_data = port.data }
		if !svp_accept(p, .Comma) { break }
	}
}

svp_starts_port_type :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p)
	if t.kind == .LBracket { return true }
	if _, ok := svp_var_type(t.kw); ok { return true }
	if _, ok := svp_net_type(t.kw); ok { return true }
	if t.kw == .Var || t.kw == .Const || t.kw == .Signed || t.kw == .Unsigned ||
	   t.kw == .Enum || t.kw == .Struct || t.kw == .Union { return true }
	if svp_is_ident(t) {
		if svp_text(p, t) in p.ast.type_names { return true }
		n := svp_peek(p, 1)
		if n.kind == .ColonColon { return true }
		if svp_is_ident(n) { return true }
		if n.kind == .LBracket && svp_ident_dims_then_ident(p) { return true }
	}
	return false
}

svp_parse_port_declaration :: proc(p: ^SVParser2, dir: SVPortDir) -> ^SVPortDecl {
	svp_bump(p) // direction keyword
	net_type := SVNetType.NONE
	if nt, ok := svp_net_type(svp_peek(p).kw); ok {
		net_type = nt
		svp_bump(p)
	}
	data := svp_parse_net_data_type(p)
	decl := svp_set(p, SVNetDecl{
		net_type = net_type,
		data = data,
		declarators = svp_parse_declarators(p),
	})
	_ = svp_expect(p, .Semicolon)
	target_ports: ^[dynamic]^SVPort
	if p.module != nil { target_ports = &p.module.ports } else if p.iface != nil { target_ports = &p.iface.ports }
	if target_ports != nil && !p.port_map_ready {
		for port in target_ports^ { p.port_map[port.name] = port }
		p.port_map_ready = true
	}
	if target_ports != nil {
		given_data := len(data.type_name) > 0 || data.var_type != .IMPLICIT || data.spec != nil || len(data.packed_dims) > 0
		for d in decl.declarators {
			port := p.port_map[d.name]
			if port == nil {
				port_data: SVDataType
				if given_data { port_data = data }
				port = svp_set(p, SVPort{
					name = d.name,
					dir = dir,
					net_type = net_type,
					data = port_data,
					unpacked_dims = d.unpacked_dims,
					default_value = d.init,
				})
				p.port_map[d.name] = port
				svp_add(p, target_ports, port, 4)
			} else {
				port.dir = dir
				port.net_type = net_type
				if given_data { port.data = data }
				port.unpacked_dims = d.unpacked_dims
				port.default_value = d.init
			}
		}
	}
	return svp_set(p, SVPortDecl{dir = dir, decl = decl})
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

svp_parse_module_item :: proc(p: ^SVParser2, items: ^[dynamic]SVItem) {
	svp_skip_attributes(p)
	if svp_accept(p, .Semicolon) { return }
	t := svp_peek(p)
	if svp_is_ident(t) && svp_at(p, .Colon, 1) {
		n := svp_peek(p, 2)
		if n.kw == .Assert || n.kw == .Assume || n.kw == .Cover {
			svp_bump(p)
			_ = svp_expect(p, .Colon)
			append(items, svp_parse_assertion(p, n.kw == .Assert ? .ASSERT : (n.kw == .Assume ? .ASSUME : .COVER)))
			return
		}
		if n.kw == .Begin {
			label := svp_expect_ident(p)
			_ = svp_expect(p, .Colon)
			block := svp_parse_gen_block_after_begin(p, label)
			region := svp_new(p, SVGenRegion)
			region.label = block.label
			region.items = block.items
			append(items, region)
			return
		}
	}
	#partial switch t.kw {
	case .Input: append(items, svp_parse_port_declaration(p, .INPUT))
	case .Output: append(items, svp_parse_port_declaration(p, .OUTPUT))
	case .Inout: append(items, svp_parse_port_declaration(p, .INOUT))
	case .Ref: append(items, svp_parse_port_declaration(p, .REF))
	case .Parameter, .Localparam:
		svp_bump(p)
		decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
		_ = svp_expect(p, .Semicolon)
		append(items, decl)
	case .Typedef: append(items, svp_parse_typedef(p))
	case .Import:
		if p.module != nil { svp_parse_import_list(p, &p.module.imports) } else if p.iface != nil { svp_parse_import_list(p, &p.iface.imports) } else { svp_parse_import_list(p, &p.ast.imports) }
	case .Assign: append(items, svp_parse_cont_assign(p))
	case .Alias: append(items, svp_parse_alias(p))
	case .Defparam: append(items, svp_parse_defparam(p))
	case .Initial: append(items, svp_parse_proc(p, .INITIAL))
	case .Final:
		svp_bump(p)
		proc_node := svp_new(p, SVProc)
		proc_node.kind = .FINAL
		proc_node.body = svp_parse_statement(p)
		append(items, proc_node)
	case .Always: append(items, svp_parse_proc(p, .ALWAYS))
	case .AlwaysComb: append(items, svp_parse_proc(p, .ALWAYS_COMB))
	case .AlwaysFf: append(items, svp_parse_proc(p, .ALWAYS_FF))
	case .AlwaysLatch: append(items, svp_parse_proc(p, .ALWAYS_LATCH))
	case .Function: append(items, svp_parse_subroutine(p, false))
	case .Task: append(items, svp_parse_subroutine(p, true))
	case .Generate: append(items, svp_parse_gen_region(p))
	case .For: append(items, svp_parse_gen_loop(p))
	case .If: append(items, svp_parse_gen_if(p))
	case .Case, .Casez, .Casex: append(items, svp_parse_gen_case(p))
	case .Genvar:
		svp_bump(p)
		gv := svp_new(p, SVGenvarDecl)
		for {
			svp_add(p, &gv.names, svp_expect_ident(p))
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .Semicolon)
		append(items, gv)
	case .Assert: append(items, svp_parse_assertion(p, .ASSERT))
	case .Assume: append(items, svp_parse_assertion(p, .ASSUME))
	case .Cover: append(items, svp_parse_assertion(p, .COVER))
	case .Restrict:
		svp_bump(p)
		if svp_kw_at(p, .Property) {
			svp_bump(p)
			if svp_at(p, .LParen) {
				depth := 0
				for !svp_at_eof(p) {
					if svp_at(p, .LParen) { depth += 1 }
					if svp_at(p, .RParen) { depth -= 1; if depth == 0 { svp_bump(p); break } }
					svp_bump(p)
				}
			}
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
	case .Specify:
		svp_skip_until_kw(p, .Endspecify)
	case .Default:
		svp_bump(p)
		if svp_kw_at(p, .Clocking) {
			svp_skip_until_kw(p, .Endclocking)
			svp_skip_end_label(p)
		} else {
			svp_skip_until_semicolon(p)
		}
	case .Timeunit, .Timeprecision:
		svp_skip_until_semicolon(p)
	case .Begin:
		block := svp_parse_gen_block(p)
		region := svp_new(p, SVGenRegion)
		region.label = block.label
		region.items = block.items
		append(items, region)
	case .Module, .Macromodule:
		_ = svp_parse_module(p)
	case:
		if svp_is_gate_kw(t.kw) {
			name := svp_text(p, t)
			svp_bump(p)
			svp_parse_instantiation(p, name, true, items)
			return
		}
		if t.kind == .SystemIdent {
			name := svp_text(p, svp_advance(p))
			call: SVCall
			if svp_at(p, .LParen) {
				e := svp_parse_call(p, name, true)
				call = e.(^SVCall)^
			} else {
				call.name = name
				call.is_system = true
			}
			_ = svp_expect(p, .Semicolon)
			append(items, svp_set(p, call))
			return
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			append(items, svp_parse_net_decl(p))
			return
		}
		if svp_is_ident(t) {
			name := svp_expect_ident(p)
			if svp_is_instantiation_ahead(p) {
				svp_parse_instantiation(p, name, svp_is_gate_kw(t.kw), items)
				return
			}
			// `type_t name;` / `pkg::type_t name;`
			if svp_is_ident(svp_peek(p)) || svp_at(p, .LBracket) {
				data := svp_type_from_name(p, "", name)
				decl := svp_parse_net_decl_after_keyword(p, .NONE, data)
				append(items, decl)
				return
			}
			if svp_at(p, .ColonColon) {
				scope := name
				svp_bump(p)
				member := svp_expect_ident(p)
				if svp_is_ident(svp_peek(p)) || svp_at(p, .LBracket) {
					data := svp_type_from_name(p, scope, member)
					decl := svp_parse_net_decl_after_keyword(p, .NONE, data)
					append(items, decl)
					return
				}
				// scoped task call
				if svp_at(p, .Semicolon) {
					svp_bump(p)
					append(items, svp_set(p, SVCall{name = strings.concatenate({scope, "::", member}, p.allocator)}))
					return
				}
				svp_error(p, "unsupported scoped module item")
			}
			is_gate := svp_is_gate_kw(t.kw)
			svp_parse_instantiation(p, name, is_gate, items)
			return
		}
		svp_error(p, fmt.tprintf("unexpected token '%s' in module body", svp_text(p, t)))
	}
}

svp_skip_strengths :: proc(p: ^SVParser2) {
	if svp_at(p, .LParen) && svp_is_strength_token(p) {
		depth := 0
		for !svp_at_eof(p) {
			if svp_at(p, .LParen) { depth += 1 }
			if svp_at(p, .RParen) { depth -= 1; if depth == 0 { svp_bump(p); break } }
			svp_bump(p)
		}
	}
}

svp_parse_cont_assign :: proc(p: ^SVParser2) -> ^SVContAssign {
	_ = svp_expect_kw(p, .Assign)
	if svp_accept(p, .Hash) {
		if svp_at(p, .LParen) {
			depth := 0
			for !svp_at_eof(p) {
				if svp_at(p, .LParen) { depth += 1 }
				if svp_at(p, .RParen) { depth -= 1; if depth == 0 { svp_bump(p); break } }
				svp_bump(p)
			}
		} else { svp_bump(p) }
	}
	svp_skip_strengths(p)
	node := svp_new(p, SVContAssign)
	for {
		pair := SVAssignPair{lhs = svp_parse_expr(p, 0)}
		_ = svp_expect(p, .Assign)
		pair.rhs = svp_parse_expr(p, 0)
		svp_add(p, &node.pairs, pair)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_alias :: proc(p: ^SVParser2) -> ^SVAlias {
	_ = svp_expect_kw(p, .Alias)
	node := svp_new(p, SVAlias)
	for {
		svp_add(p, &node.names, svp_parse_expr(p, 0))
		if !svp_accept(p, .Assign) { break }
	}
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_defparam :: proc(p: ^SVParser2) -> ^SVDefparam {
	_ = svp_expect_kw(p, .Defparam)
	node := svp_new(p, SVDefparam)
	for {
		pair := SVAssignPair{lhs = svp_parse_expr(p, 0)}
		_ = svp_expect(p, .Assign)
		pair.rhs = svp_parse_expr(p, 0)
		svp_add(p, &node.pairs, pair)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_type_from_name :: proc(p: ^SVParser2, scope, name: string) -> SVDataType {
	data := SVDataType{type_scope = scope, type_name = name}
	for svp_at(p, .LBracket) { svp_add(p, &data.packed_dims, svp_parse_range(p)) }
	return data
}

svp_parse_param_overrides :: proc(p: ^SVParser2, inst: ^SVInstance) {
	if !svp_accept(p, .Hash) { return }
	if svp_at(p, .Number) {
		// delay control, not a parameter list
		svp_bump(p)
		return
	}
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		o: SVParamOverride
		if svp_accept(p, .Dot) {
			o.name = svp_expect_ident(p)
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) {
				if svp_starts_type_token(p) {
					v := svp_new(p, SVDataType)
					v^ = svp_parse_type(p, true)
					o.type_value = v
				} else {
					o.value = svp_expr(p, svp_parse_expr(p, 0))
				}
			}
			_ = svp_expect(p, .RParen)
		} else if svp_starts_type_token(p) {
			v := svp_new(p, SVDataType)
			v^ = svp_parse_type(p, true)
			o.type_value = v
		} else {
			o.value = svp_expr(p, svp_parse_expr(p, 0))
		}
		svp_add(p, &inst.param_overrides, o)
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

svp_parse_instantiation :: proc(p: ^SVParser2, cell: string, is_gate: bool, items: ^[dynamic]SVItem) {
	// Optional gate strengths: (strong0, strong1)
	if is_gate && svp_at(p, .LParen) && svp_is_strength_token(p) {
		for !svp_at(p, .RParen) && !svp_at_eof(p) { svp_bump(p) }
		_ = svp_expect(p, .RParen)
	}
	for {
		inst := svp_new(p, SVInstance)
		inst.cell_name = cell
		inst.is_gate = is_gate
		if svp_at(p, .Hash) { svp_parse_param_overrides(p, inst) }
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
		if svp_is_ident(svp_peek(p)) || svp_at(p, .EscapedIdent) {
			inst.name = svp_expect_ident(p)
		} else if !is_gate {
			svp_error(p, "expected an instance name")
		}
		for svp_at(p, .LBracket) { svp_add(p, &inst.unpacked_dims, svp_parse_range(p)) }
		if svp_at(p, .LParen) { svp_parse_port_connections(p, inst) }
		append(items, inst)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
}

svp_is_strength_token :: proc(p: ^SVParser2) -> bool {
	t := svp_peek(p, 1)
	#partial switch t.kw {
	case .Strong0, .Strong1, .Weak0, .Weak1, .Highz0, .Highz1, .Pull0, .Pull1, .Supply0, .Supply1:
		return true
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

svp_parse_port_connections :: proc(p: ^SVParser2, inst: ^SVInstance) {
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		svp_skip_attributes(p)
		conn: SVPortConn
		if svp_accept(p, .DotStar) {
			inst.wildcard_ports = true
			if !svp_accept(p, .Comma) { break }
			continue
		}
		if svp_accept(p, .Dot) {
			if svp_accept(p, .Star) {
				inst.wildcard_ports = true
				if !svp_accept(p, .Comma) { break }
				continue
			}
			conn.name = svp_expect_ident(p)
			if svp_accept(p, .LParen) {
				if !svp_at(p, .RParen) { conn.value = svp_expr(p, svp_parse_expr(p, 0)) }
				_ = svp_expect(p, .RParen)
			}
		} else if !svp_at(p, .Comma) {
			conn.value = svp_expr(p, svp_parse_expr(p, 0))
		}
		svp_add(p, &inst.port_conns, conn, 2)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RParen)
}

svp_parse_gen_region :: proc(p: ^SVParser2) -> ^SVGenRegion {
	_ = svp_expect_kw(p, .Generate)
	region := svp_new(p, SVGenRegion)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endgenerate) {
		svp_parse_module_item(p, &region.items)
	}
	_ = svp_expect_kw(p, .Endgenerate)
	return region
}

svp_parse_gen_block :: proc(p: ^SVParser2) -> ^SVGenBlock {
	block := svp_new(p, SVGenBlock)
	if svp_accept_kw(p, .Begin) {
		if svp_accept(p, .Colon) { block.label = svp_expect_ident(p) }
		for !svp_at_eof(p) && !svp_kw_at(p, .End) {
			svp_parse_module_item(p, &block.items)
		}
		_ = svp_expect_kw(p, .End)
		svp_skip_end_label(p)
	} else {
		svp_parse_module_item(p, &block.items)
	}
	return block
}

svp_parse_gen_loop :: proc(p: ^SVParser2) -> ^SVGenLoop {
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
	return svp_set(p, SVGenLoop{var = var, init = init, cond = cond, step = step, body = body})
}

svp_parse_gen_if :: proc(p: ^SVParser2) -> ^SVGenIf {
	_ = svp_expect_kw(p, .If)
	_ = svp_expect(p, .LParen)
	cond := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	then_blk := svp_parse_gen_block(p)
	else_blk: ^SVGenBlock
	if svp_accept_kw(p, .Else) { else_blk = svp_parse_gen_block(p) }
	return svp_set(p, SVGenIf{cond = cond, then_blk = then_blk, else_blk = else_blk})
}

svp_parse_gen_case :: proc(p: ^SVParser2) -> ^SVGenCase {
	kind := SVCaseKind.CASE
	#partial switch svp_peek(p).kw {
	case .Casez: kind = .CASEZ
	case .Casex: kind = .CASEX
	}
	svp_bump(p)
	node := svp_new(p, SVGenCase)
	node.kind = kind
	_ = svp_expect(p, .LParen)
	node.subject = svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	for !svp_at_eof(p) && !svp_kw_at(p, .Endcase) {
		item := SVGenCaseItem{}
		if svp_accept_kw(p, .Default) {
			item.is_default = true
			_ = svp_accept(p, .Colon)
		} else {
			for {
				svp_add(p, &item.exprs, svp_parse_expr(p, 0))
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .Colon)
		}
		item.body = svp_parse_gen_block(p)
		svp_add(p, &node.items, item)
	}
	_ = svp_expect_kw(p, .Endcase)
	return node
}

// ---------------------------------------------------------------------------------------
// Procedures, statements, subroutines
// ---------------------------------------------------------------------------------------

svp_parse_proc :: proc(p: ^SVParser2, kind: SVProcKind) -> ^SVProc {
	svp_bump(p)
	if svp_at(p, .At) {
		ctl := svp_parse_timing_ctl(p)
		return svp_set(p, SVProc{
			kind = kind,
			events = ctl.events,
			any_event = ctl.any_event,
			body = svp_parse_statement(p),
		})
	}
	if svp_at(p, .Hash) {
		ctl := svp_parse_timing_ctl(p)
		return svp_set(p, SVProc{
			kind = kind,
			body = svp_set(p, SVTimingStmt{timing = ctl, body = svp_parse_statement_or_null(p)}),
		})
	}
	return svp_set(p, SVProc{kind = kind, body = svp_parse_statement(p)})
}

svp_parse_timing_ctl :: proc(p: ^SVParser2) -> SVTimingCtl {
	ctl: SVTimingCtl
	if svp_accept(p, .Hash) {
		ctl.is_delay = true
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
				ctl.delay = svp_parse_expr(p, 0)
				p.i = old_i
			}
		} else if !svp_at(p, .Semicolon) {
			ctl.delay = svp_parse_primary(p)
		}
		return ctl
	}
	_ = svp_expect(p, .At)
	if svp_accept(p, .Star) {
		ctl.any_event = true
		return ctl
	}
	if svp_accept(p, .AttrStart) {
		_ = svp_expect(p, .RParen)
		ctl.any_event = true
		return ctl
	}
	if svp_accept(p, .LParen) {
		if svp_accept(p, .Star) {
			_ = svp_expect(p, .RParen)
			ctl.any_event = true
			return ctl
		}
		for {
			ev: SVEvent
			if svp_accept_kw(p, .Posedge) { ev.edge = .POSEDGE } else if svp_accept_kw(p, .Negedge) { ev.edge = .NEGEDGE } else if svp_accept_kw(p, .Edge) { ev.edge = .EDGE }
			ev.expr = svp_parse_expr(p, 0)
			if svp_accept_kw(p, .Iff) { ev.iff = svp_expr(p, svp_parse_expr(p, 0)) }
			svp_add(p, &ctl.events, ev)
			if svp_accept(p, .Comma) { continue }
			if svp_accept_kw(p, .Or) { continue }
			break
		}
		_ = svp_expect(p, .RParen)
		return ctl
	}
	ev: SVEvent
	if svp_accept_kw(p, .Posedge) { ev.edge = .POSEDGE } else if svp_accept_kw(p, .Negedge) { ev.edge = .NEGEDGE }
	ev.expr = svp_parse_expr(p, 0)
	svp_add(p, &ctl.events, ev)
	return ctl
}

svp_parse_statement_or_null :: proc(p: ^SVParser2) -> ^SVStmt {
	svp_skip_attributes(p)
	if svp_accept(p, .Semicolon) { return nil }
	s := svp_parse_statement(p)
	return svp_set(p, s)
}

svp_parse_statement :: proc(p: ^SVParser2) -> SVStmt {
	svp_skip_attributes(p)
	if svp_at(p, .Semicolon) {
		svp_bump(p)
		return svp_set(p, SVBlock{})
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
		return svp_set(p, SVJump{kind = .BREAK})
	case .Continue:
		svp_bump(p)
		_ = svp_expect(p, .Semicolon)
		return svp_set(p, SVJump{kind = .CONTINUE})
	case .Return:
		svp_bump(p)
		value: ^SVExpr
		if !svp_at(p, .Semicolon) { value = svp_expr(p, svp_parse_expr(p, 0)) }
		_ = svp_expect(p, .Semicolon)
		return svp_set(p, SVJump{kind = .RETURN, value = value})
	case .Void:
		svp_bump(p)
		_ = svp_expect(p, .Tick)
		_ = svp_expect(p, .LParen)
		e := svp_parse_expr(p, 0)
		_ = svp_expect(p, .RParen)
		_ = svp_expect(p, .Semicolon)
		if c, ok := e.(^SVCall); ok { return c }
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
		if body == nil { return svp_set(p, SVTimingStmt{timing = ctl}) }
		return svp_set(p, SVTimingStmt{timing = ctl, body = body})
	}
	if svp_at(p, .SystemIdent) {
		name := svp_text(p, svp_advance(p))
		call: SVCall
		if svp_at(p, .LParen) {
			e := svp_parse_call(p, name, true)
			call = e.(^SVCall)^
		} else {
			call.name = name
			call.is_system = true
		}
		_ = svp_expect(p, .Semicolon)
		return svp_set(p, call)
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

svp_parse_assignment_or_call :: proc(p: ^SVParser2, name: string, escaped: bool) -> SVStmt {
	if escaped {
		return svp_parse_assignment_or_call_expr(p, name)
	}
	// scoped call / scoped name in statement position
	if svp_at(p, .ColonColon) {
		svp_bump(p)
		member := svp_expect_ident(p)
		qual := strings.concatenate({name, "::", member}, p.allocator)
		if svp_at(p, .LParen) {
			e := svp_parse_call(p, qual, false)
			_ = svp_expect(p, .Semicolon)
			return e.(^SVCall)
		}
		_ = svp_expect(p, .Semicolon)
		return svp_set(p, SVCall{name = qual})
	}
	if svp_at(p, .LParen) {
		e := svp_parse_call(p, name, false)
		_ = svp_expect(p, .Semicolon)
		return e.(^SVCall)
	}
	if svp_at(p, .Semicolon) {
		svp_bump(p)
		return svp_set(p, SVCall{name = name})
	}
	return svp_parse_assignment_or_call_expr(p, name)
}

svp_parse_assignment_or_call_expr :: proc(p: ^SVParser2, prefix: SVExpr) -> SVStmt {
	base := svp_parse_postfix(p, prefix)
	if svp_accept(p, .Semicolon) {
		if c, ok := base.(^SVCall); ok { return c }
		if _, ok := base.(^SVIncDec); ok { return base.(^SVIncDec) }
		if ident, ok := base.(string); ok { return svp_set(p, SVCall{name = ident}) }
		if scoped, ok := base.(^SVScopedName); ok { return svp_set(p, SVCall{name = strings.concatenate({scoped.scope, "::", scoped.name}, p.allocator)}) }
		svp_error(p, "only subroutine calls and ++/-- can stand alone as expressions")
	}
	op := SVAssignOp.EQ
	nonblocking := false
	#partial switch svp_peek(p).kind {
	case .Assign: op = .EQ
	case .Le:
		// `<=` is nonblocking only when not followed by a delay/event control of a comparison
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
	timing: ^SVTimingCtl
	if svp_at(p, .Hash) || svp_at(p, .At) {
		ctl := svp_parse_timing_ctl(p)
		timing = svp_set(p, ctl)
	}
	rhs := svp_parse_expr(p, 0)
	_ = svp_expect(p, .Semicolon)
	return svp_set(p, SVAssignStmt{
		lhs = base,
		op = op,
		rhs = rhs,
		nonblocking = nonblocking,
		timing = timing,
	})
}

svp_parse_block :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Begin)
	block := svp_new(p, SVBlock)
	if svp_accept(p, .Colon) { block.label = svp_expect_ident(p) }
	for !svp_at_eof(p) {
		svp_skip_attributes(p)
		if svp_kw_at(p, .End) {
			svp_bump(p)
			svp_skip_end_label(p)
			return block
		}
		if svp_accept(p, .Semicolon) { continue }
		t := svp_peek(p)
		if t.kw == .Import {
			svp_parse_import_list(p, &block.imports)
			continue
		}
		if t.kw == .Typedef {
			svp_add(p, &block.decls, svp_parse_typedef(p))
			continue
		}
		if t.kw == .Parameter || t.kw == .Localparam {
			svp_bump(p)
			decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
			_ = svp_expect(p, .Semicolon)
			svp_add(p, &block.decls, decl)
			continue
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			svp_add(p, &block.decls, svp_parse_net_decl(p))
			continue
		}
		if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && (svp_is_ident(svp_peek(p, 3)) || svp_at(p, .LBracket, 3)) {
			scope := svp_expect_ident(p)
			_ = svp_expect(p, .ColonColon)
			member := svp_expect_ident(p)
			data := svp_type_from_name(p, scope, member)
			svp_add(p, &block.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		if svp_is_ident(t) && (svp_is_ident(svp_peek(p, 1)) || (svp_at(p, .LBracket, 1) && svp_ident_dims_then_ident(p))) {
			name := svp_expect_ident(p)
			data := svp_type_from_name(p, "", name)
			svp_add(p, &block.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		append(&block.stmts, svp_parse_statement(p))
	}
	svp_error(p, "unterminated begin block")
}

svp_parse_if :: proc(p: ^SVParser2, q: SVQualifier) -> SVStmt {
	_ = svp_expect_kw(p, .If)
	_ = svp_expect(p, .LParen)
	cond := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	then_body := svp_parse_statement_or_null(p)
	else_body: ^SVStmt
	if svp_accept_kw(p, .Else) { else_body = svp_parse_statement_or_null(p) }
	return svp_set(p, SVIf{qualifier = q, cond = cond, then_body = then_body, else_body = else_body})
}

svp_parse_case :: proc(p: ^SVParser2, q: SVQualifier) -> SVStmt {
	kind := SVCaseKind.CASE
	#partial switch svp_peek(p).kw {
	case .Casez: kind = .CASEZ
	case .Casex: kind = .CASEX
	}
	svp_bump(p)
	node := svp_new(p, SVCase)
	node.kind = kind
	node.qualifier = q
	_ = svp_expect(p, .LParen)
	node.subject = svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	if svp_accept_kw(p, .Inside) { node.is_inside = true }
	for !svp_at_eof(p) && !svp_kw_at(p, .Endcase) {
		item := SVCaseItem{}
		if svp_accept_kw(p, .Default) {
			item.is_default = true
			_ = svp_accept(p, .Colon)
		} else {
			for {
				if node.is_inside && svp_at(p, .LBracket) {
					r: SVInsideRange
					svp_bump(p)
					r.lo = svp_parse_expr(p, 0)
					if svp_accept(p, .Colon) { r.hi = svp_parse_expr(p, 0); r.has_hi = true }
					_ = svp_expect(p, .RBracket)
					svp_add(p, &item.ranges, r)
				} else {
					svp_add(p, &item.exprs, svp_parse_expr(p, 0))
				}
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .Colon)
		}
		item.body = svp_parse_statement_or_null(p)
		svp_add(p, &node.items, item)
	}
	_ = svp_expect_kw(p, .Endcase)
	return node
}

svp_parse_for :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .For)
	node := svp_new(p, SVFor)
	_ = svp_expect(p, .LParen)
	if !svp_at(p, .Semicolon) {
		t := svp_peek(p)
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket || (svp_is_ident(t) && svp_is_ident(svp_peek(p, 1))) {
			decl := svp_new(p, SVNetDecl)
			decl.data = svp_parse_type(p, true)
			for {
				d := SVDeclarator{name = svp_expect_ident(p)}
				for svp_at(p, .LBracket) { svp_add(p, &d.unpacked_dims, svp_parse_range(p)) }
				if svp_accept(p, .Assign) { d.init = svp_expr(p, svp_parse_expr(p, 0)) }
				svp_add(p, &decl.declarators, d)
				if !svp_accept(p, .Comma) { break }
			}
			svp_add(p, &node.var_decls, decl)
		} else {
			for {
				svp_add(p, &node.init_assigns, svp_parse_for_assign(p))
				if !svp_accept(p, .Comma) { break }
			}
		}
	}
	_ = svp_expect(p, .Semicolon)
	if !svp_at(p, .Semicolon) { node.cond = svp_expr(p, svp_parse_expr(p, 0)) }
	_ = svp_expect(p, .Semicolon)
	if !svp_at(p, .RParen) {
		for {
			svp_add(p, &node.steps, svp_parse_stmt_no_semi(p))
			if !svp_accept(p, .Comma) { break }
		}
	}
	_ = svp_expect(p, .RParen)
	node.body = svp_parse_statement_or_null(p)
	return node
}

svp_parse_for_assign :: proc(p: ^SVParser2) -> ^SVAssignStmt {
	base := svp_parse_postfix(p, svp_parse_primary(p))
	rhs: SVExpr
	if svp_accept(p, .Assign) {
		rhs = svp_parse_expr(p, 0)
	}
	return svp_set(p, SVAssignStmt{lhs = base, rhs = rhs})
}

svp_parse_stmt_no_semi :: proc(p: ^SVParser2) -> SVStmt {
	t := svp_peek(p)
	if t.kind == .Inc || t.kind == .Dec {
		e := svp_parse_unary(p)
		if inc, ok := e.(^SVIncDec); ok { return inc }
		return svp_parse_assignment_no_semi_expr(p, e)
	}
	if svp_is_ident(t) || t.kind == .EscapedIdent {
		name := svp_text(p, svp_advance(p))
		if svp_at(p, .LParen) { return svp_parse_call(p, name, false).(^SVCall) }
		if svp_at(p, .Inc) || svp_at(p, .Dec) {
			is_dec := svp_at(p, .Dec)
			svp_bump(p)
			return svp_set(p, SVIncDec{operand = name, is_dec = is_dec})
		}
		return svp_parse_assignment_no_semi(p, name)
	}
	return svp_parse_assignment_no_semi_expr(p, svp_parse_primary(p))
}

svp_parse_assignment_no_semi :: proc(p: ^SVParser2, prefix: SVExpr) -> SVStmt {
	return svp_parse_assignment_no_semi_expr(p, svp_parse_postfix(p, prefix))
}

svp_parse_assignment_no_semi_expr :: proc(p: ^SVParser2, base: SVExpr) -> SVStmt {
	if svp_at(p, .Inc) || svp_at(p, .Dec) {
		is_dec := svp_at(p, .Dec)
		svp_bump(p)
		return svp_set(p, SVIncDec{operand = base, is_dec = is_dec})
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
	return svp_set(p, SVAssignStmt{lhs = base, op = op, rhs = svp_parse_expr(p, 0), nonblocking = nonblocking})
}

svp_parse_while :: proc(p: ^SVParser2, do_while: bool) -> SVStmt {
	body: ^SVStmt
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
	return svp_set(p, SVWhile{do_while = do_while, cond = cond, body = body})
}

svp_parse_repeat :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Repeat)
	_ = svp_expect(p, .LParen)
	count := svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	return svp_set(p, SVRepeat{count = count, body = svp_parse_statement_or_null(p)})
}

svp_parse_forever :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Forever)
	return svp_set(p, SVForever{body = svp_parse_statement_or_null(p)})
}

svp_parse_foreach :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Foreach)
	node := svp_new(p, SVForeach)
	_ = svp_expect(p, .LParen)
	node.array = svp_parse_primary(p)
	for svp_accept(p, .Dot) {
		member := svp_expect_ident(p)
		parts: [dynamic]SVSelectPart
		svp_add(p, &parts, SVSelectPart{member = member})
		node.array = svp_set(p, SVSelect{base = node.array, parts = parts})
	}
	_ = svp_expect(p, .LBracket)
	for !svp_at(p, .RBracket) {
		if svp_at(p, .Comma) { svp_add(p, &node.loop_vars, ""); svp_bump(p); continue }
		svp_add(p, &node.loop_vars, svp_expect_ident(p))
		_ = svp_accept(p, .Comma)
	}
	_ = svp_expect(p, .RBracket)
	_ = svp_expect(p, .RParen)
	node.body = svp_parse_statement_or_null(p)
	return node
}

svp_parse_assertion :: proc(p: ^SVParser2, kind: SVAssertKind) -> ^SVAssert {
	svp_bump(p)
	node := svp_new(p, SVAssert)
	node.kind = kind
	if svp_accept_kw(p, .Final) {
		// deferred assertion
	} else if svp_accept(p, .Hash) {
		svp_bump(p) // #0
	}
	if svp_accept_kw(p, .Property) {
		node.is_property = true
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
			node.property_text = strings.to_string(b)
		}
		if svp_accept_kw(p, .Else) { node.else_body = svp_parse_statement_or_null(p); return node }
		if !svp_at(p, .Semicolon) { node.pass_body = svp_parse_statement_or_null(p); return node }
		_ = svp_expect(p, .Semicolon)
		return node
	}
	if svp_at(p, .LParen) {
		svp_bump(p)
		node.cond = svp_parse_expr(p, 0)
		_ = svp_expect(p, .RParen)
	} else {
		node.cond = svp_parse_expr(p, 0)
	}
	if svp_accept_kw(p, .Else) { node.else_body = svp_parse_statement_or_null(p); return node }
	if !svp_at(p, .Semicolon) { node.pass_body = svp_parse_statement_or_null(p); return node }
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_subroutine :: proc(p: ^SVParser2, is_task: bool) -> ^SVSubroutine {
	svp_bump(p) // function/task
	sub := svp_new(p, SVSubroutine)
	sub.is_task = is_task
	if svp_accept_kw(p, .Automatic) { sub.is_automatic = true } else { _ = svp_accept_kw(p, .Static) }

	if !is_task {
		t := svp_peek(p)
		if t.kw == .Void {
			svp_bump(p)
			sub.return_data.var_type = .VOID
		} else if svp_starts_return_type(p) {
			sub.return_data = svp_parse_type(p, true)
		}
	}
	sub.name = svp_expect_ident(p)
	if svp_at(p, .LParen) {
		svp_parse_tf_ports(p, &sub.ports)
	}
	_ = svp_expect(p, .Semicolon)
	svp_parse_subroutine_body(p, sub)
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

svp_parse_tf_ports :: proc(p: ^SVParser2, ports: ^[dynamic]SVTFPort) {
	_ = svp_expect(p, .LParen)
	for !svp_at(p, .RParen) {
		port := SVTFPort{}
		if d, ok := svp_port_dir(svp_peek(p).kw); ok {
			port.dir = d
			svp_bump(p)
		} else if svp_accept_kw(p, .Ref) {
			port.dir = .REF
		}
		if svp_starts_tf_type(p) {
			port.data = svp_parse_type(p, true)
		}
		port.name = svp_expect_ident(p)
		for svp_at(p, .LBracket) { svp_add(p, &port.unpacked_dims, svp_parse_range(p)) }
		if svp_accept(p, .Assign) { port.default_value = svp_expr(p, svp_parse_expr(p, 0)) }
		svp_add(p, ports, port)
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

svp_parse_subroutine_body :: proc(p: ^SVParser2, sub: ^SVSubroutine) {
	for !svp_at_eof(p) && !svp_kw_at(p, .Endfunction) && !svp_kw_at(p, .Endtask) {
		svp_skip_attributes(p)
		t := svp_peek(p)
		if t.kw == .Import {
			svp_parse_import_list(p, &sub.body.imports)
			continue
		}
		if t.kw == .Typedef {
			svp_add(p, &sub.body.decls, svp_parse_typedef(p))
			continue
		}
		if t.kw == .Parameter || t.kw == .Localparam {
			svp_bump(p)
			decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
			_ = svp_expect(p, .Semicolon)
			svp_add(p, &sub.body.decls, decl)
			continue
		}
		if d, ok := svp_port_dir(t.kw); ok {
			// Legacy task/function port declaration.
			svp_bump(p)
			data: SVDataType
			if svp_starts_tf_type(p) { data = svp_parse_type(p, true) }
			for {
				port := SVTFPort{dir = d, data = data}
				port.name = svp_expect_ident(p)
				for svp_at(p, .LBracket) { svp_add(p, &port.unpacked_dims, svp_parse_range(p)) }
				svp_add(p, &sub.ports, port)
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .Semicolon)
			continue
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			svp_add(p, &sub.body.decls, svp_parse_net_decl(p))
			continue
		}
		if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && (svp_is_ident(svp_peek(p, 3)) || svp_at(p, .LBracket, 3)) {
			scope := svp_expect_ident(p)
			_ = svp_expect(p, .ColonColon)
			member := svp_expect_ident(p)
			data := svp_type_from_name(p, scope, member)
			svp_add(p, &sub.body.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		if svp_is_ident(t) && (svp_is_ident(svp_peek(p, 1)) || (svp_at(p, .LBracket, 1) && svp_ident_dims_then_ident(p))) {
			name := svp_expect_ident(p)
			data := svp_type_from_name(p, "", name)
			svp_add(p, &sub.body.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		append(&sub.body.stmts, svp_parse_statement(p))
	}
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

svp_parse_gen_block_after_begin :: proc(p: ^SVParser2, label: string) -> ^SVGenBlock {
	block := svp_new(p, SVGenBlock)
	block.label = label
	if svp_accept(p, .Colon) { block.label = svp_expect_ident(p) }
	for !svp_at_eof(p) && !svp_kw_at(p, .End) {
		svp_parse_module_item(p, &block.items)
	}
	_ = svp_expect_kw(p, .End)
	svp_skip_end_label(p)
	return block
}
