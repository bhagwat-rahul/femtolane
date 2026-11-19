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
	i:         int,
	ast:       ^SystemVerilogAST,
	allocator: mem.Allocator,
	module:    ^SVModule,
	iface:     ^SVInterface,
	filepath:  string,
}

svp_peek :: #force_inline proc(p: ^SVParser2, n := 0) -> SVToken {
	j := p.i + n
	return p.toks[j] if j >= 0 && j < len(p.toks) else SVToken{kind = .EOF}
}

svp_at :: #force_inline proc(p: ^SVParser2, kind: SVTokenKind, n := 0) -> bool {
	return svp_peek(p, n).kind == kind
}

svp_kw_at :: #force_inline proc(p: ^SVParser2, kw: SVKeyword, n := 0) -> bool {
	return svp_peek(p, n).kw == kw
}

svp_advance :: #force_inline proc(p: ^SVParser2) -> SVToken {
	t := svp_peek(p)
	if t.kind != .EOF { p.i += 1 }
	return t
}

svp_accept :: #force_inline proc(p: ^SVParser2, kind: SVTokenKind) -> bool {
	if svp_at(p, kind) { p.i += 1; return true }
	return false
}

svp_accept_kw :: #force_inline proc(p: ^SVParser2, kw: SVKeyword) -> bool {
	if svp_kw_at(p, kw) { p.i += 1; return true }
	return false
}

svp_expect :: proc(p: ^SVParser2, kind: SVTokenKind) -> SVToken {
	t := svp_peek(p)
	if t.kind != kind {
		svp_error(p, fmt.tprintf("expected %v, got %v '%s'", kind, t.kind, t.text))
	}
	return svp_advance(p)
}

svp_expect_kw :: proc(p: ^SVParser2, kw: SVKeyword) -> SVToken {
	t := svp_peek(p)
	if t.kw != kw {
		svp_error(p, fmt.tprintf("expected '%s', got '%s'", sv_keyword_name(kw), t.text))
	}
	return svp_advance(p)
}

svp_is_ident :: #force_inline proc(t: SVToken) -> bool {
	return t.kind == .EscapedIdent || (t.kind == .Ident && t.kw == .None)
}

svp_expect_ident :: proc(p: ^SVParser2) -> string {
	t := svp_peek(p)
	if !svp_is_ident(t) {
		svp_error(p, fmt.tprintf("expected an identifier, got '%s'", t.text))
	}
	return svp_advance(p).text
}

svp_error :: proc(p: ^SVParser2, msg: string) -> ! {
	t := svp_peek(p)
	panic(fmt.tprintf("SystemVerilog parse error at line %d: %s (near '%s')", t.line, msg, t.text))
}

svp_at_eof :: #force_inline proc(p: ^SVParser2) -> bool { return svp_at(p, .EOF) }

svp_new :: proc(p: ^SVParser2, $T: typeid) -> ^T {
	ptr, err := new(T, p.allocator)
	ensure(err == nil, "SystemVerilog AST allocation failed")
	return ptr
}

svp_set :: proc(p: ^SVParser2, value: $T) -> ^T {
	ptr := svp_new(p, T)
	ptr^ = value
	return ptr
}

svp_expr :: proc(p: ^SVParser2, e: SVExpr) -> ^SVExpr {
	return svp_set(p, e)
}

svp_skip_attributes :: proc(p: ^SVParser2) {
	for svp_at(p, .AttrStart) {
		p.i += 1
		for !svp_at_eof(p) && !svp_at(p, .AttrEnd) { p.i += 1 }
		_ = svp_accept(p, .AttrEnd)
	}
}

svp_skip_until_kw :: proc(p: ^SVParser2, kw: SVKeyword) {
	for !svp_at_eof(p) {
		if svp_kw_at(p, kw) { _ = svp_advance(p); return }
		_ = svp_advance(p)
	}
	svp_error(p, fmt.tprintf("unterminated construct, expected '%s'", sv_keyword_name(kw)))
}

svp_skip_until_semicolon :: proc(p: ^SVParser2) {
	for !svp_at_eof(p) {
		if svp_accept(p, .Semicolon) { return }
		_ = svp_advance(p)
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
			_ = svp_advance(p)
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
			svp_error(p, fmt.tprintf("unsupported top-level construct '%s'", t.text))
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

svp_parse_range :: proc(p: ^SVParser2, unpacked: bool) -> SVRange {
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
		if is_var_type || (t.kind == .SystemIdent && t.text == "$") {
			_ = svp_advance(p)
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
		append(&d.packed_dims, svp_parse_range(p, false))
	}
	return d
}

svp_parse_type :: proc(p: ^SVParser2, allow_implicit := true) -> SVDataType {
	data: SVDataType
	for {
		t := svp_peek(p)
		if t.kw == .Var || t.kw == .Const || t.kw == .Automatic || t.kw == .Static {
			_ = svp_advance(p)
			continue
		}
		break
	}
	t := svp_peek(p)
	if vt, ok := svp_var_type(t.kw); ok {
		_ = svp_advance(p)
		data.var_type = vt
	} else if t.kw == .Enum {
		_ = svp_advance(p)
		data.spec = svp_parse_type_spec(p, .ENUM)
	} else if t.kw == .Struct || t.kw == .Union {
		_ = svp_advance(p)
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
				for !svp_at(p, .RBracket) && !svp_at_eof(p) { _ = svp_advance(p) }
				_ = svp_expect(p, .RBracket)
			}
			if svp_accept(p, .Assign) { entry.value = svp_expr(p, svp_parse_expr(p, 0)) }
			append(&spec.enum_names, entry)
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
			for svp_at(p, .LBracket) { append(&decl.unpacked_dims, svp_parse_range(p, true)) }
			if svp_accept(p, .Assign) { decl.init = svp_expr(p, svp_parse_expr(p, 0)) }
			append(&member.declarators, decl)
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .Semicolon)
		append(&spec.members, member)
	}
	_ = svp_expect(p, .RBrace)
	return spec
}

svp_parse_declarators :: proc(p: ^SVParser2) -> [dynamic]SVDeclarator {
	decls: [dynamic]SVDeclarator
	for {
		decl := SVDeclarator{name = svp_expect_ident(p)}
		for svp_at(p, .LBracket) { append(&decl.unpacked_dims, svp_parse_range(p, true)) }
		if svp_accept(p, .Assign) { decl.init = svp_expr(p, svp_parse_expr(p, 0)) }
		append(&decls, decl)
		if !svp_accept(p, .Comma) { break }
	}
	return decls
}

svp_parse_typedef :: proc(p: ^SVParser2) -> ^SVTypeDecl {
	_ = svp_expect_kw(p, .Typedef)
	decl := svp_new(p, SVTypeDecl)
	decl.data = svp_parse_type(p, false)
	decl.name = svp_expect_ident(p)
	for svp_at(p, .LBracket) { append(&decl.unpacked_dims, svp_parse_range(p, true)) }
	_ = svp_expect(p, .Semicolon)
	p.ast.type_names[decl.name] = true
	return decl
}

svp_parse_net_decl_after_keyword :: proc(p: ^SVParser2, net_type: SVNetType, data: SVDataType) -> ^SVNetDecl {
	decl := svp_new(p, SVNetDecl)
	decl.net_type = net_type
	decl.data = data
	decl.declarators = svp_parse_declarators(p)
	_ = svp_expect(p, .Semicolon)
	return decl
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
		_ = svp_advance(p)
		net_type = nt
		if svp_accept(p, .Hash) {
			if svp_at(p, .LParen) {
				for !svp_at(p, .RParen) && !svp_at_eof(p) { _ = svp_advance(p) }
				_ = svp_expect(p, .RParen)
			} else { _ = svp_advance(p) }
		}
		data = svp_parse_net_data_type(p)
	} else {
		data = svp_parse_net_data_type(p)
	}
	return svp_parse_net_decl_after_keyword(p, net_type, data)
}

svp_parse_param_assignments :: proc(p: ^SVParser2, decl: ^SVParamDecl, in_port_list: bool) {
	for {
		a := SVParamAssign{name = svp_expect_ident(p)}
		for svp_at(p, .LBracket) { append(&a.unpacked_dims, svp_parse_range(p, true)) }
		if svp_accept(p, .Assign) { a.value = svp_expr(p, svp_parse_expr(p, 0)) }
		append(&decl.assignments, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
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
		append(&decl.assignments, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
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

svp_bin_prec :: proc(kind: SVTokenKind) -> u8 {
	#partial switch kind {
	case .Question: return 1
	case .PipePipe: return 2
	case .AmpAmp: return 3
	case .Pipe: return 4
	case .Caret, .CaretTilde, .TildeCaret: return 5
	case .Amp: return 6
	case .EqEq, .NotEq, .CaseEq, .CaseNeq, .WildEq, .WildNeq: return 7
	case .Lt, .Le, .Gt, .Ge: return 8
	case .Shl, .Shr, .Ashl, .Ashr: return 9
	case .Plus, .Minus: return 10
	case .Star, .Slash, .Percent: return 11
	case .Pow: return 12
	}
	return 0
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

svp_parse_expr :: proc(p: ^SVParser2, min_prec: u8 = 0) -> SVExpr {
	lhs := svp_parse_unary(p)
	for {
		// inside { range_list }
		if min_prec <= 8 && svp_kw_at(p, .Inside) {
			_ = svp_advance(p)
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
				append(&ranges, r)
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .RBrace)
			lhs = svp_set(p, SVInside{subject = lhs, ranges = ranges})
			continue
		}
		kind := svp_peek(p).kind
		if kind == .Question && min_prec <= 1 {
			_ = svp_advance(p)
			t := svp_parse_expr(p, 0)
			_ = svp_expect(p, .Colon)
			f := svp_parse_expr(p, 1)
			lhs = svp_set(p, SVTernary{cond = lhs, lhs = t, rhs = f})
			continue
		}
		prec := svp_bin_prec(kind)
		if prec == 0 || prec < min_prec { break }
		_ = svp_advance(p)
		rhs := svp_parse_expr(p, prec + 1)
		lhs = svp_set(p, SVBinary{op = svp_bin_op(kind), lhs = lhs, rhs = rhs})
	}
	return lhs
}

svp_parse_unary :: proc(p: ^SVParser2) -> SVExpr {
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
		_ = svp_advance(p)
		operand := svp_parse_unary(p)
		return svp_set(p, SVIncDec{operand = operand, is_dec = is_dec, is_prefix = true})
	case:
		has_op = false
	}
	if !has_op { return svp_parse_postfix(p, svp_parse_primary(p)) }
	_ = svp_advance(p)
	operand := svp_parse_unary(p)
	return svp_set(p, SVUnary{op = op, operand = operand})
}

svp_parse_postfix :: proc(p: ^SVParser2, prefix: SVExpr) -> SVExpr {
	base := prefix
	parts: [dynamic]SVSelectPart

	// Scoped names and calls are handled here too, because statement-leading
	// identifiers arrive without going through primary's scoped-name branch.
	if name, is_ident := base.(string); is_ident {
		if svp_accept(p, .ColonColon) {
			member := svp_expect_ident(p)
			base = SVScopedName{scope = name, name = member}
			if svp_at(p, .LParen) {
				qual := strings.concatenate({name, "::", member}, p.allocator)
				base = svp_parse_call(p, qual, false)
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
			append(&parts, part)
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
			append(&parts, SVSelectPart{member = member})
			continue
		}
		break
	}

	if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
		_ = svp_advance(p)
		return svp_parse_cast(p, "", base)
	}
	if svp_at(p, .Inc) || svp_at(p, .Dec) {
		is_dec := svp_at(p, .Dec)
		_ = svp_advance(p)
		selected := base
		if len(parts) > 0 { selected = svp_set(p, SVSelect{base = base, parts = parts}) }
		return svp_set(p, SVIncDec{operand = selected, is_dec = is_dec})
	}
	if len(parts) == 0 { return base }
	return svp_set(p, SVSelect{base = base, parts = parts})
}

svp_parse_primary :: proc(p: ^SVParser2) -> SVExpr {
	t := svp_peek(p)
	_, is_var_type := svp_var_type(t.kw)
	if t.kw == .Signed || t.kw == .Unsigned || t.kw == .Void || (is_var_type && svp_at(p, .Tick, 1)) {
		target := svp_advance(p).text
		_ = svp_expect(p, .Tick)
		return svp_parse_cast(p, target, nil)
	}
	#partial switch t.kind {
	case .LParen:
		_ = svp_advance(p)
		e := svp_parse_expr(p, 0)
		_ = svp_expect(p, .RParen)
		if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
			_ = svp_advance(p)
			return svp_parse_cast(p, "", e)
		}
		return e
	case .LBrace:
		return svp_parse_concat(p)
	case .Tick:
		if svp_at(p, .LBrace, 1) {
			_ = svp_advance(p)
			return svp_parse_aggregate(p, "", "")
		}
		return svp_parse_number(p)
	case .Number:
		return svp_parse_number(p)
	case .String:
		_ = svp_advance(p)
		return SVStringLit(t.text)
	case .SystemIdent:
		name := svp_advance(p).text
		if svp_at(p, .LParen) { return svp_parse_call(p, name, true) }
		return svp_set(p, SVCall{name = name, is_system = true})
	case .EscapedIdent, .Ident:
		if t.kw != .None {
			lo := max(0, p.i - 4)
			for j in lo ..< min(len(p.toks), p.i + 2) { fmt.eprintfln("DBG tok %d: %v kw=%v '%s'", j, p.toks[j].kind, p.toks[j].kw, p.toks[j].text) }
			svp_error(p, fmt.tprintf("unexpected keyword '%s' in expression", t.text))
		}
		name := svp_advance(p).text
		if svp_accept(p, .ColonColon) {
			member := svp_expect_ident(p)
			scoped := SVScopedName{scope = name, name = member}
			qual := strings.concatenate({name, "::", member}, p.allocator)
			if svp_at(p, .LParen) {
				return svp_parse_call(p, qual, false)
			}
			if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
				_ = svp_advance(p)
				return svp_parse_cast(p, qual, nil)
			}
			if svp_at(p, .Tick) && svp_at(p, .LBrace, 1) {
				_ = svp_advance(p)
				return svp_parse_aggregate(p, name, member)
			}
			return scoped
		}
		if svp_at(p, .LParen) { return svp_parse_call(p, name, false) }
		if svp_at(p, .Tick) && svp_at(p, .LParen, 1) {
			_ = svp_advance(p)
			return svp_parse_cast(p, name, nil)
		}
		if svp_at(p, .Tick) && svp_at(p, .LBrace, 1) {
			_ = svp_advance(p)
			return svp_parse_aggregate(p, "", name)
		}
		return name
	}
	svp_error(p, fmt.tprintf("unexpected token '%s' in expression", t.text))
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
			_ = svp_advance(p)
			arg.name = svp_expect_ident(p)
			_ = svp_expect(p, .LParen)
			if !svp_at(p, .RParen) { arg.value = svp_expr(p, svp_parse_expr(p, 0)) }
			_ = svp_expect(p, .RParen)
		} else if !svp_at(p, .Comma) {
			arg.value = svp_expr(p, svp_parse_expr(p, 0))
		}
		append(&call.args, arg)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RParen)
	return call
}

svp_parse_concat :: proc(p: ^SVParser2) -> SVExpr {
	_ = svp_expect(p, .LBrace)
	if svp_at(p, .RBrace) {
		_ = svp_advance(p)
		return svp_set(p, SVConcat{})
	}
	// Streaming concatenation: {<< [slice] { a, b }} / {>> ...}
	if (svp_at(p, .Shl) && svp_peek(p).text == "<<") || (svp_at(p, .Shr) && svp_peek(p).text == ">>") {
		stream := svp_new(p, SVStream)
		stream.dir = svp_at(p, .Shl) ? .LEFT : .RIGHT
		_ = svp_advance(p)
		if !svp_at(p, .LBrace) { stream.slice = svp_expr(p, svp_parse_expr(p, 0)) }
		_ = svp_expect(p, .LBrace)
		for {
			append(&stream.parts, svp_parse_expr(p, 0))
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .RBrace)
		_ = svp_expect(p, .RBrace)
		return stream
	}
	first := svp_parse_expr(p, 0)
	if svp_at(p, .LBrace) {
		// replication
		_ = svp_advance(p)
		parts: [dynamic]SVExpr
		for {
			append(&parts, svp_parse_expr(p, 0))
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
	append(&node.parts, first)
	for svp_accept(p, .Comma) {
		append(&node.parts, svp_parse_expr(p, 0))
	}
	_ = svp_expect(p, .RBrace)
	return node
}

svp_parse_aggregate :: proc(p: ^SVParser2, type_scope, type_name: string) -> SVExpr {
	_ = svp_expect(p, .LBrace)
	agg := svp_new(p, SVAggregate)
	agg.type_scope = type_scope
	agg.type_name = type_name
	if svp_at(p, .RBrace) {
		_ = svp_advance(p)
		return agg
	}
	if svp_at(p, .Number) && svp_at(p, .LBrace, 1) {
		agg.count = svp_expr(p, svp_parse_expr(p, 0))
		_ = svp_expect(p, .LBrace)
	}
	for !svp_at(p, .RBrace) {
		entry: SVAggregateEntry
		if svp_is_ident(svp_peek(p)) && svp_at(p, .Colon, 1) {
			entry.key = svp_expect_ident(p)
			_ = svp_expect(p, .Colon)
		} else if svp_at(p, .String) && svp_at(p, .Colon, 1) {
			entry.key = svp_advance(p).text
			_ = svp_expect(p, .Colon)
		} else if svp_kw_at(p, .Default) {
			_ = svp_advance(p)
			_ = svp_expect(p, .Colon)
			entry.key = "default"
		}
		entry.value = svp_parse_expr(p, 0)
		append(&agg.entries, entry)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .RBrace)
	if agg.count != nil { _ = svp_expect(p, .RBrace) }
	return agg
}

svp_parse_number :: proc(p: ^SVParser2) -> SVExpr {
	t := svp_advance(p)
	text := t.text
	width: u32
	base := SVNumberBase.DEC
	signed := false
	is_unbased := false
	is_real := false
	real_value: f64
	raw := text
	time_unit := ""

	// Macro-expanded size: XLEN'd4 arrives as Number("32") + Number("'d4").
	if !strings.contains(text, "'") && svp_at(p, .Number) && strings.has_prefix(svp_peek(p).text, "'") {
		t2 := svp_advance(p)
		text = strings.concatenate({t.text, t2.text}, p.allocator)
	}

	if strings.has_prefix(text, "'") {
		// unbased ('0/'1/'x/'z) or unsized based ('hFF)
		body := text[1:]
		if len(body) > 0 && (body[0] == 's' || body[0] == 'S') {
			signed = true
			body = body[1:]
		}
		if len(body) > 0 && svl_is_base_char(body[0]) {
			base = sv_number_base_of(body[0])
			raw = body[1:]
			raw = strings.trim_space(raw)
		} else {
			is_unbased = true
			raw = body
		}
	} else if idx := strings.index_byte(text, '\''); idx >= 0 {
		width = sv_parse_size_text(text[:idx])
		body := text[idx + 1:]
		if len(body) > 0 && (body[0] == 's' || body[0] == 'S') {
			signed = true
			body = body[1:]
		}
		if len(body) > 0 && svl_is_base_char(body[0]) {
			base = sv_number_base_of(body[0])
			raw = strings.trim_space(body[1:])
		}
	} else {
		// Real literal?
		if strings.contains(text, ".") || strings.contains_any(text, "eE") {
			if v, ok := strconv.parse_f64(text); ok {
				is_real = true
				real_value = v
			}
		}
		// trailing time unit
		switch {
		case strings.has_suffix(text, "ms"): time_unit = "ms"; raw = text[:len(text)-2]
		case strings.has_suffix(text, "us"): time_unit = "us"; raw = text[:len(text)-2]
		case strings.has_suffix(text, "ns"): time_unit = "ns"; raw = text[:len(text)-2]
		case strings.has_suffix(text, "ps"): time_unit = "ps"; raw = text[:len(text)-2]
		case strings.has_suffix(text, "fs"): time_unit = "fs"; raw = text[:len(text)-2]
		case strings.has_suffix(text, "s"): time_unit = "s"; raw = text[:len(text)-1]
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
	return SVNumber {
		raw = raw,
		width = width,
		base = base,
		is_signed = signed || (width == 0 && !has_x_z),
		is_unbased = is_unbased,
		is_real = is_real,
		real_value = real_value,
		value = value,
		has_x_z = has_x_z,
		time_unit = time_unit,
	}
}

// ---------------------------------------------------------------------------------------
// Entry point (temporary name; the public API switches to this once it covers the suite)
// ---------------------------------------------------------------------------------------

svp_parse_tokens :: proc(ast: ^SystemVerilogAST, toks: []SVToken, filepath: string, allocator: mem.Allocator) {
	p := SVParser2{toks = toks, ast = ast, allocator = allocator, filepath = filepath}
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
			p.ast.type_names[name] = true
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
		_ = svp_advance(p)
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
			svp_error(p, fmt.tprintf("unsupported package item '%s'", t.text))
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
		if t.text in p.ast.type_names || t.text in p.ast.iface_names { return true }
		n := svp_peek(p, 1)
		if svp_is_ident(n) || n.kind == .Dot { return true }
	}
	return false
}

svp_parse_module :: proc(p: ^SVParser2) -> ^SVModule {
	_ = svp_advance(p) // module/macromodule
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
			append(&iface.modports, svp_parse_modport(p))
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
			_ = svp_advance(p)
		} else if svp_accept_kw(p, .Ref) {
			dir = .REF
		}
		append(&mp.ports, SVModportPort{dir = dir, name = svp_expect_ident(p)})
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
	if svp_accept_kw(p, .Type) { return svp_parse_type_param_decl2(p, is_local, in_port_list) }

	decl := svp_new(p, SVParamDecl)
	decl.is_local = is_local
	decl.data = svp_parse_type_for_param(p)
	for {
		a := SVParamAssign{name = svp_expect_ident(p)}
		for svp_at(p, .LBracket) { append(&a.unpacked_dims, svp_parse_range(p, true)) }
		if svp_accept(p, .Assign) { a.value = svp_expr(p, svp_parse_expr(p, 0)) }
		append(&decl.assignments, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
		if in_port_list && svp_param_comma_starts_group(p) { p.i -= 1; break }
	}
	return decl
}

svp_parse_type_for_param :: proc(p: ^SVParser2) -> SVDataType {
	t := svp_peek(p)
	if t.kind == .LBracket {
		data: SVDataType
		for svp_at(p, .LBracket) { append(&data.packed_dims, svp_parse_range(p, false)) }
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

svp_parse_type_param_decl2 :: proc(p: ^SVParser2, is_local: bool, in_port_list: bool) -> ^SVParamDecl {
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
		append(&decl.assignments, a)
		if !svp_accept(p, .Comma) { break }
		if in_port_list && svp_at(p, .RParen) { break }
		if in_port_list && svp_param_comma_starts_group(p) { p.i -= 1; break }
	}
	return decl
}

svp_parse_module_ports :: proc(p: ^SVParser2, module: ^SVModule) {
	_ = svp_expect(p, .LParen)
	if svp_accept(p, .DotStar) {
		_ = svp_expect(p, .RParen)
		module.wildcard_ports = true
		module.is_ansi = true
		return
	}
	if svp_at(p, .RParen) {
		_ = svp_advance(p)
		module.is_ansi = true
		return
	}
	if svp_port_list_is_ansi(p) {
		module.is_ansi = true
		svp_parse_ansi_ports(p, &module.ports)
	} else {
		for {
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
			}
			append(&module.ports, port)
			if !svp_accept(p, .Comma) { break }
			if svp_at(p, .RParen) { break }
		}
	}
	_ = svp_expect(p, .RParen)
}

svp_parse_interface_ports :: proc(p: ^SVParser2, iface: ^SVInterface) {
	_ = svp_expect(p, .LParen)
	if svp_at(p, .RParen) { _ = svp_advance(p); return }
	svp_parse_ansi_ports(p, &iface.ports)
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
			_ = svp_advance(p)
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
			_ = svp_advance(p)
			given_dir = true
		} else {
			port.dir = prev_dir
		}

		if nt, ok := svp_net_type(svp_peek(p).kw); ok {
			port.net_type = nt
			_ = svp_advance(p)
			given_net = true
		} else {
			port.net_type = prev_net
		}

		if svp_at(p, .Dot) {
			_ = svp_advance(p)
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
			_ = svp_advance(p)
			port.iface_name = "interface"
			port.name = svp_expect_ident(p)
			given_data = true
		} else if t := svp_peek(p); svp_is_ident(t) && svp_at(p, .Dot, 1) {
			port.iface_name = t.text
			_ = svp_advance(p)
			_ = svp_expect(p, .Dot)
			port.modport = svp_expect_ident(p)
			port.name = svp_expect_ident(p)
			given_data = true
		} else if t := svp_peek(p); svp_is_ident(t) && t.text in p.ast.iface_names && svp_is_ident(svp_peek(p, 1)) {
			port.iface_name = t.text
			_ = svp_advance(p)
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

		for svp_at(p, .LBracket) { append(&port.unpacked_dims, svp_parse_range(p, true)) }
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
		if t.text in p.ast.type_names { return true }
		n := svp_peek(p, 1)
		if n.kind == .ColonColon { return true }
		if svp_is_ident(n) { return true }
		if n.kind == .LBracket && svp_ident_dims_then_ident(p) { return true }
	}
	return false
}

svp_parse_port_declaration :: proc(p: ^SVParser2, dir: SVPortDir) -> ^SVPortDecl {
	_ = svp_advance(p) // direction keyword
	net_type := SVNetType.NONE
	if nt, ok := svp_net_type(svp_peek(p).kw); ok {
		net_type = nt
		_ = svp_advance(p)
	}
	data := svp_parse_net_data_type(p)
	decl := svp_new(p, SVNetDecl)
	decl.net_type = net_type
	decl.data = data
	decl.declarators = svp_parse_declarators(p)
	_ = svp_expect(p, .Semicolon)
	if p.module != nil {
		for d in decl.declarators {
			port := svp_find_module_port(p.module, d.name)
			if port == nil {
				port = svp_new(p, SVPort)
				port.name = d.name
				append(&p.module.ports, port)
			}
			port.dir = dir
			port.net_type = net_type
			if len(data.type_name) > 0 || data.var_type != .IMPLICIT || data.spec != nil || len(data.packed_dims) > 0 {
				port.data = data
			}
			port.unpacked_dims = d.unpacked_dims
			port.default_value = d.init
		}
	}
	return svp_set(p, SVPortDecl{dir = dir, decl = decl})
}

svp_find_module_port :: proc(module: ^SVModule, name: string) -> ^SVPort {
	for port in module.ports { if port.name == name { return port } }
	return nil
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
			_ = svp_advance(p)
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
		_ = svp_advance(p)
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
		_ = svp_advance(p)
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
		_ = svp_advance(p)
		gv := svp_new(p, SVGenvarDecl)
		for {
			append(&gv.names, svp_expect_ident(p))
			if !svp_accept(p, .Comma) { break }
		}
		_ = svp_expect(p, .Semicolon)
		append(items, gv)
	case .Assert: append(items, svp_parse_assertion(p, .ASSERT))
	case .Assume: append(items, svp_parse_assertion(p, .ASSUME))
	case .Cover: append(items, svp_parse_assertion(p, .COVER))
	case .Restrict:
		_ = svp_advance(p)
		if svp_kw_at(p, .Property) {
			_ = svp_advance(p)
			if svp_at(p, .LParen) {
				depth := 0
				for !svp_at_eof(p) {
					if svp_at(p, .LParen) { depth += 1 }
					if svp_at(p, .RParen) { depth -= 1; if depth == 0 { _ = svp_advance(p); break } }
					_ = svp_advance(p)
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
		svp_skip_until_semicolon(p)
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
			name := t.text
			_ = svp_advance(p)
			svp_parse_instantiation(p, name, true, items)
			return
		}
		if t.kind == .SystemIdent {
			name := svp_advance(p).text
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
				_ = svp_advance(p)
				member := svp_expect_ident(p)
				if svp_is_ident(svp_peek(p)) || svp_at(p, .LBracket) {
					data := svp_type_from_name(p, scope, member)
					decl := svp_parse_net_decl_after_keyword(p, .NONE, data)
					append(items, decl)
					return
				}
				// scoped task call
				if svp_at(p, .Semicolon) {
					_ = svp_advance(p)
					append(items, svp_set(p, SVCall{name = strings.concatenate({scope, "::", member}, p.allocator)}))
					return
				}
				svp_error(p, "unsupported scoped module item")
			}
			is_gate := svp_is_gate_kw(t.kw)
			svp_parse_instantiation(p, name, is_gate, items)
			return
		}
		svp_error(p, fmt.tprintf("unexpected token '%s' in module body", t.text))
	}
}

svp_parse_cont_assign :: proc(p: ^SVParser2) -> ^SVContAssign {
	_ = svp_expect_kw(p, .Assign)
	if svp_accept(p, .Hash) {
		if svp_at(p, .LParen) {
			depth := 0
			for !svp_at_eof(p) {
				if svp_at(p, .LParen) { depth += 1 }
				if svp_at(p, .RParen) { depth -= 1; if depth == 0 { _ = svp_advance(p); break } }
				_ = svp_advance(p)
			}
		} else { _ = svp_advance(p) }
	}
	node := svp_new(p, SVContAssign)
	for {
		pair := SVAssignPair{lhs = svp_parse_expr(p, 0)}
		_ = svp_expect(p, .Assign)
		pair.rhs = svp_parse_expr(p, 0)
		append(&node.pairs, pair)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_alias :: proc(p: ^SVParser2) -> ^SVAlias {
	_ = svp_expect_kw(p, .Alias)
	node := svp_new(p, SVAlias)
	for {
		append(&node.names, svp_parse_expr(p, 0))
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
		append(&node.pairs, pair)
		if !svp_accept(p, .Comma) { break }
	}
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_type_from_name :: proc(p: ^SVParser2, scope, name: string) -> SVDataType {
	data := SVDataType{type_scope = scope, type_name = name}
	for svp_at(p, .LBracket) { append(&data.packed_dims, svp_parse_range(p, false)) }
	return data
}

svp_parse_param_overrides :: proc(p: ^SVParser2, inst: ^SVInstance) {
	if !svp_accept(p, .Hash) { return }
	if svp_at(p, .Number) {
		// delay control, not a parameter list
		_ = svp_advance(p)
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
		append(&inst.param_overrides, o)
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
		if t.text in p.ast.type_names || t.text in p.ast.iface_names { return true }
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
		for !svp_at(p, .RParen) && !svp_at_eof(p) { _ = svp_advance(p) }
		_ = svp_expect(p, .RParen)
	}
	first := true
	for {
		inst := svp_new(p, SVInstance)
		inst.cell_name = cell
		inst.is_gate = is_gate
		if svp_at(p, .Hash) { svp_parse_param_overrides(p, inst) }
		if svp_at(p, .Hash) {
			// gate delay triple / `#delay
			_ = svp_advance(p)
			if svp_at(p, .LParen) {
				for !svp_at(p, .RParen) && !svp_at_eof(p) { _ = svp_advance(p) }
				_ = svp_expect(p, .RParen)
			} else {
				_ = svp_advance(p)
			}
		}
		if svp_is_ident(svp_peek(p)) || svp_at(p, .EscapedIdent) {
			inst.name = svp_expect_ident(p)
		} else if !is_gate {
			svp_error(p, "expected an instance name")
		}
		for svp_at(p, .LBracket) { append(&inst.unpacked_dims, svp_parse_range(p, true)) }
		if svp_at(p, .LParen) { svp_parse_port_connections(p, inst) }
		append(items, inst)
		first = false
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
		append(&inst.port_conns, conn)
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
	node := svp_new(p, SVGenLoop)
	node.var = svp_expect_ident(p)
	_ = svp_expect(p, .Assign)
	node.init = svp_parse_expr(p, 0)
	_ = svp_expect(p, .Semicolon)
	node.cond = svp_parse_expr(p, 0)
	_ = svp_expect(p, .Semicolon)
	node.step = svp_parse_stmt_no_semi(p)
	_ = svp_expect(p, .RParen)
	node.body = svp_parse_gen_block(p)
	return node
}

svp_parse_gen_if :: proc(p: ^SVParser2) -> ^SVGenIf {
	_ = svp_expect_kw(p, .If)
	_ = svp_expect(p, .LParen)
	node := svp_new(p, SVGenIf)
	node.cond = svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	node.then_blk = svp_parse_gen_block(p)
	if svp_accept_kw(p, .Else) { node.else_blk = svp_parse_gen_block(p) }
	return node
}

svp_parse_gen_case :: proc(p: ^SVParser2) -> ^SVGenCase {
	kind := svp_peek(p).kw
	_ = svp_advance(p)
	node := svp_new(p, SVGenCase)
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
				append(&item.exprs, svp_parse_expr(p, 0))
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .Colon)
		}
		item.body = svp_parse_gen_block(p)
		append(&node.items, item)
	}
	_ = svp_expect_kw(p, .Endcase)
	_ = kind
	return node
}

// ---------------------------------------------------------------------------------------
// Procedures, statements, subroutines
// ---------------------------------------------------------------------------------------

svp_parse_proc :: proc(p: ^SVParser2, kind: SVProcKind) -> ^SVProc {
	_ = svp_advance(p)
	node := svp_new(p, SVProc)
	node.kind = kind
	if svp_at(p, .At) {
		ctl := svp_parse_timing_ctl(p)
		node.events = ctl.events
		node.any_event = ctl.any_event
		node.body = svp_parse_statement(p)
		return node
	}
	if svp_at(p, .Hash) {
		ctl := svp_parse_timing_ctl(p)
		node.body = svp_set(p, SVTimingStmt{timing = ctl, body = svp_parse_statement_or_null(p)})
		return node
	}
	node.body = svp_parse_statement(p)
	return node
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
			append(&ctl.events, ev)
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
	append(&ctl.events, ev)
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
		_ = svp_advance(p)
		return svp_set(p, SVBlock{})
	}
	// optional statement label
	if svp_is_ident(svp_peek(p)) && svp_at(p, .Colon, 1) {
		_ = svp_advance(p)
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
		_ = svp_advance(p)
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
		_ = svp_advance(p)
		_ = svp_expect(p, .Semicolon)
		return svp_set(p, SVJump{kind = .BREAK})
	case .Continue:
		_ = svp_advance(p)
		_ = svp_expect(p, .Semicolon)
		return svp_set(p, SVJump{kind = .CONTINUE})
	case .Return:
		_ = svp_advance(p)
		j := svp_new(p, SVJump)
		j.kind = .RETURN
		if !svp_at(p, .Semicolon) { j.value = svp_expr(p, svp_parse_expr(p, 0)) }
		_ = svp_expect(p, .Semicolon)
		return j
	case .Void:
		_ = svp_advance(p)
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
		svp_error(p, fmt.tprintf("unsupported procedural construct '%s'", t.text))
	case:
	}

	if svp_at(p, .At) || svp_at(p, .Hash) {
		ctl := svp_parse_timing_ctl(p)
		body := svp_parse_statement_or_null(p)
		if body == nil { return svp_set(p, SVTimingStmt{timing = ctl}) }
		return svp_set(p, SVTimingStmt{timing = ctl, body = body})
	}
	if svp_at(p, .SystemIdent) {
		name := svp_advance(p).text
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
		name := svp_advance(p).text
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
		_ = svp_advance(p)
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
		_ = svp_advance(p)
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
		if scoped, ok := base.(SVScopedName); ok { return svp_set(p, SVCall{name = strings.concatenate({scoped.scope, "::", scoped.name}, p.allocator)}) }
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
	_ = svp_advance(p)
	timing: ^SVTimingCtl
	if svp_at(p, .Hash) || svp_at(p, .At) {
		ctl := svp_parse_timing_ctl(p)
		timing = svp_set(p, ctl)
	}
	rhs := svp_parse_expr(p, 0)
	node := svp_new(p, SVAssignStmt)
	node.lhs = base
	node.op = op
	node.rhs = rhs
	node.nonblocking = nonblocking
	node.timing = timing
	_ = svp_expect(p, .Semicolon)
	return node
}

svp_parse_block :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Begin)
	block := svp_new(p, SVBlock)
	if svp_accept(p, .Colon) { block.label = svp_expect_ident(p) }
	for !svp_at_eof(p) {
		svp_skip_attributes(p)
		if svp_kw_at(p, .End) {
			_ = svp_advance(p)
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
			append(&block.decls, svp_parse_typedef(p))
			continue
		}
		if t.kw == .Parameter || t.kw == .Localparam {
			_ = svp_advance(p)
			decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
			_ = svp_expect(p, .Semicolon)
			append(&block.decls, decl)
			continue
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			append(&block.decls, svp_parse_net_decl(p))
			continue
		}
		if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && (svp_is_ident(svp_peek(p, 3)) || svp_at(p, .LBracket, 3)) {
			scope := svp_expect_ident(p)
			_ = svp_expect(p, .ColonColon)
			member := svp_expect_ident(p)
			data := svp_type_from_name(p, scope, member)
			append(&block.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		if svp_is_ident(t) && svp_is_ident(svp_peek(p, 1)) {
			name := svp_expect_ident(p)
			data := svp_type_from_name(p, "", name)
			append(&block.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		append(&block.stmts, svp_parse_statement(p))
	}
	svp_error(p, "unterminated begin block")
}

svp_parse_if :: proc(p: ^SVParser2, q: SVQualifier) -> SVStmt {
	_ = svp_expect_kw(p, .If)
	node := svp_new(p, SVIf)
	node.qualifier = q
	_ = svp_expect(p, .LParen)
	node.cond = svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	node.then_body = svp_parse_statement_or_null(p)
	if svp_accept_kw(p, .Else) { node.else_body = svp_parse_statement_or_null(p) }
	return node
}

svp_parse_case :: proc(p: ^SVParser2, q: SVQualifier) -> SVStmt {
	kind := SVCaseKind.CASE
	#partial switch svp_peek(p).kw {
	case .Casez: kind = .CASEZ
	case .Casex: kind = .CASEX
	}
	_ = svp_advance(p)
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
					_ = svp_advance(p)
					r.lo = svp_parse_expr(p, 0)
					if svp_accept(p, .Colon) { r.hi = svp_parse_expr(p, 0); r.has_hi = true }
					_ = svp_expect(p, .RBracket)
					append(&item.ranges, r)
				} else {
					append(&item.exprs, svp_parse_expr(p, 0))
				}
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .Colon)
		}
		item.body = svp_parse_statement_or_null(p)
		append(&node.items, item)
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
				for svp_at(p, .LBracket) { append(&d.unpacked_dims, svp_parse_range(p, true)) }
				if svp_accept(p, .Assign) { d.init = svp_expr(p, svp_parse_expr(p, 0)) }
				append(&decl.declarators, d)
				if !svp_accept(p, .Comma) { break }
			}
			append(&node.var_decls, decl)
		} else {
			for {
				append(&node.init_assigns, svp_parse_for_assign(p))
				if !svp_accept(p, .Comma) { break }
			}
		}
	}
	_ = svp_expect(p, .Semicolon)
	if !svp_at(p, .Semicolon) { node.cond = svp_expr(p, svp_parse_expr(p, 0)) }
	_ = svp_expect(p, .Semicolon)
	if !svp_at(p, .RParen) {
		for {
			append(&node.steps, svp_parse_stmt_no_semi(p))
			if !svp_accept(p, .Comma) { break }
		}
	}
	_ = svp_expect(p, .RParen)
	node.body = svp_parse_statement_or_null(p)
	return node
}

svp_parse_for_assign :: proc(p: ^SVParser2) -> ^SVAssignStmt {
	base := svp_parse_postfix(p, svp_parse_primary(p))
	node := svp_new(p, SVAssignStmt)
	node.lhs = base
	if svp_accept(p, .Assign) {
		node.rhs = svp_parse_expr(p, 0)
	}
	return node
}

svp_parse_stmt_no_semi :: proc(p: ^SVParser2) -> SVStmt {
	t := svp_peek(p)
	if t.kind == .Inc || t.kind == .Dec {
		e := svp_parse_unary(p)
		if inc, ok := e.(^SVIncDec); ok { return inc }
		return svp_parse_assignment_no_semi_expr(p, e)
	}
	if svp_is_ident(t) || t.kind == .EscapedIdent {
		name := svp_advance(p).text
		if svp_at(p, .LParen) { return svp_parse_call(p, name, false).(^SVCall) }
		if svp_at(p, .Inc) || svp_at(p, .Dec) {
			is_dec := svp_at(p, .Dec)
			_ = svp_advance(p)
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
		_ = svp_advance(p)
		return svp_set(p, SVIncDec{operand = base, is_dec = is_dec})
	}
	node := svp_new(p, SVAssignStmt)
	node.lhs = base
	#partial switch svp_peek(p).kind {
	case .Assign: node.op = .EQ
	case .Le: node.nonblocking = true
	case .PlusEq: node.op = .ADD_EQ
	case .MinusEq: node.op = .SUB_EQ
	case .StarEq: node.op = .MUL_EQ
	case .SlashEq: node.op = .DIV_EQ
	case .PercentEq: node.op = .MOD_EQ
	case .AmpEq: node.op = .AND_EQ
	case .PipeEq: node.op = .OR_EQ
	case .CaretEq: node.op = .XOR_EQ
	case .ShlEq: node.op = .SHL_EQ
	case .ShrEq: node.op = .SHR_EQ
	case .AshlEq: node.op = .ASH_L_EQ
	case .AshrEq: node.op = .ASH_R_EQ
	case: svp_error(p, "expected an assignment")
	}
	_ = svp_advance(p)
	node.rhs = svp_parse_expr(p, 0)
	return node
}

svp_parse_while :: proc(p: ^SVParser2, do_while: bool) -> SVStmt {
	node := svp_new(p, SVWhile)
	node.do_while = do_while
	if do_while {
		_ = svp_expect_kw(p, .Do)
		node.body = svp_parse_statement_or_null(p)
		_ = svp_expect_kw(p, .While)
	} else {
		_ = svp_expect_kw(p, .While)
	}
	_ = svp_expect(p, .LParen)
	node.cond = svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	if !do_while { node.body = svp_parse_statement_or_null(p) } else { _ = svp_expect(p, .Semicolon) }
	return node
}

svp_parse_repeat :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Repeat)
	node := svp_new(p, SVRepeat)
	_ = svp_expect(p, .LParen)
	node.count = svp_parse_expr(p, 0)
	_ = svp_expect(p, .RParen)
	node.body = svp_parse_statement_or_null(p)
	return node
}

svp_parse_forever :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Forever)
	node := svp_new(p, SVForever)
	node.body = svp_parse_statement_or_null(p)
	return node
}

svp_parse_foreach :: proc(p: ^SVParser2) -> SVStmt {
	_ = svp_expect_kw(p, .Foreach)
	node := svp_new(p, SVForeach)
	_ = svp_expect(p, .LParen)
	node.array = svp_parse_primary(p)
	for svp_accept(p, .Dot) {
		member := svp_expect_ident(p)
		parts: [dynamic]SVSelectPart
		append(&parts, SVSelectPart{member = member})
		node.array = svp_set(p, SVSelect{base = node.array, parts = parts})
	}
	_ = svp_expect(p, .LBracket)
	for !svp_at(p, .RBracket) {
		if svp_at(p, .Comma) { append(&node.loop_vars, ""); _ = svp_advance(p); continue }
		append(&node.loop_vars, svp_expect_ident(p))
		_ = svp_accept(p, .Comma)
	}
	_ = svp_expect(p, .RBracket)
	_ = svp_expect(p, .RParen)
	node.body = svp_parse_statement_or_null(p)
	return node
}

svp_parse_assertion :: proc(p: ^SVParser2, kind: SVAssertKind) -> ^SVAssert {
	_ = svp_advance(p)
	node := svp_new(p, SVAssert)
	node.kind = kind
	if svp_accept_kw(p, .Final) {
		// deferred assertion
	} else if svp_accept(p, .Hash) {
		_ = svp_advance(p) // #0
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
					if depth == 0 { _ = svp_advance(p); break }
				}
				if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
				strings.write_string(&b, svp_peek(p).text)
				_ = svp_advance(p)
			}
			node.property_text = strings.to_string(b)
		}
		if svp_accept_kw(p, .Else) { node.else_body = svp_parse_statement_or_null(p); return node }
		if !svp_at(p, .Semicolon) { node.pass_body = svp_parse_statement_or_null(p); return node }
		_ = svp_expect(p, .Semicolon)
		return node
	}
	if svp_at(p, .LParen) {
		_ = svp_advance(p)
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
	_ = svp_advance(p) // function/task
	sub := svp_new(p, SVSubroutine)
	sub.is_task = is_task
	if svp_accept_kw(p, .Automatic) { sub.is_automatic = true } else { _ = svp_accept_kw(p, .Static) }

	if !is_task {
		t := svp_peek(p)
		if t.kw == .Void {
			_ = svp_advance(p)
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
	_ = svp_advance(p) // endfunction/endtask
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
			_ = svp_advance(p)
		} else if svp_accept_kw(p, .Ref) {
			port.dir = .REF
		}
		if svp_starts_tf_type(p) {
			port.data = svp_parse_type(p, true)
		}
		port.name = svp_expect_ident(p)
		for svp_at(p, .LBracket) { append(&port.unpacked_dims, svp_parse_range(p, true)) }
		if svp_accept(p, .Assign) { port.default_value = svp_expr(p, svp_parse_expr(p, 0)) }
		append(ports, port)
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
			append(&sub.body.decls, svp_parse_typedef(p))
			continue
		}
		if t.kw == .Parameter || t.kw == .Localparam {
			_ = svp_advance(p)
			decl := svp_parse_param_decl_after_keyword(p, t.kw == .Localparam, false)
			_ = svp_expect(p, .Semicolon)
			append(&sub.body.decls, decl)
			continue
		}
		if d, ok := svp_port_dir(t.kw); ok {
			// Legacy task/function port declaration.
			_ = svp_advance(p)
			data: SVDataType
			if svp_starts_tf_type(p) { data = svp_parse_type(p, true) }
			for {
				port := SVTFPort{dir = d, data = data}
				port.name = svp_expect_ident(p)
				for svp_at(p, .LBracket) { append(&port.unpacked_dims, svp_parse_range(p, true)) }
				append(&sub.ports, port)
				if !svp_accept(p, .Comma) { break }
			}
			_ = svp_expect(p, .Semicolon)
			continue
		}
		if svp_is_decl_kw(t.kw) || t.kind == .LBracket {
			append(&sub.body.decls, svp_parse_net_decl(p))
			continue
		}
		if svp_is_ident(t) && svp_at(p, .ColonColon, 1) && (svp_is_ident(svp_peek(p, 3)) || svp_at(p, .LBracket, 3)) {
			scope := svp_expect_ident(p)
			_ = svp_expect(p, .ColonColon)
			member := svp_expect_ident(p)
			data := svp_type_from_name(p, scope, member)
			append(&sub.body.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
			continue
		}
		if svp_is_ident(t) && svp_is_ident(svp_peek(p, 1)) {
			name := svp_expect_ident(p)
			data := svp_type_from_name(p, "", name)
			append(&sub.body.decls, svp_parse_net_decl_after_keyword(p, .NONE, data))
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
	svp_parse_tokens(ast, toks, filepath, allocator)
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
