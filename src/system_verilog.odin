/*
Femtolane SystemVerilog frontend, stage 1: source text -> typed AST.

The frontend is split into four small layers:

  system_verilog_tokenizer.odin     raw ASCII tokenizer, token layout, keyword lookup
  system_verilog_preprocessor.odin  `define/`ifdef/`include and macro expansion
  system_verilog_parser.odin        hand-written recursive descent over tokens
  this file                         AST types and the public entry points

There is no token buffer in the parser and no grammar file: the preprocessor
produces a flat token array once, and every parser function indexes it. The AST
is arena-friendly: nodes are allocated with the caller's allocator and never
freed individually; identifiers and literals are zero-copy slices of the source
(or of arena-owned macro expansion text). Comments and attributes are kept in
side arrays with their source path and line, so nodes without trivia pay no
per-node storage cost.

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
// AST
// ---------------------------------------------------------------------------------------

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
// arrays avoids adding a pointer to every AST node.
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
	modules:            [dynamic]^SVModule,
	module_hash_map:    map[string]^SVModule, // name -> module, also used for duplicate detection
	packages:           [dynamic]^SVPackage,
	package_hash_map:   map[string]^SVPackage,
	interfaces:         [dynamic]^SVInterface,
	interface_hash_map: map[string]^SVInterface,
	items:              [dynamic]SVItem, // compilation-unit items (e.g. top-level typedefs)
	type_names:         map[string]bool, // typedefs seen so far; disambiguates `name x;`
	iface_names:        map[string]bool, // interface names, usable as port/declaration types
	imports:            [dynamic]SVImport, // compilation-unit imports
	defines:            map[string]SVDefine, // `define table (conditional compilation + expansion)
	include_dirs:       [dynamic]string, // extra `include paths, after the includer's dir
	file_dirs:          [dynamic]string, // parsed file dirs (fallback for flattened trees)
	comments:           [dynamic]SVComment,
	attributes:         [dynamic]SVAttribute,
}

SVImport :: struct {
	package_name: string,
	name:         string, // "*" for wildcard imports
}

SVPackage :: struct {
	name:    string,
	imports: [dynamic]SVImport,
	items:   [dynamic]SVItem,
}

SVModportPort :: struct {
	dir:  SVPortDir,
	name: string,
}

SVModport :: struct {
	name:  string,
	ports: [dynamic]SVModportPort,
}

SVInterface :: struct {
	name:     string,
	imports:  [dynamic]SVImport,
	params:   [dynamic]^SVParamDecl,
	ports:    [dynamic]^SVPort,
	items:    [dynamic]SVItem,
	modports: [dynamic]SVModport,
}

SVModule :: struct {
	name:           string,
	source_path:    string,
	is_ansi:        bool,
	wildcard_ports: bool, // module m (.*);
	imports:        [dynamic]SVImport,
	ports:          [dynamic]^SVPort,
	params:         [dynamic]^SVParamDecl, // from the #( ... ) header list
	items:          [dynamic]SVItem,
}

// ---- ports & declarations --------------------------------------------------------------

SVPortDir :: enum u8 {
	NONE,
	INPUT,
	OUTPUT,
	INOUT,
	REF,
}

SVPort :: struct {
	data:          SVDataType,
	name:          string,
	iface_name:    string, // interface port (`axi_if.Slave bus`)
	modport:       string,
	unpacked_dims: [dynamic]SVRange,
	expr:          ^SVExpr, // explicit port expression `.P(expr)` / concatenated port
	default_value: ^SVExpr,
	dir:           SVPortDir,
	net_type:      SVNetType,
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

SVTypeSpec :: struct {
	kind:       SVTypeSpecKind,
	is_packed:  bool,
	base:       SVDataType, // enum base type, e.g. `enum logic [1:0] { ... }`
	members:    [dynamic]SVStructMember,
	enum_names: [dynamic]SVEnumName,
}

SVStructMember :: struct {
	data:        SVDataType,
	declarators: [dynamic]SVDeclarator,
}

SVEnumName :: struct {
	name:  string,
	value: ^SVExpr,
}

SVDataType :: struct {
	type_scope:  string, // package/class scope of a named type (`pkg::type`)
	type_name:   string, // user-defined type reference, "" for builtin/inline types
	packed_dims: [dynamic]SVRange,
	spec:        ^SVTypeSpec, // inline enum/struct/union
	var_type:    SVVarType,
	is_signed:   bool,
}

SVTypeDecl :: struct {
	name:          string,
	data:          SVDataType,
	unpacked_dims: [dynamic]SVRange,
	is_forward:    bool,
}

// [msb:lsb] packed/unpacked range, or [size] unpacked size (is_size = true)
SVRange :: struct {
	msb:     SVExpr,
	lsb:     SVExpr, // unused when is_size
	is_size: bool,
}

SVDeclarator :: struct {
	name:          string,
	unpacked_dims: [dynamic]SVRange,
	init:          ^SVExpr, // = expr
}

SVNetDecl :: struct {
	data:        SVDataType,
	declarators: [dynamic]SVDeclarator,
	net_type:    SVNetType, // NONE for variable declarations
}

SVPortDecl :: struct {
	dir:  SVPortDir,
	decl: ^SVNetDecl,
}

SVParamAssign :: struct {
	name:          string,
	unpacked_dims: [dynamic]SVRange,
	value:         ^SVExpr, // nil is legal in a parameter port list
	type_value:    ^SVDataType, // default type of a `parameter type`
}

SVParamDecl :: struct {
	data:        SVDataType,
	assignments: [dynamic]SVParamAssign,
	is_local:    bool, // localparam
	is_type:     bool, // `parameter type T = ...`
}

SVParamOverride :: struct {
	name:       string, // "" for ordered overrides
	value:      ^SVExpr,
	type_value: ^SVDataType, // type argument, e.g. `#(.T(logic [7:0]))`
}

SVGenvarDecl :: struct {
	names: [dynamic]string,
}

// ---- instantiations --------------------------------------------------------------------

SVPortConn :: struct {
	name:  string, // "" for ordered connections
	value: ^SVExpr, // nil for an unconnected port
}

SVInstance :: struct {
	cell_name:       string,
	is_gate:         bool, // gate primitive (and/or/buf/...): delays are legal, name optional
	param_overrides: [dynamic]SVParamOverride,
	name:            string, // "" for nameless gate instances
	unpacked_dims:   [dynamic]SVRange, // instance array dimensions
	port_conns:      [dynamic]SVPortConn,
	wildcard_ports:  bool, // .*
}

// ---- continuous assignment -------------------------------------------------------------

SVAssignPair :: struct {
	lhs: SVExpr,
	rhs: SVExpr,
}

SVContAssign :: struct {
	pairs: [dynamic]SVAssignPair,
}

// alias a = b = c;  (multiple names for the same physical net)
SVAlias :: struct {
	names: [dynamic]SVExpr,
}

// defparam a.b = expr { , c.d = expr } ;  (hierarchical parameter override)
SVDefparam :: struct {
	pairs: [dynamic]SVAssignPair,
}

// ---- procedural constructs -------------------------------------------------------------

SVEdgeKind :: enum u8 {
	NONE,
	POSEDGE,
	NEGEDGE,
	EDGE,
}

SVEvent :: struct {
	edge: SVEdgeKind,
	expr: SVExpr,
	iff:  ^SVExpr,
}

SVTimingCtl :: struct {
	is_delay:  bool,
	delay:     SVExpr, // valid when is_delay
	events:    [dynamic]SVEvent,
	any_event: bool, // @* or @(*)
}

SVProcKind :: enum u8 {
	INITIAL,
	FINAL,
	ALWAYS,
	ALWAYS_COMB,
	ALWAYS_FF,
	ALWAYS_LATCH,
}

SVProc :: struct {
	kind:      SVProcKind,
	events:    [dynamic]SVEvent, // sensitivity list hoisted from @( ... )
	any_event: bool, // always @* / @(*)
	body:      SVStmt,
}

SVSubroutine :: struct {
	is_task:      bool,
	is_automatic: bool,
	return_data:  SVDataType, // VOID for tasks and void functions
	name:         string,
	ports:        [dynamic]SVTFPort,
	body:         SVBlock,
}

SVTFPort :: struct {
	dir:           SVPortDir, // NONE when omitted (function inputs may omit it)
	data:          SVDataType,
	name:          string,
	unpacked_dims: [dynamic]SVRange,
	default_value: ^SVExpr,
}

// ---- generate constructs ---------------------------------------------------------------

SVGenBlock :: struct {
	label: string, // begin : label ... end
	items: [dynamic]SVItem,
}

SVGenRegion :: struct {
	label: string, // "" for an explicit generate ... endgenerate region
	items: [dynamic]SVItem,
}

SVGenLoop :: struct {
	var:  string, // genvar name
	init: SVExpr,
	cond: SVExpr,
	step: SVStmt,
	body: ^SVGenBlock,
}

SVGenIf :: struct {
	cond:     SVExpr,
	then_blk: ^SVGenBlock,
	else_blk: ^SVGenBlock, // nil when there is no else branch
}

SVGenCaseItem :: struct {
	exprs:      [dynamic]SVExpr,
	is_default: bool,
	body:       ^SVGenBlock,
}

SVGenCase :: struct {
	kind:    SVCaseKind,
	subject: SVExpr,
	items:   [dynamic]SVGenCaseItem,
}

// ---- statements ------------------------------------------------------------------------

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

SVAssignStmt :: struct {
	lhs:         SVExpr,
	op:          SVAssignOp,
	rhs:         SVExpr,
	nonblocking: bool, // <=
	timing:      ^SVTimingCtl, // intra-assignment delay/event control
}

SVIf :: struct {
	qualifier: SVQualifier,
	cond:      SVExpr,
	then_body: ^SVStmt,
	else_body: ^SVStmt,
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

SVCaseItem :: struct {
	exprs:      [dynamic]SVExpr,
	ranges:     [dynamic]SVInsideRange, // `case ... inside` item ranges
	is_default: bool,
	body:       ^SVStmt,
}

SVCase :: struct {
	kind:      SVCaseKind,
	qualifier: SVQualifier,
	subject:   SVExpr,
	is_inside: bool, // case ( ... ) inside
	items:     [dynamic]SVCaseItem,
}

SVFor :: struct {
	var_decls:    [dynamic]^SVNetDecl, // for (int i = 0, ...)
	init_assigns: [dynamic]^SVAssignStmt, // for (i = 0, ...)
	cond:         ^SVExpr, // nil for `for (;;)`
	steps:        [dynamic]SVStmt,
	body:         ^SVStmt,
}

SVWhile :: struct {
	do_while: bool,
	cond:     SVExpr,
	body:     ^SVStmt,
}

SVRepeat :: struct {
	count: SVExpr,
	body:  ^SVStmt,
}

SVForever :: struct {
	body: ^SVStmt,
}

SVForeach :: struct {
	array:     SVExpr,
	loop_vars: [dynamic]string, // "" for an omitted index
	body:      ^SVStmt,
}

SVAssertKind :: enum u8 {
	ASSERT,
	ASSUME,
	COVER,
	EXPECT,
}

SVAssert :: struct {
	kind:          SVAssertKind,
	is_property:   bool,
	cond:          SVExpr, // immediate assertion condition
	property_text: string, // raw property/sequence text (not part of the synth subset)
	pass_body:     ^SVStmt,
	else_body:     ^SVStmt,
}

SVJumpKind :: enum u8 {
	BREAK,
	CONTINUE,
	RETURN,
}

SVJump :: struct {
	kind:  SVJumpKind,
	value: ^SVExpr, // return value, may be nil
}

SVTimingStmt :: struct {
	timing: SVTimingCtl,
	body:   ^SVStmt, // nil for a null statement
}

SVBlockDecl :: union {
	^SVNetDecl,
	^SVParamDecl,
	^SVTypeDecl,
}

SVBlock :: struct {
	label:   string,
	imports: [dynamic]SVImport, // block-scope package imports
	decls:   [dynamic]SVBlockDecl,
	stmts:   [dynamic]SVStmt,
}

SVStmt :: union {
	^SVBlock,
	^SVNetDecl,
	^SVParamDecl,
	^SVAssignStmt,
	^SVIf,
	^SVCase,
	^SVFor,
	^SVWhile,
	^SVRepeat,
	^SVForever,
	^SVForeach,
	^SVTimingStmt,
	^SVAssert,
	^SVCall,
	^SVIncDec,
	^SVJump,
}

// ---- expressions -----------------------------------------------------------------------

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

SVNumber :: struct {
	raw:        string, // digit text, points into the source bytes
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

// Compact integer literal used for the common case that fits in 64 bits. Keeping
// it inline in SVExpr avoids a heap node for the majority of numeric literals.
SVSmallNumber :: struct {
	value:     u64,
	width:     u32,
	base:      SVNumberBase,
	is_signed: bool,
	time_unit: SVTimeUnit,
}

SVStringLit :: distinct string

// Scoped constant/parameter reference: `pkg::NAME`.
SVScopedName :: struct {
	scope: string,
	name:  string,
}

// Assignment pattern `'{...}`: positional or keyed entries, optionally replicated.
SVAggregateEntry :: struct {
	key:   string, // "" for positional entries ("default" for default keys)
	value: SVExpr,
}

SVAggregate :: struct {
	entries:    [dynamic]SVAggregateEntry,
	count:      ^SVExpr, // replication count for `'{N{...}}`
	type_name:  string, // typed assignment pattern `type_t'{...}`
	type_scope: string,
}

SVSelectKind :: enum u8 {
	BIT,
	PART,
	INDEXED_PLUS,
	INDEXED_MINUS,
}

SVSelectPart :: struct {
	member:     string, // non-empty: `.member` access, other fields unused
	kind:       SVSelectKind,
	first:      SVExpr,
	second:     SVExpr,
	has_second: bool,
}

SVSelect :: struct {
	base:  SVExpr,
	parts: [dynamic]SVSelectPart,
}

SVInsideRange :: struct {
	lo:     SVExpr,
	hi:     SVExpr,
	has_hi: bool, // false for a single value
}

SVInside :: struct {
	subject: SVExpr,
	ranges:  [dynamic]SVInsideRange,
}

SVConcat :: struct {
	parts: [dynamic]SVExpr,
	count: ^SVExpr, // replication count for {N{a, b}}, nil for a plain concatenation
}

SVStreamDir :: enum u8 {
	LEFT,
	RIGHT,
}

SVStream :: struct {
	dir:   SVStreamDir, // {<<{...}} / {>>{...}}
	slice: ^SVExpr, // optional slice size
	parts: [dynamic]SVExpr,
}

SVCastKind :: enum u8 {
	SIGNING,
	TYPE,
	SIZE,
}

SVCast :: struct {
	kind:    SVCastKind,
	target:  string, // SIGNING: "signed"/"unsigned"; TYPE: type name
	data:    SVDataType, // TYPE
	size:    ^SVExpr, // SIZE
	operand: SVExpr,
}

SVCallArg :: struct {
	name:  string, // named argument `.name(expr)`; "" when positional
	value: ^SVExpr,
}

SVCall :: struct {
	name:      string, // includes the leading $ for system calls
	is_system: bool,
	args:      [dynamic]SVCallArg,
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

SVUnary :: struct {
	op:      SVUnOp,
	operand: SVExpr,
}

SVBinary :: struct {
	op:  SVBinOp,
	lhs: SVExpr,
	rhs: SVExpr,
}

SVTernary :: struct {
	cond: SVExpr,
	lhs:  SVExpr,
	rhs:  SVExpr,
}

SVIncDec :: struct {
	operand:   SVExpr,
	is_dec:    bool,
	is_prefix: bool,
}

SVExpr :: union {
	string, // plain identifier
	^SVNumber,
	SVSmallNumber,
	SVStringLit,
	^SVSelect,
	^SVConcat,
	^SVStream,
	^SVUnary,
	^SVBinary,
	^SVTernary,
	^SVInside,
	^SVCall,
	^SVIncDec,
	^SVCast,
	^SVAggregate,
	^SVScopedName,
}

// ---- module items ----------------------------------------------------------------------

SVItem :: union {
	^SVPortDecl,
	^SVNetDecl,
	^SVParamDecl,
	^SVTypeDecl,
	^SVGenvarDecl,
	^SVContAssign,
	^SVAlias,
	^SVDefparam,
	^SVInstance,
	^SVProc,
	^SVSubroutine,
	^SVCall, // elaboration system tasks ($fatal/$error/...)
	^SVAssert, // concurrent assertions at module/generate scope
	^SVGenRegion,
	^SVGenLoop,
	^SVGenIf,
	^SVGenCase,
}

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

// [size]'[s]base digits | plain decimal | real literal


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

// Frontend entry point kept from the original stub: parses RTL into the AST. The lowering
// stages (bit-blast -> elaborate always blocks -> techmap) operate on this AST next.
system_verilog_to_gate_netlist :: proc(filepath: string, ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	// TODO(rahul): lower ast into NetlistHyperGraph once the parse stage is validated.
	system_verilog_parse_to_ast(filepath, ast, allocator)
}
