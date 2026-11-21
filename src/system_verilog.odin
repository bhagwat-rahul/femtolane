/*
Femtolane SystemVerilog frontend, stage 1: source text -> typed AST.

The frontend is split into four small layers:

  system_verilog_tokenizer.odin     raw ASCII tokenizer, token layout, keyword lookup
  system_verilog_preprocessor.odin  `define/`ifdef/`include and macro expansion
  system_verilog_parser.odin        hand-written recursive descent over tokens
  this file                         AST types and the public entry points

There is no token buffer in the parser and no grammar file: the preprocessor
produces a flat token array once, and every parser function indexes it.

The AST is data-oriented and flat:

  - Every syntax node lives in a flat, chunked node store addressed by a u32 id
    (SV_NONE is the null id). Chunks are fixed-size and never move, so appending
    cannot invalidate an id or a node pointer. There are no `^SV...` links in
    the tree.
  - Child lists are `SVSpan {start,len}` slices of a shared child-id buffer
    (`kids`). A node therefore never owns a dynamic array or a pointer.
  - Identifier, string-literal and small-number leaves are tagged immediate ids
    in the u32 payload, so the dominant RTL leaves do not allocate a node.
  - Identifier and literal text stays zero-copy: `strings` stores the original
    source (or arena-owned macro expansion) slices.
  - Modules, packages and interfaces are small structs stored contiguously;
    their maps store u32 indices, not pointers.

The node struct is a tagged record with four u32 payload words plus one child
span. Each kind documents its layout in the comment above it, and the `sv_*`
view helpers below give callers named fields without exposing raw slots. The
few records with more fields (ports, full-precision numbers) keep them in side
payload chunks indexed from the node.

Scope is the ASIC-synthesizable RTL subset plus the pragmatic leniency needed by
real vendor RTL (trailing commas, attributes, escaped identifiers, empty
concatenations, queue-style method calls, etc.).
*/

package main

import "core:fmt"
import "core:mem"
import "core:os"
import "file_picker"

// ---------------------------------------------------------------------------------------
// AST storage
// ---------------------------------------------------------------------------------------

// Null id for every ID slot (node ids, child lists, string refs).
SV_NONE :: u32(0xFFFF_FFFF)

// Identifier, string-literal and small-number expressions are encoded directly
// in the u32 id instead of taking a node slot. The top bit tags an immediate;
// the next two bits select the payload table and the low 29 bits are the index.
// This keeps the dominant RTL leaves at 4 bytes in a child list plus their
// string/number payload, with no SVNode header.
SV_IMM_BIT :: u32(0x8000_0000)
SV_IMM_SUB_MASK :: u32(0x6000_0000)
SV_IMM_SUB_SHIFT :: u32(29)
SV_IMM_PAYLOAD_MASK :: u32(0x1FFF_FFFF)
SV_IMM_IDENT :: u32(0)
SV_IMM_STRING :: u32(1) << SV_IMM_SUB_SHIFT
SV_IMM_NUMBER :: u32(2) << SV_IMM_SUB_SHIFT

sv_imm :: #force_inline proc(subtype, payload: u32) -> u32 {
	return SV_IMM_BIT | subtype | (payload & SV_IMM_PAYLOAD_MASK)
}

sv_is_imm :: #force_inline proc(id: u32) -> bool { return (id & SV_IMM_BIT) != 0 }

// A contiguous slice of the shared child-id buffer. Nodes store spans, never
// per-node child arrays.
SVSpan :: struct {
	start: u32,
	len:   u32,
}

SVNodeKind :: enum u16 {
	None,

	// ---- auxiliary records (also children, so every list is uniform) -------------
	Aux_Str, // a = string ref
	Aux_NumberSmall, // synthesized for SV_IMM_NUMBER; payload lives in ast.small_number_chunks
	Aux_NumberFull, // a = index into ast.number_chunks
	Aux_DataType, // a = type name ref, b = type scope ref, c = spec, flags = var_type|signed, span = packed dims
	Aux_Range, // a = msb, b = lsb, flags = is_size
	Aux_Declarator, // a = name ref, b = init, span = unpacked dims
	Aux_Import, // a = package ref, b = imported name ref ("*" for wildcard)
	Aux_Port, // a = data, b = name ref, c = port-extras index (iface/modport/expr/default), flags = dir|net, span = dims
	Aux_PortConn, // a = name ref, b = value
	Aux_ParamAssign, // a = name ref, b = value, c = type value, span = unpacked dims
	Aux_ParamOverride, // a = name ref, b = value, c = type value
	Aux_AssignPair, // a = lhs, b = rhs
	Aux_TFPort, // a = data, b = name ref, c = default, flags = dir, span = dims
	Aux_Event, // a = expr, b = iff, flags = edge
	Aux_CaseItem, // a = body, flags = is_default, span = exprs or inside ranges
	Aux_GenCaseItem, // a = body, flags = is_default, span = exprs
	Aux_SelectPart, // a = member ref, b = first, c = second, flags = kind|has_second
	Aux_CallArg, // a = name ref, b = value
	Aux_AggregateEntry, // a = key ref, b = value
	Aux_InsideRange, // a = lo, b = hi, flags = has_hi
	Aux_Modport, // a = name ref, span = ports
	Aux_ModportPort, // a = name ref, flags = dir
	Aux_StructMember, // a = data, span = declarators
	Aux_EnumName, // a = name ref, b = value
	Aux_TypeSpec, // a = base data, flags = kind|packed, span = members or enum names
	Aux_TimingCtl, // a = delay, flags = is_delay|any_event, span = events

	// ---- expressions -------------------------------------------------------------
	Expr_Ident, // a = name ref
	Expr_String, // a = string ref
	Expr_ScopedName, // a = scope ref, b = name ref
	Expr_Select, // a = base, span = select parts
	Expr_Concat, // a = replication count (SV_NONE for plain), span = parts
	Expr_Stream, // a = slice size, flags = direction, span = parts
	Expr_Unary, // a = op, b = operand
	Expr_Binary, // a = op, b = lhs, c = rhs
	Expr_Ternary, // a = cond, b = then, c = else
	Expr_Inside, // a = subject, span = inside ranges
	Expr_Call, // a = name ref, flags = is_system, span = args
	Expr_IncDec, // a = operand, flags = is_dec|is_prefix
	Expr_Cast, // a = kind, b = target ref, c = operand, d = data/size, flags = has_data
	Expr_Aggregate, // a = type name ref, b = type scope ref, c = count, span = entries

	// ---- statements --------------------------------------------------------------
	Stmt_Block, // a = label ref, b/c = imports span into ast.imports, d = decl count, span = decls ++ stmts
	Stmt_Assign, // a = lhs, b = op, c = rhs, d = timing, flags = nonblocking
	Stmt_If, // a = qualifier, b = cond, c = then, d = else
	Stmt_Case, // a = subject, flags = kind|qualifier|inside, span = items
	Stmt_For, // a = cond, b = body, c = decl count, d = init count, span = decls ++ inits ++ steps
	Stmt_While, // a = cond, b = body, flags = do_while
	Stmt_Repeat, // a = count, b = body
	Stmt_Forever, // a = body
	Stmt_Foreach, // a = array, b = body, span = loop var name refs
	Stmt_Timing, // a = timing control, b = body
	Stmt_Assert, // a = cond or property text ref, b = pass body, c = else body, flags = kind|is_property
	Stmt_Jump, // a = kind, b = value

	// ---- module/package/interface items -----------------------------------------
	Item_PortDecl, // a = dir, b = net declaration
	Item_NetDecl, // a = data, flags = net type, span = declarators
	Item_ParamDecl, // a = data, flags = is_local|is_type, span = assignments
	Item_TypeDecl, // a = name ref, b = data, flags = is_forward, span = unpacked dims
	Item_GenvarDecl, // span = name refs
	Item_ContAssign, // span = assignment pairs
	Item_Alias, // span = expressions
	Item_Defparam, // span = assignment pairs
	Item_Instance, // a = cell ref, b = name ref, c = param count, d = dim count, flags = gate|wildcard, span = params ++ dims ++ conns
	Item_Proc, // a = kind, b = body, flags = any_event, span = events
	Item_Subroutine, // a = name ref, b = return data, c = body, flags = task|automatic, span = ports
	Item_GenRegion, // a = label ref, span = items
	Item_GenLoop, // a = var ref, b = init, c = cond, d = step, span = [body]
	Item_GenIf, // a = cond, b = then block, c = else block
	Item_GenCase, // a = kind, b = subject, span = items
}

// A flat AST node. Payload slots are interpreted by `kind`; see the comments in
// SVNodeKind. Nodes never contain pointers or owned lists. Nodes are packed in
// fixed-size chunks addressed by a flat u32 id (SV_CHUNK_SHIFT below).
SVNode :: struct {
	kind:  SVNodeKind,
	flags: u16,
	a:     u32,
	b:     u32,
	c:     u32,
	d:     u32,
	span:  SVSpan,
}

// One `define. The body is raw replacement text; function-like macros also carry their
// formal parameter names so invocations can substitute arguments.
SVDefine :: struct {
	body:             string,
	params:           [dynamic]string,
	param_defaults:   [dynamic]string, // parallel to params; "" when no default
	is_function_like: bool,
	body_owned:       bool, // body points into the preprocessor arena
}

// Source trivia retained for debuggers, waveform viewers, and physical-design
// annotation passes. Text points into the same arena-owned source bytes as the
// rest of the AST; comments and attributes are rare, so keeping them in side
// arrays avoids adding a field to every AST node.
SVComment :: struct {
	text:     string, // includes the // or /* */ delimiters
	path:     string,
	line:     u32,
	is_block: bool,
}

SVAttribute :: struct {
	text:       string, // raw (* ... *) text
	path:       string,
	line:       u32, // line containing the attribute
	owner_line: u32, // line of the construct that follows it
}

// One source buffer owned by the preprocessor: the original file, an include, or
// macro-expanded text. Token file ids index an array of these.
SVSource :: struct {
	data:      []byte,
	line_base: u32,
	path:      string,
}

SystemVerilogAST :: struct {
	// Flat node graph shared by expressions, statements, items and records.
	// Large payloads are stored in stable fixed-size chunks addressed by a flat
	// u32 id: growth never copies or moves an existing node, which keeps arena
	// use close to the live size and makes node pointers stable while parsing.
	node_chunks:         [dynamic][]SVNode,
	node_count:          u32,
	first_nodes:         [SV_FIRST_NODE]SVNode,
	kids:                [dynamic]u32, // child-id buffer; every SVSpan indexes this
	string_chunks:       [dynamic][]string,
	string_count:        u32,
	first_strings:       [SV_FIRST_STRING]string,
	number_chunks:       [dynamic][]SVNumber,
	number_count:        u32,
	small_number_chunks: [dynamic][]SVSmallNumber,
	small_number_count:  u32,
	first_small_numbers: [SV_FIRST_SMALL]SVSmallNumber,
	port_extra_chunks:   [dynamic][]SVPortExtra,
	port_extra_count:    u32,
	modules:             [dynamic]SVModule,
	module_hash_map:     map[string]u32, // name -> modules index, also duplicate detection
	packages:            [dynamic]SVPackage,
	package_hash_map:    map[string]u32,
	interfaces:          [dynamic]SVInterface,
	interface_hash_map:  map[string]u32,
	items:               SVSpan, // compilation-unit items (top-level typedefs, tasks, ...)
	unit_imports:        SVSpan, // compilation-unit imports, into ast.imports
	ports:               [dynamic]u32, // port nodes; module/interface `ports` spans index this
	imports:             [dynamic]u32, // import nodes; owner `imports` spans index this
	type_names:          map[string]bool, // typedefs seen so far; disambiguates `name x;`
	iface_names:         map[string]bool, // interface names, usable as port/declaration types
	defines:             map[string]SVDefine, // `define table (conditional compilation + expansion)
	include_dirs:        [dynamic]string, // extra `include paths, after the includer's dir
	file_dirs:           [dynamic]string, // parsed file dirs (fallback for flattened trees)
	comments:            [dynamic]SVComment,
	attributes:          [dynamic]SVAttribute,
}

// Extra Aux_Port fields. The port node keeps data/name/dims inline; interface
// names, modport and the optional expressions live here.
SVPortExtra :: struct {
	iface_name:    u32,
	modport:       u32,
	expr:          u32,
	default_value: u32,
}

SVModule :: struct {
	name:           string,
	is_ansi:        bool,
	wildcard_ports: bool, // module m (.*);
	imports:        SVSpan, // into ast.imports
	ports:          SVSpan, // into ast.ports
	params:         SVSpan, // into ast.kids (Item_ParamDecl nodes)
	items:          SVSpan, // into ast.kids
}

SVPackage :: struct {
	name:    string,
	imports: SVSpan, // into ast.imports
	items:   SVSpan, // into ast.kids
}

SVInterface :: struct {
	name:     string,
	imports:  SVSpan, // into ast.imports
	params:   SVSpan, // into ast.kids
	ports:    SVSpan, // into ast.ports
	items:    SVSpan, // into ast.kids
	modports: SVSpan, // into ast.kids
}

// ---- enums -----------------------------------------------------------------------------

SVPortDir :: enum u8 {
	NONE,
	INPUT,
	OUTPUT,
	INOUT,
	REF,
}

SVNetType :: enum u8 {
	NONE, // variable declaration / no explicit net type
	WIRE,
	TRI,
	WAND,
	WOR,
	TRIAND,
	TRIOR,
	TRI0,
	TRI1,
	TRIREG,
	SUPPLY0,
	SUPPLY1,
	UWIRE,
}

SVVarType :: enum u8 {
	IMPLICIT, // no type keyword, e.g. `[3:0] x;`
	LOGIC,
	BIT,
	REG,
	INT,
	INTEGER,
	SHORTINT,
	LONGINT,
	BYTE,
	TIME,
	REAL,
	SHORTREAL,
	REALTIME,
	STRING, // parameter/typedef type; parsed for completeness
	VOID, // function/task return only
}

SVTypeSpecKind :: enum u8 {
	ENUM,
	STRUCT,
	UNION,
}

SVEdgeKind :: enum u8 {
	NONE,
	POSEDGE,
	NEGEDGE,
	EDGE,
}

SVProcKind :: enum u8 {
	INITIAL,
	FINAL,
	ALWAYS,
	ALWAYS_COMB,
	ALWAYS_FF,
	ALWAYS_LATCH,
}

SVAssignOp :: enum u8 {
	EQ,
	ADD_EQ,
	SUB_EQ,
	MUL_EQ,
	DIV_EQ,
	MOD_EQ,
	AND_EQ,
	OR_EQ,
	XOR_EQ,
	SHL_EQ,
	SHR_EQ,
	ASH_L_EQ,
	ASH_R_EQ,
}

SVQualifier :: enum u8 {
	NONE,
	UNIQUE,
	UNIQUE0,
	PRIORITY,
}

SVCaseKind :: enum u8 {
	CASE,
	CASEZ,
	CASEX,
}

SVAssertKind :: enum u8 {
	ASSERT,
	ASSUME,
	COVER,
	EXPECT,
}

SVJumpKind :: enum u8 {
	BREAK,
	CONTINUE,
	RETURN,
}

SVTimeUnit :: enum u8 {
	NONE,
	S,
	MS,
	US,
	NS,
	PS,
	FS,
}

SVNumberBase :: enum u8 {
	DEC,
	BIN,
	OCT,
	HEX,
}

// Compact payload for immediate small literals. Values are decoded into SVNumber
// by sv_number; the table is never exposed as AST nodes.
SVSmallNumber :: struct {
	value:     u64,
	width:     u32,
	base:      SVNumberBase,
	is_signed: bool,
	time_unit: SVTimeUnit,
}

// Decoded numeric literal. Full-precision literals live in ast.number_chunks;
// immediate small literals decode from ast.small_number_chunks on demand.
SVNumber :: struct {
	raw:        string, // digit text, points into the source bytes ("" for small literals)
	width:      u32, // explicit size; 0 = unsized
	base:       SVNumberBase,
	is_signed:  bool,
	is_unbased: bool, // '0 '1 'x 'z
	is_real:    bool,
	real_value: f64,
	value:      u64, // decoded low 64 bits; raw keeps the full text for wider literals
	has_x_z:    bool,
	time_unit:  SVTimeUnit, // NONE for ordinary literals
}

SVSelectKind :: enum u8 {
	BIT,
	PART,
	INDEXED_PLUS,
	INDEXED_MINUS,
}

SVStreamDir :: enum u8 {
	LEFT,
	RIGHT,
}

SVCastKind :: enum u8 {
	SIGNING,
	TYPE,
	SIZE,
}

SVUnOp :: enum u8 {
	PLUS,
	MINUS,
	NOT,
	BIT_NOT,
	RED_AND,
	RED_NAND,
	RED_OR,
	RED_NOR,
	RED_XOR,
	RED_XNOR,
}

SVBinOp :: enum u8 {
	POW,
	MUL,
	DIV,
	MOD,
	ADD,
	SUB,
	SHL,
	SHR,
	ASH_L,
	ASH_R,
	LT,
	LE,
	GT,
	GE,
	EQ,
	NE,
	CASE_EQ,
	CASE_NE,
	WILD_EQ,
	WILD_NE,
	BIT_AND,
	BIT_XOR,
	BIT_XNOR,
	BIT_OR,
	LOG_AND,
	LOG_OR,
}

// ---- flags -----------------------------------------------------------------------------

@(private)
SVF_NUMBER_BASE_MASK :: u16(0x3)
@(private)
SVF_NUMBER_SIGNED :: u16(0x4)
@(private)
SVF_NUMBER_UNIT_SHIFT :: u16(3)
@(private)
SVF_NUMBER_UNIT_MASK :: u16(0x38)

@(private)
SVF_DATA_VARTYPE_MASK :: u16(0xF)
@(private)
SVF_DATA_SIGNED :: u16(0x10)

@(private)
SVF_RANGE_IS_SIZE :: u16(0x1)

@(private)
SVF_DIR_MASK :: u16(0x7)
@(private)
SVF_NET_SHIFT :: u16(3)
@(private)
SVF_NET_MASK :: u16(0x78)

@(private)
SVF_CASE_KIND_MASK :: u16(0x3)
@(private)
SVF_CASE_QUAL_SHIFT :: u16(2)
@(private)
SVF_CASE_QUAL_MASK :: u16(0xC)
@(private)
SVF_CASE_INSIDE :: u16(0x10)

@(private)
SVF_ASSERT_KIND_MASK :: u16(0x3)
@(private)
SVF_ASSERT_PROPERTY :: u16(0x4)

@(private)
SVF_SELECT_KIND_MASK :: u16(0x3)
@(private)
SVF_SELECT_HAS_SECOND :: u16(0x4)

@(private)
SVF_TYPESPEC_KIND_MASK :: u16(0x3)
@(private)
SVF_TYPESPEC_PACKED :: u16(0x4)

@(private)
SVF_TIMING_DELAY :: u16(0x1)
@(private)
SVF_TIMING_ANY :: u16(0x2)

@(private)
SVF_STREAM_RIGHT :: u16(0x1)

@(private)
SVF_INCDEC_DEC :: u16(0x1)
@(private)
SVF_INCDEC_PREFIX :: u16(0x2)

@(private)
SVF_CALL_SYSTEM :: u16(0x1)

@(private)
SVF_CAST_HAS_DATA :: u16(0x1)

@(private)
SVF_ASSIGN_NONBLOCKING :: u16(0x1)

@(private)
SVF_WHILE_DO :: u16(0x1)

@(private)
SVF_PROC_ANY_EVENT :: u16(0x1)

@(private)
SVF_INSTANCE_GATE :: u16(0x1)
@(private)
SVF_INSTANCE_WILDCARD :: u16(0x2)

@(private)
SVF_PARAM_LOCAL :: u16(0x1)
@(private)
SVF_PARAM_TYPE :: u16(0x2)

@(private)
SVF_TYPE_FORWARD :: u16(0x1)

@(private)
SVF_SUB_TASK :: u16(0x1)
@(private)
SVF_SUB_AUTOMATIC :: u16(0x2)

// ---------------------------------------------------------------------------------------
// Node access helpers
// ---------------------------------------------------------------------------------------

// Chunk size is a power of two so the chunk/offset split is a shift and a mask.
SV_CHUNK_SHIFT :: 8
SV_CHUNK_SIZE :: 1 << SV_CHUNK_SHIFT
SV_CHUNK_MASK :: SV_CHUNK_SIZE - 1
// Tiny files fit entirely in these inline first pages; larger files switch to
// the chunked stores after the first page.
SV_FIRST_NODE :: 16
SV_FIRST_STRING :: 16
SV_FIRST_SMALL :: 16

sv_node :: #force_inline proc(ast: ^SystemVerilogAST, id: u32) -> SVNode {
	if (id & SV_IMM_BIT) != 0 {
		switch id & SV_IMM_SUB_MASK {
		case SV_IMM_IDENT: return SVNode{kind = .Expr_Ident, a = id & SV_IMM_PAYLOAD_MASK}
		case SV_IMM_STRING: return SVNode{kind = .Expr_String, a = id & SV_IMM_PAYLOAD_MASK}
		case SV_IMM_NUMBER: return SVNode{kind = .Aux_NumberSmall, a = id & SV_IMM_PAYLOAD_MASK}
		}
	}
	if id == SV_NONE || id >= ast.node_count { return {} }
	if id < SV_FIRST_NODE { return ast.first_nodes[id] }
	idx := id - SV_FIRST_NODE
	return ast.node_chunks[idx >> SV_CHUNK_SHIFT][idx & SV_CHUNK_MASK]
}

sv_node_kind :: #force_inline proc(ast: ^SystemVerilogAST, id: u32) -> SVNodeKind {
	return sv_node(ast, id).kind
}

sv_children :: #force_inline proc(ast: ^SystemVerilogAST, span: SVSpan) -> []u32 {
	if span.len == 0 { return nil }
	return ast.kids[span.start:span.start + span.len]
}

sv_text :: #force_inline proc(ast: ^SystemVerilogAST, ref: u32) -> string {
	if ref == SV_NONE || ref == 0 || ref >= ast.string_count { return "" }
	if ref < SV_FIRST_STRING { return ast.first_strings[ref] }
	idx := ref - SV_FIRST_STRING
	return ast.string_chunks[idx >> SV_CHUNK_SHIFT][idx & SV_CHUNK_MASK]
}

sv_module :: #force_inline proc(ast: ^SystemVerilogAST, index: u32) -> SVModule {
	if index == SV_NONE || int(index) >= len(ast.modules) { return {} }
	return ast.modules[index]
}

sv_package :: #force_inline proc(ast: ^SystemVerilogAST, index: u32) -> SVPackage {
	if index == SV_NONE || int(index) >= len(ast.packages) { return {} }
	return ast.packages[index]
}

sv_interface :: #force_inline proc(ast: ^SystemVerilogAST, index: u32) -> SVInterface {
	if index == SV_NONE || int(index) >= len(ast.interfaces) { return {} }
	return ast.interfaces[index]
}

sv_unit_imports :: #force_inline proc(ast: ^SystemVerilogAST) -> []u32 {
	if ast.unit_imports.len == 0 { return nil }
	return ast.imports[ast.unit_imports.start:ast.unit_imports.start + ast.unit_imports.len]
}

sv_module_items :: #force_inline proc(ast: ^SystemVerilogAST, module: SVModule) -> []u32 {
	return sv_children(ast, module.items)
}

sv_module_ports :: #force_inline proc(ast: ^SystemVerilogAST, module: SVModule) -> []u32 {
	if module.ports.len == 0 { return nil }
	return ast.ports[module.ports.start:module.ports.start + module.ports.len]
}

sv_module_params :: #force_inline proc(ast: ^SystemVerilogAST, module: SVModule) -> []u32 {
	return sv_children(ast, module.params)
}

sv_module_imports :: #force_inline proc(ast: ^SystemVerilogAST, module: SVModule) -> []u32 {
	if module.imports.len == 0 { return nil }
	return ast.imports[module.imports.start:module.imports.start + module.imports.len]
}

sv_interface_ports :: #force_inline proc(ast: ^SystemVerilogAST, iface: SVInterface) -> []u32 {
	if iface.ports.len == 0 { return nil }
	return ast.ports[iface.ports.start:iface.ports.start + iface.ports.len]
}

sv_interface_modports :: #force_inline proc(ast: ^SystemVerilogAST, iface: SVInterface) -> []u32 {
	return sv_children(ast, iface.modports)
}

sv_text_of :: #force_inline proc(ast: ^SystemVerilogAST, id: u32) -> string {
	n := sv_node(ast, id)
	return sv_text(ast, n.a)
}

// ---------------------------------------------------------------------------------------
// Paths and numeric helpers
// ---------------------------------------------------------------------------------------

sv_path_directory :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' { return path[:i] }
	}
	return ""
}

sv_path_basename :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' { return path[i + 1:] }
	}
	return path
}

sv_path_is_absolute :: proc(path: string) -> bool {
	if len(path) == 0 { return false }
	if path[0] == '/' || path[0] == '\\' { return true }
	return len(path) > 2 && path[1] == ':'
}

sv_is_decimal_digit :: #force_inline proc(c: byte) -> bool { return c >= '0' && c <= '9' }

sv_number_base_of :: #force_inline proc(c: byte) -> SVNumberBase {
	switch c {
	case 'b', 'B': return .BIN
	case 'o', 'O': return .OCT
	case 'd', 'D': return .DEC
	case: return .HEX
	}
}

sv_digit_value_lut: [256]u8

@(init)
sv_digit_value_init :: proc "contextless" () {
	for i in 0 ..< 256 {
		c := u8(i)
		switch {
		case c >= '0' && c <= '9': sv_digit_value_lut[i] = c - '0'
		case c >= 'a' && c <= 'f': sv_digit_value_lut[i] = c - 'a' + 10
		case c >= 'A' && c <= 'F': sv_digit_value_lut[i] = c - 'A' + 10
		case c == 'x' || c == 'X' || c == 'z' || c == 'Z' || c == '?': sv_digit_value_lut[i] = 16
		case c == '_': sv_digit_value_lut[i] = 17
		case: sv_digit_value_lut[i] = 255
		}
	}
}

sv_decode_number :: proc(digits: string, base: SVNumberBase) -> (value: u64, has_x_z: bool) {
	radix: u64 = 10
	switch base {
	case .BIN: radix = 2
	case .OCT: radix = 8
	case .DEC: radix = 10
	case .HEX: radix = 16
	}
	for c in digits {
		d := sv_digit_value_lut[c]
		if d < 16 {
			value = value * radix + u64(d)
		} else if d == 16 {
			has_x_z = true
		}
	}
	return
}

// ---------------------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------------------

// The AST containers are ordinary dynamic arrays/maps; a zero value is valid and takes
// its allocator on first append/insert. This entry point is kept for source compatibility.
system_verilog_ast_init :: proc(_: ^SystemVerilogAST, _: mem.Allocator) {  }

// Parse one file into the AST (appends, so several files share one database). If filepath
// is empty a file picker is shown, matching the LEF/Liberty readers.
system_verilog_parse_to_ast :: proc(filepath: string, ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	resolved_path := filepath
	if len(resolved_path) == 0 {
		fmt.println("Please select a SystemVerilog file")
		resolved_path = file_picker.pick_path({mode = .Open_File, title = "Select SystemVerilog file"})
	}
	ensure(len(resolved_path) > 0, "Program terminated as you did not select a SystemVerilog file")
	data, read_err := os.read_entire_file_from_path(resolved_path, allocator)
	ensure(read_err == nil, fmt.tprint("SystemVerilog File Read Err: ", read_err, " ", resolved_path))
	svp_parse_source_to_ast(data, resolved_path, ast, allocator)
}

// Parse in-memory source text (tests, generated RTL). `source` must stay alive as long as
// the AST is used: identifier and literal strings point into it (zero copy). `filepath`
// is only used for diagnostics and for resolving relative `include paths.
system_verilog_parse_source_to_ast :: proc(source: string, filepath: string, ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	data := make([]byte, len(source), allocator)
	copy(data, source)
	svp_parse_source_to_ast(data, filepath, ast, allocator)
}
