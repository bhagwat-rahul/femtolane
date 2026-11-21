package tests

import main "../src"

// Test-side decoding of the flat AST payload. The parser writes these slots
// directly; these aliases keep the assertions readable without shipping a view
// layer in the production package.
SystemVerilogAST :: main.SystemVerilogAST
SVNode :: main.SVNode
SVNodeKind :: main.SVNodeKind
SVSpan :: main.SVSpan
SVVarType :: main.SVVarType
SVNetType :: main.SVNetType
SVPortDir :: main.SVPortDir
SVTimeUnit :: main.SVTimeUnit
SVNumberBase :: main.SVNumberBase
SVSelectKind :: main.SVSelectKind
SVStreamDir :: main.SVStreamDir
SVCastKind :: main.SVCastKind
SVUnOp :: main.SVUnOp
SVBinOp :: main.SVBinOp
SVProcKind :: main.SVProcKind
SVQualifier :: main.SVQualifier
SVCaseKind :: main.SVCaseKind
SVEdgeKind :: main.SVEdgeKind
SVAssertKind :: main.SVAssertKind
SVJumpKind :: main.SVJumpKind
SVAssignOp :: main.SVAssignOp
SVTypeSpecKind :: main.SVTypeSpecKind
SVNumber :: main.SVNumber
SVSmallNumber :: main.SVSmallNumber
SVPortExtra :: main.SVPortExtra
SV_NONE :: main.SV_NONE
SV_CHUNK_SHIFT :: main.SV_CHUNK_SHIFT
SV_CHUNK_MASK :: main.SV_CHUNK_MASK
SV_CHUNK_SIZE :: main.SV_CHUNK_SIZE
SV_FIRST_SMALL :: main.SV_FIRST_SMALL
SV_IMM_BIT :: main.SV_IMM_BIT
SV_IMM_SUB_MASK :: main.SV_IMM_SUB_MASK
SV_IMM_PAYLOAD_MASK :: main.SV_IMM_PAYLOAD_MASK
SV_IMM_IDENT :: main.SV_IMM_IDENT
SV_IMM_STRING :: main.SV_IMM_STRING
SV_IMM_NUMBER :: main.SV_IMM_NUMBER

SVF_NUMBER_BASE_MASK :: u16(0x3)
SVF_NUMBER_SIGNED :: u16(0x4)
SVF_NUMBER_UNIT_SHIFT :: u16(3)
SVF_NUMBER_UNIT_MASK :: u16(0x38)
SVF_DATA_VARTYPE_MASK :: u16(0xF)
SVF_DATA_SIGNED :: u16(0x10)
SVF_RANGE_IS_SIZE :: u16(0x1)
SVF_DIR_MASK :: u16(0x7)
SVF_NET_SHIFT :: u16(3)
SVF_NET_MASK :: u16(0x78)
SVF_CASE_KIND_MASK :: u16(0x3)
SVF_CASE_QUAL_SHIFT :: u16(2)
SVF_CASE_QUAL_MASK :: u16(0xC)
SVF_CASE_INSIDE :: u16(0x10)
SVF_ASSERT_KIND_MASK :: u16(0x3)
SVF_ASSERT_PROPERTY :: u16(0x4)
SVF_SELECT_KIND_MASK :: u16(0x3)
SVF_SELECT_HAS_SECOND :: u16(0x4)
SVF_TYPESPEC_KIND_MASK :: u16(0x3)
SVF_TYPESPEC_PACKED :: u16(0x4)
SVF_TIMING_DELAY :: u16(0x1)
SVF_TIMING_ANY :: u16(0x2)
SVF_STREAM_RIGHT :: u16(0x1)
SVF_INCDEC_DEC :: u16(0x1)
SVF_INCDEC_PREFIX :: u16(0x2)
SVF_CALL_SYSTEM :: u16(0x1)
SVF_CAST_HAS_DATA :: u16(0x1)
SVF_ASSIGN_NONBLOCKING :: u16(0x1)
SVF_WHILE_DO :: u16(0x1)
SVF_PROC_ANY_EVENT :: u16(0x1)
SVF_INSTANCE_GATE :: u16(0x1)
SVF_INSTANCE_WILDCARD :: u16(0x2)
SVF_PARAM_LOCAL :: u16(0x1)
SVF_PARAM_TYPE :: u16(0x2)
SVF_TYPE_FORWARD :: u16(0x1)
SVF_SUB_TASK :: u16(0x1)
SVF_SUB_AUTOMATIC :: u16(0x2)

SVDataTypeView :: struct {
	type_scope:  string, // package/class scope of a named type (`pkg::type`)
	type_name:   string, // user-defined type reference, "" for builtin/inline types
	packed_dims: []u32, // Aux_Range nodes
	spec:        u32, // Aux_TypeSpec, SV_NONE for none
	var_type:    SVVarType,
	is_signed:   bool,
}

sv_data_type :: proc(ast: ^SystemVerilogAST, id: u32) -> SVDataTypeView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_DataType { return {} }
	return SVDataTypeView {
		type_scope = main.sv_text(ast, n.b),
		type_name = main.sv_text(ast, n.a),
		packed_dims = main.sv_children(ast, n.span),
		spec = n.c,
		var_type = SVVarType(n.flags & SVF_DATA_VARTYPE_MASK),
		is_signed = (n.flags & SVF_DATA_SIGNED) != 0,
	}
}

SVRangeView :: struct {
	msb:     u32,
	lsb:     u32, // SV_NONE when is_size
	is_size: bool,
}

sv_range :: proc(ast: ^SystemVerilogAST, id: u32) -> SVRangeView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_Range { return {} }
	return SVRangeView{msb = n.a, lsb = n.b, is_size = (n.flags & SVF_RANGE_IS_SIZE) != 0}
}

SVDeclaratorView :: struct {
	name:          string,
	unpacked_dims: []u32,
	init:          u32, // SV_NONE when absent
}

sv_declarator :: proc(ast: ^SystemVerilogAST, id: u32) -> SVDeclaratorView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_Declarator { return {} }
	return SVDeclaratorView{name = main.sv_text(ast, n.a), unpacked_dims = main.sv_children(ast, n.span), init = n.b}
}

SVImportView :: struct {
	package_name: string,
	name:         string, // "*" for wildcard imports
}

sv_import :: proc(ast: ^SystemVerilogAST, id: u32) -> SVImportView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_Import { return {} }
	return SVImportView{package_name = main.sv_text(ast, n.a), name = main.sv_text(ast, n.b)}
}

SVPortView :: struct {
	data:          u32,
	name:          string,
	iface_name:    string, // interface port (`axi_if.Slave bus`)
	modport:       string,
	unpacked_dims: []u32,
	expr:          u32, // explicit port expression `.P(expr)` / concatenated port
	default_value: u32,
	dir:           SVPortDir,
	net_type:      SVNetType,
}

sv_port :: proc(ast: ^SystemVerilogAST, id: u32) -> SVPortView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_Port { return {} }
	extra: SVPortExtra
	if n.c < ast.port_extra_count {
		#no_bounds_check extra = ast.port_extra_chunks[n.c >> SV_CHUNK_SHIFT][n.c & SV_CHUNK_MASK]
	}
	return SVPortView {
		data = n.a,
		name = main.sv_text(ast, n.b),
		iface_name = main.sv_text(ast, extra.iface_name),
		modport = main.sv_text(ast, extra.modport),
		unpacked_dims = main.sv_children(ast, n.span),
		expr = extra.expr,
		default_value = extra.default_value,
		dir = SVPortDir(n.flags & SVF_DIR_MASK),
		net_type = SVNetType((n.flags & SVF_NET_MASK) >> SVF_NET_SHIFT),
	}
}

SVPortConnView :: struct {
	name:  string, // "" for ordered connections
	value: u32, // SV_NONE for an unconnected port
}

sv_port_conn :: proc(ast: ^SystemVerilogAST, id: u32) -> SVPortConnView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_PortConn { return {} }
	return SVPortConnView{name = main.sv_text(ast, n.a), value = n.b}
}

SVParamAssignView :: struct {
	name:          string,
	unpacked_dims: []u32,
	value:         u32, // SV_NONE is legal in a parameter port list
	type_value:    u32, // Aux_DataType for `parameter type`
}

sv_param_assign :: proc(ast: ^SystemVerilogAST, id: u32) -> SVParamAssignView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_ParamAssign { return {} }
	return SVParamAssignView{name = main.sv_text(ast, n.a), unpacked_dims = main.sv_children(ast, n.span), value = n.b, type_value = n.c}
}

SVParamOverrideView :: struct {
	name:       string, // "" for ordered overrides
	value:      u32,
	type_value: u32,
}

sv_param_override :: proc(ast: ^SystemVerilogAST, id: u32) -> SVParamOverrideView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_ParamOverride { return {} }
	return SVParamOverrideView{name = main.sv_text(ast, n.a), value = n.b, type_value = n.c}
}

SVAssignPairView :: struct {
	lhs: u32,
	rhs: u32,
}

sv_assign_pair :: proc(ast: ^SystemVerilogAST, id: u32) -> SVAssignPairView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_AssignPair { return {} }
	return SVAssignPairView{lhs = n.a, rhs = n.b}
}

SVTFPortView :: struct {
	dir:           SVPortDir, // NONE when omitted (function inputs may omit it)
	data:          u32,
	name:          string,
	unpacked_dims: []u32,
	default_value: u32,
}

sv_tf_port :: proc(ast: ^SystemVerilogAST, id: u32) -> SVTFPortView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_TFPort { return {} }
	return SVTFPortView {
		dir = SVPortDir(n.flags & SVF_DIR_MASK),
		data = n.a,
		name = main.sv_text(ast, n.b),
		unpacked_dims = main.sv_children(ast, n.span),
		default_value = n.c,
	}
}

SVEventView :: struct {
	edge: SVEdgeKind,
	expr: u32,
	iff:  u32,
}

sv_event :: proc(ast: ^SystemVerilogAST, id: u32) -> SVEventView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_Event { return {} }
	return SVEventView{edge = SVEdgeKind(n.flags & 0x3), expr = n.a, iff = n.b}
}

SVCaseItemView :: struct {
	exprs:      []u32, // expression ids, or Aux_InsideRange ids for `case ... inside`
	is_default: bool,
	body:       u32,
}

sv_case_item :: proc(ast: ^SystemVerilogAST, id: u32) -> SVCaseItemView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_CaseItem { return {} }
	return SVCaseItemView{exprs = main.sv_children(ast, n.span), is_default = (n.flags & 0x1) != 0, body = n.a}
}

SVGenCaseItemView :: struct {
	exprs:      []u32,
	is_default: bool,
	body:       u32,
}

sv_gen_case_item :: proc(ast: ^SystemVerilogAST, id: u32) -> SVGenCaseItemView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_GenCaseItem { return {} }
	return SVGenCaseItemView{exprs = main.sv_children(ast, n.span), is_default = (n.flags & 0x1) != 0, body = n.a}
}

SVSelectPartView :: struct {
	member:     string, // non-empty: `.member` access, other fields unused
	kind:       SVSelectKind,
	first:      u32,
	second:     u32,
	has_second: bool,
}

sv_select_part :: proc(ast: ^SystemVerilogAST, id: u32) -> SVSelectPartView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_SelectPart { return {} }
	return SVSelectPartView {
		member = main.sv_text(ast, n.a),
		kind = SVSelectKind(n.flags & SVF_SELECT_KIND_MASK),
		first = n.b,
		second = n.c,
		has_second = (n.flags & SVF_SELECT_HAS_SECOND) != 0,
	}
}

SVCallArgView :: struct {
	name:  string, // named argument `.name(expr)`; "" when positional
	value: u32,
}

sv_call_arg :: proc(ast: ^SystemVerilogAST, id: u32) -> SVCallArgView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_CallArg { return {} }
	return SVCallArgView{name = main.sv_text(ast, n.a), value = n.b}
}

SVAggregateEntryView :: struct {
	key:   string, // "" for positional entries ("default" for default keys)
	value: u32,
}

sv_aggregate_entry :: proc(ast: ^SystemVerilogAST, id: u32) -> SVAggregateEntryView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_AggregateEntry { return {} }
	return SVAggregateEntryView{key = main.sv_text(ast, n.a), value = n.b}
}

SVInsideRangeView :: struct {
	lo:     u32,
	hi:     u32,
	has_hi: bool,
}

sv_inside_range :: proc(ast: ^SystemVerilogAST, id: u32) -> SVInsideRangeView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_InsideRange { return {} }
	return SVInsideRangeView{lo = n.a, hi = n.b, has_hi = (n.flags & 0x1) != 0}
}

SVModportPortView :: struct {
	dir:  SVPortDir,
	name: string,
}

sv_modport_port :: proc(ast: ^SystemVerilogAST, id: u32) -> SVModportPortView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_ModportPort { return {} }
	return SVModportPortView{dir = SVPortDir(n.flags & SVF_DIR_MASK), name = main.sv_text(ast, n.a)}
}

SVModportView :: struct {
	name:  string,
	ports: []u32,
}

sv_modport :: proc(ast: ^SystemVerilogAST, id: u32) -> SVModportView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_Modport { return {} }
	return SVModportView{name = main.sv_text(ast, n.a), ports = main.sv_children(ast, n.span)}
}

SVStructMemberView :: struct {
	data:        u32,
	declarators: []u32,
}

sv_struct_member :: proc(ast: ^SystemVerilogAST, id: u32) -> SVStructMemberView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_StructMember { return {} }
	return SVStructMemberView{data = n.a, declarators = main.sv_children(ast, n.span)}
}

SVEnumNameView :: struct {
	name:  string,
	value: u32,
}

sv_enum_name :: proc(ast: ^SystemVerilogAST, id: u32) -> SVEnumNameView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_EnumName { return {} }
	return SVEnumNameView{name = main.sv_text(ast, n.a), value = n.b}
}

SVTypeSpecView :: struct {
	kind:       SVTypeSpecKind,
	is_packed:  bool,
	base:       u32, // Aux_DataType for `enum logic [1:0] { ... }`
	members:    []u32, // Aux_StructMember
	enum_names: []u32, // Aux_EnumName
}

sv_type_spec :: proc(ast: ^SystemVerilogAST, id: u32) -> SVTypeSpecView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_TypeSpec { return {} }
	kind := SVTypeSpecKind(n.flags & SVF_TYPESPEC_KIND_MASK)
	span := main.sv_children(ast, n.span)
	return SVTypeSpecView {
		kind = kind,
		is_packed = (n.flags & SVF_TYPESPEC_PACKED) != 0,
		base = n.a,
		members = kind == .ENUM ? nil : span,
		enum_names = kind == .ENUM ? span : nil,
	}
}

SVTimingCtlView :: struct {
	is_delay:  bool,
	delay:     u32, // valid when is_delay
	events:    []u32,
	any_event: bool, // @* or @(*)
}

sv_timing_ctl :: proc(ast: ^SystemVerilogAST, id: u32) -> SVTimingCtlView {
	n := main.sv_node(ast, id)
	if n.kind != .Aux_TimingCtl { return {} }
	return SVTimingCtlView {
		is_delay = (n.flags & SVF_TIMING_DELAY) != 0,
		delay = n.a,
		events = main.sv_children(ast, n.span),
		any_event = (n.flags & SVF_TIMING_ANY) != 0,
	}
}

// ---- expression views ----------------------------------------------------------------

sv_expr_ident :: proc(ast: ^SystemVerilogAST, id: u32) -> (name: string, ok: bool) {
	if (id & SV_IMM_BIT) != 0 {
		if id & SV_IMM_SUB_MASK != SV_IMM_IDENT { return "", false }
		return main.sv_text(ast, id & SV_IMM_PAYLOAD_MASK), true
	}
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Ident { return "", false }
	return main.sv_text(ast, n.a), true
}

sv_expr_string :: proc(ast: ^SystemVerilogAST, id: u32) -> (text: string, ok: bool) {
	if (id & SV_IMM_BIT) != 0 {
		if id & SV_IMM_SUB_MASK != SV_IMM_STRING { return "", false }
		return main.sv_text(ast, id & SV_IMM_PAYLOAD_MASK), true
	}
	n := main.sv_node(ast, id)
	if n.kind != .Expr_String { return "", false }
	return main.sv_text(ast, n.a), true
}

sv_expr_scoped_name :: proc(ast: ^SystemVerilogAST, id: u32) -> (scope, name: string, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_ScopedName { return "", "", false }
	return main.sv_text(ast, n.a), main.sv_text(ast, n.b), true
}

sv_expr_select :: proc(ast: ^SystemVerilogAST, id: u32) -> (base: u32, parts: []u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Select { return SV_NONE, nil, false }
	return n.a, main.sv_children(ast, n.span), true
}

sv_expr_concat :: proc(ast: ^SystemVerilogAST, id: u32) -> (parts: []u32, count: u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Concat { return nil, SV_NONE, false }
	return main.sv_children(ast, n.span), n.a, true
}

sv_expr_stream :: proc(ast: ^SystemVerilogAST, id: u32) -> (dir: SVStreamDir, slice: u32, parts: []u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Stream { return .LEFT, SV_NONE, nil, false }
	dir_value := (n.flags & SVF_STREAM_RIGHT) != 0 ? SVStreamDir.RIGHT : SVStreamDir.LEFT
	return dir_value, n.a, main.sv_children(ast, n.span), true
}

sv_expr_unary :: proc(ast: ^SystemVerilogAST, id: u32) -> (op: SVUnOp, operand: u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Unary { return {}, SV_NONE, false }
	return SVUnOp(n.a), n.b, true
}

sv_expr_binary :: proc(ast: ^SystemVerilogAST, id: u32) -> (op: SVBinOp, lhs, rhs: u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Binary { return {}, SV_NONE, SV_NONE, false }
	return SVBinOp(n.a), n.b, n.c, true
}

sv_expr_ternary :: proc(ast: ^SystemVerilogAST, id: u32) -> (cond, then_expr, else_expr: u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Ternary { return SV_NONE, SV_NONE, SV_NONE, false }
	return n.a, n.b, n.c, true
}

sv_expr_inside :: proc(ast: ^SystemVerilogAST, id: u32) -> (subject: u32, ranges: []u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Inside { return SV_NONE, nil, false }
	return n.a, main.sv_children(ast, n.span), true
}

sv_expr_call :: proc(ast: ^SystemVerilogAST, id: u32) -> (name: string, is_system: bool, args: []u32, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Call { return "", false, nil, false }
	return main.sv_text(ast, n.a), (n.flags & SVF_CALL_SYSTEM) != 0, main.sv_children(ast, n.span), true
}

sv_expr_incdec :: proc(ast: ^SystemVerilogAST, id: u32) -> (operand: u32, is_dec, is_prefix, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_IncDec { return SV_NONE, false, false, false }
	return n.a, (n.flags & SVF_INCDEC_DEC) != 0, (n.flags & SVF_INCDEC_PREFIX) != 0, true
}

SVCastView :: struct {
	kind:    SVCastKind,
	target:  string, // SIGNING: "signed"/"unsigned"; TYPE: type name
	data:    u32, // TYPE: Aux_DataType
	size:    u32, // SIZE: expression
	operand: u32,
}

sv_expr_cast :: proc(ast: ^SystemVerilogAST, id: u32) -> (view: SVCastView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Cast { return {}, false }
	view.kind = SVCastKind(n.a)
	view.target = main.sv_text(ast, n.b)
	view.operand = n.c
	if (n.flags & SVF_CAST_HAS_DATA) != 0 {
		view.data = n.d
	} else if view.kind == .SIZE {
		view.size = n.d
	}
	return view, true
}

SVAggregateView :: struct {
	entries:    []u32,
	count:      u32, // replication count for `'{N{...}}`, SV_NONE otherwise
	type_name:  string, // typed assignment pattern `type_t'{...}`
	type_scope: string,
}

sv_expr_aggregate :: proc(ast: ^SystemVerilogAST, id: u32) -> (agg: SVAggregateView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Expr_Aggregate { return {}, false }
	return SVAggregateView{entries = main.sv_children(ast, n.span), count = n.c, type_name = main.sv_text(ast, n.a), type_scope = main.sv_text(ast, n.b)}, true
}

// Decoded numeric literal payload. Immediate small literals decode from
// ast.small_number_chunks; full-precision literals (x/z digits, reals, wide
// values) live in ast.number_chunks.
view_number :: proc(ast: ^SystemVerilogAST, id: u32) -> (number: SVNumber, ok: bool) {
	if (id & SV_IMM_BIT) != 0 {
		if id & SV_IMM_SUB_MASK != SV_IMM_NUMBER { return {}, false }
		index := id & SV_IMM_PAYLOAD_MASK
		if index >= ast.small_number_count { return {}, false }
		small: SVSmallNumber
		if index < SV_FIRST_SMALL {
			small = ast.first_small_numbers[index]
		} else {
			i := index - SV_FIRST_SMALL
			#no_bounds_check small = ast.small_number_chunks[i >> SV_CHUNK_SHIFT][i & SV_CHUNK_MASK]
		}
		number.value = small.value
		number.width = small.width
		number.base = small.base
		number.is_signed = small.is_signed
		number.time_unit = small.time_unit
		return number, true
	}
	n := main.sv_node(ast, id)
	#partial switch n.kind {
	case .Aux_NumberSmall:
		number.value = u64(n.a) | (u64(n.b) << 32)
		number.width = n.c
		number.base = SVNumberBase(n.flags & SVF_NUMBER_BASE_MASK)
		number.is_signed = (n.flags & SVF_NUMBER_SIGNED) != 0
		number.time_unit = SVTimeUnit((n.flags & SVF_NUMBER_UNIT_MASK) >> SVF_NUMBER_UNIT_SHIFT)
		return number, true
	case .Aux_NumberFull:
		if n.a < ast.number_count {
			#no_bounds_check return ast.number_chunks[n.a >> SV_CHUNK_SHIFT][n.a & SV_CHUNK_MASK], true
		}
		return {}, false
	}
	return {}, false
}

// ---- statement views -----------------------------------------------------------------

SVBlockView :: struct {
	label:   string,
	imports: []u32, // Aux_Import ids
	decls:   []u32, // Item_NetDecl / Item_ParamDecl / Item_TypeDecl ids
	stmts:   []u32,
}

sv_stmt_block :: proc(ast: ^SystemVerilogAST, id: u32) -> (block: SVBlockView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_Block { return {}, false }
	kids := main.sv_children(ast, n.span)
	total := len(kids)
	nd := int(min(n.d, u32(total)))
	block.label = main.sv_text(ast, n.a)
	if n.c > 0 {
		imports_start := int(n.b)
		block.imports = ast.imports[imports_start:imports_start + int(n.c)]
	}
	block.decls = kids[:nd]
	block.stmts = kids[nd:total]
	return block, true
}

// Generate blocks share Stmt_Block storage but only carry a label and items.
SVGenBlockView :: struct {
	label: string,
	items: []u32,
}

sv_gen_block :: proc(ast: ^SystemVerilogAST, id: u32) -> (block: SVGenBlockView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_Block { return {}, false }
	return SVGenBlockView{label = main.sv_text(ast, n.a), items = main.sv_children(ast, n.span)}, true
}

SVAssignStmtView :: struct {
	lhs:         u32,
	op:          SVAssignOp,
	rhs:         u32,
	nonblocking: bool, // <=
	timing:      u32, // intra-assignment delay/event control, SV_NONE when absent
}

sv_stmt_assign :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVAssignStmtView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_Assign { return {}, false }
	return SVAssignStmtView{lhs = n.a, op = SVAssignOp(n.b), rhs = n.c, nonblocking = (n.flags & SVF_ASSIGN_NONBLOCKING) != 0, timing = n.d}, true
}

SVIfView :: struct {
	qualifier: SVQualifier,
	cond:      u32,
	then_body: u32,
	else_body: u32, // SV_NONE when there is no else branch
}

sv_stmt_if :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVIfView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_If { return {}, false }
	return SVIfView{qualifier = SVQualifier(n.a), cond = n.b, then_body = n.c, else_body = n.d}, true
}

SVCaseView :: struct {
	kind:      SVCaseKind,
	qualifier: SVQualifier,
	subject:   u32,
	is_inside: bool, // case ( ... ) inside
	items:     []u32,
}

sv_stmt_case :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVCaseView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_Case { return {}, false }
	return SVCaseView {
			kind = SVCaseKind(n.flags & SVF_CASE_KIND_MASK),
			qualifier = SVQualifier((n.flags & SVF_CASE_QUAL_MASK) >> SVF_CASE_QUAL_SHIFT),
			subject = n.a,
			is_inside = (n.flags & SVF_CASE_INSIDE) != 0,
			items = main.sv_children(ast, n.span),
		},
		true
}

SVForView :: struct {
	var_decls:    []u32, // Item_NetDecl ids (`for (int i = 0, ...)`)
	init_assigns: []u32, // Stmt_Assign ids
	cond:         u32, // SV_NONE for `for (;;)`
	steps:        []u32,
	body:         u32,
}

sv_stmt_for :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVForView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_For { return {}, false }
	kids := main.sv_children(ast, n.span)
	total := len(kids)
	nd := int(min(n.c, u32(total)))
	ni := int(min(n.d, u32(total - nd)))
	stmt.var_decls = kids[:nd]
	stmt.init_assigns = kids[nd:nd + ni]
	stmt.steps = kids[nd + ni:total]
	stmt.cond = n.a
	stmt.body = n.b
	return stmt, true
}

SVWhileView :: struct {
	do_while: bool,
	cond:     u32,
	body:     u32,
}

sv_stmt_while :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVWhileView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_While { return {}, false }
	return SVWhileView{do_while = (n.flags & SVF_WHILE_DO) != 0, cond = n.a, body = n.b}, true
}

SVForeachView :: struct {
	array:     u32,
	loop_vars: []string, // "" for an omitted index
	body:      u32,
}

sv_stmt_foreach :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVForeachView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_Foreach { return {}, false }
	kids := main.sv_children(ast, n.span)
	// Loop variables are Aux_Str ids; materialize them into the caller's temp
	// allocator so the view is convenient to iterate.
	vars := make([]string, len(kids), context.temp_allocator)
	for kid, i in kids { vars[i] = main.sv_text_of(ast, kid) }
	return SVForeachView{array = n.a, loop_vars = vars, body = n.b}, true
}

SVAssertView :: struct {
	kind:          SVAssertKind,
	is_property:   bool,
	cond:          u32, // immediate assertion condition
	property_text: string, // raw property/sequence text (not part of the synth subset)
	pass_body:     u32,
	else_body:     u32,
}

sv_stmt_assert :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVAssertView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_Assert { return {}, false }
	stmt.kind = SVAssertKind(n.flags & SVF_ASSERT_KIND_MASK)
	stmt.is_property = (n.flags & SVF_ASSERT_PROPERTY) != 0
	if stmt.is_property {
		stmt.property_text = main.sv_text(ast, n.a)
	} else {
		stmt.cond = n.a
	}
	stmt.pass_body = n.b
	stmt.else_body = n.c
	return stmt, true
}

SVJumpView :: struct {
	kind:  SVJumpKind,
	value: u32, // return value, SV_NONE when absent
}

sv_stmt_jump :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVJumpView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Stmt_Jump { return {}, false }
	return SVJumpView{kind = SVJumpKind(n.a), value = n.b}, true
}

// ---- item views ----------------------------------------------------------------------

SVProcView :: struct {
	kind:      SVProcKind,
	events:    []u32, // sensitivity list hoisted from @( ... )
	any_event: bool, // always @* / @(*)
	body:      u32,
}

sv_item_proc :: proc(ast: ^SystemVerilogAST, id: u32) -> (proc_view: SVProcView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_Proc { return {}, false }
	return SVProcView{kind = SVProcKind(n.a), events = main.sv_children(ast, n.span), any_event = (n.flags & SVF_PROC_ANY_EVENT) != 0, body = n.b}, true
}

SVSubroutineView :: struct {
	is_task:      bool,
	is_automatic: bool,
	return_data:  u32, // Aux_DataType, VOID for tasks and void functions
	name:         string,
	ports:        []u32,
	body:         u32, // Stmt_Block
}

sv_item_subroutine :: proc(ast: ^SystemVerilogAST, id: u32) -> (sub: SVSubroutineView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_Subroutine { return {}, false }
	return SVSubroutineView {
			is_task = (n.flags & SVF_SUB_TASK) != 0,
			is_automatic = (n.flags & SVF_SUB_AUTOMATIC) != 0,
			return_data = n.b,
			name = main.sv_text(ast, n.a),
			ports = main.sv_children(ast, n.span),
			body = n.c,
		},
		true
}

SVNetDeclView :: struct {
	data:        u32,
	declarators: []u32,
	net_type:    SVNetType, // NONE for variable declarations
}

sv_item_net_decl :: proc(ast: ^SystemVerilogAST, id: u32) -> (decl: SVNetDeclView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_NetDecl { return {}, false }
	return SVNetDeclView{data = n.a, declarators = main.sv_children(ast, n.span), net_type = SVNetType(n.flags & 0xF)}, true
}

SVParamDeclView :: struct {
	data:        u32,
	assignments: []u32,
	is_local:    bool, // localparam
	is_type:     bool, // `parameter type T = ...`
}

sv_item_param_decl :: proc(ast: ^SystemVerilogAST, id: u32) -> (decl: SVParamDeclView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_ParamDecl { return {}, false }
	return SVParamDeclView {
			data = n.a,
			assignments = main.sv_children(ast, n.span),
			is_local = (n.flags & SVF_PARAM_LOCAL) != 0,
			is_type = (n.flags & SVF_PARAM_TYPE) != 0,
		},
		true
}

SVTypeDeclView :: struct {
	name:          string,
	data:          u32,
	unpacked_dims: []u32,
	is_forward:    bool,
}

sv_item_type_decl :: proc(ast: ^SystemVerilogAST, id: u32) -> (decl: SVTypeDeclView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_TypeDecl { return {}, false }
	return SVTypeDeclView {
			name = main.sv_text(ast, n.a),
			data = n.b,
			unpacked_dims = main.sv_children(ast, n.span),
			is_forward = (n.flags & SVF_TYPE_FORWARD) != 0,
		},
		true
}

SVInstanceView :: struct {
	cell_name:       string,
	is_gate:         bool, // gate primitive (and/or/buf/...): delays are legal, name optional
	param_overrides: []u32,
	name:            string, // "" for nameless gate instances
	unpacked_dims:   []u32, // instance array dimensions
	port_conns:      []u32,
	wildcard_ports:  bool, // .*
}

sv_item_instance :: proc(ast: ^SystemVerilogAST, id: u32) -> (inst: SVInstanceView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_Instance { return {}, false }
	kids := main.sv_children(ast, n.span)
	total := len(kids)
	np := int(min(n.c, u32(total)))
	nd := int(min(n.d, u32(total - np)))
	return SVInstanceView {
			cell_name = main.sv_text(ast, n.a),
			is_gate = (n.flags & SVF_INSTANCE_GATE) != 0,
			param_overrides = kids[:np],
			name = main.sv_text(ast, n.b),
			unpacked_dims = kids[np:np + nd],
			port_conns = kids[np + nd:total],
			wildcard_ports = (n.flags & SVF_INSTANCE_WILDCARD) != 0,
		},
		true
}

SVGenRegionView :: struct {
	label: string, // "" for an explicit generate ... endgenerate region
	items: []u32,
}

sv_item_gen_region :: proc(ast: ^SystemVerilogAST, id: u32) -> (region: SVGenRegionView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_GenRegion { return {}, false }
	return SVGenRegionView{label = main.sv_text(ast, n.a), items = main.sv_children(ast, n.span)}, true
}

SVGenLoopView :: struct {
	var:  string, // genvar name
	init: u32,
	cond: u32,
	step: u32,
	body: u32,
}

sv_item_gen_loop :: proc(ast: ^SystemVerilogAST, id: u32) -> (loop: SVGenLoopView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_GenLoop { return {}, false }
	kids := main.sv_children(ast, n.span)
	body := len(kids) > 0 ? kids[0] : SV_NONE
	return SVGenLoopView{var = main.sv_text(ast, n.a), init = n.b, cond = n.c, step = n.d, body = body}, true
}

SVGenIfView :: struct {
	cond:     u32,
	then_blk: u32,
	else_blk: u32, // SV_NONE when there is no else branch
}

sv_item_gen_if :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVGenIfView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_GenIf { return {}, false }
	return SVGenIfView{cond = n.a, then_blk = n.b, else_blk = n.c}, true
}

SVGenCaseView :: struct {
	kind:    SVCaseKind,
	subject: u32,
	items:   []u32,
}

sv_item_gen_case :: proc(ast: ^SystemVerilogAST, id: u32) -> (stmt: SVGenCaseView, ok: bool) {
	n := main.sv_node(ast, id)
	if n.kind != .Item_GenCase { return {}, false }
	return SVGenCaseView{kind = SVCaseKind(n.a), subject = n.b, items = main.sv_children(ast, n.span)}, true
}

