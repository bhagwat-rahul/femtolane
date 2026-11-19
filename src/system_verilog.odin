/*
Femtolane SystemVerilog frontend, stage 1: source text -> typed AST.

Hand-written recursive-descent parser reading directly from the source bytes in a single
pass: no token buffer, no grammar file, no parser generator. Token scanning reuses the
shared Lexer from lexer_common.odin. Expressions use precedence climbing driven by the
SV_BINARY_OPS data table (IEEE 1800-2023 Table 11-2), not one function per precedence level.

Scope: the ASIC synthesizable RTL subset (what a synthesis frontend must accept):
  - modules (ANSI, non-ANSI and `(.*)` headers; interface and generic-interface ports;
    explicit `.port(expr)` and concatenated port expressions), packages, interfaces with
    modports, parameter/localparam declarations incl. `#(...)` lists and `parameter type`,
  - typedefs: aliases, enums, packed structs/unions; user-defined type references (incl.
    package-scoped `pkg::t`) and inline enum/struct/union declarations,
  - genvar + generate (region, for, if/else, case) and implicitly generated loops/ifs,
  - net/variable declarations (wire/tri/..., reg/logic/bit/int/integer/byte/time/...,
    signed/unsigned, packed and unpacked dimensions/memories, initialization),
  - continuous assign, net aliasing (`alias`), `defparam`, module/interface instantiations
    and gate primitives (parameter/type overrides, named/ordered/empty/`.*` connections,
    instance arrays, strengths, delay and mintypmax controls),
  - initial/final/always/always_comb/always_ff/always_latch, posedge/negedge/edge and
    wildcard event controls, begin/end blocks (with block-scope declarations and imports),
    if/else (+unique/priority), case/casez/casex, case...inside, for/while/do-while/repeat/
    forever/foreach, blocking/nonblocking/compound assignments, intra-assignment timing,
    ++/--, break/continue/return, immediate/deferred/concurrent assertions (property text
    is kept raw), functions and tasks (ANSI and legacy ports),
  - full expression set of Table 11-2: bit/part/indexed selects, concatenation/replication,
    streaming concatenation, unary reductions, ternary, inside, casts (signing, type, size,
    constant primary), assignment patterns (positional/keyed/typed/replicated), quoted and
    triple-quoted string literals, scoped constants/calls, system calls ($clog2, $readmemh,
    ...),
  - compiler directives inline with the parse: `define (object-like and function-like,
    parameters, defaults, ``/`"/`\`" escapes, token pasting, `__FILE__/`__LINE__), `undef,
    `ifdef/`ifndef/`elsif/`else/`endif (inactive text skipped without parsing), `include
    anywhere a token can appear (relative to the includer, then ast.include_dirs, then
    directories of already parsed files), `timescale and other benign directives ignored.

Rejected with a clear panic rather than mis-parsed: programs, checkers, UDP declarations,
case...matches, fork/join, wait/disable/force/release/deassign, event triggers, `dist`,
DPI exports (DPI imports are skipped), and macro/include nesting beyond SV_MAX_INPUT_DEPTH.
Class bodies, clocking block bodies, covergroups, specify blocks and property/sequence
declarations are skipped: they are verification-only and not part of the synthesizable set.
Two non-synthesizable forms are nevertheless accepted syntactically because they appear in
vendor and simulation-only files: method-style calls (`queue.push_back(x)`, flattened into
the call name) and empty concatenations (`{}`, e.g. clearing a queue).

The AST is arena-friendly: nodes are allocated with the caller's allocator and never freed
individually; identifiers/literals point into the source bytes (zero copy). Modules,
packages, interfaces and compilation-unit items append to the passed AST so several files
(and `include expansion) accumulate into one database.

NOTE(rahul): lowering to NetlistHyperGraph (bit-blast -> elaborate -> techmap) is the next
stage; this file currently covers parsing only.
*/

package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
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
}

SystemVerilogAST :: struct {
	modules:           [dynamic]^SVModule,
	module_hash_map:   map[string]^SVModule, // name -> module, also used for duplicate detection
	packages:          [dynamic]^SVPackage,
	package_hash_map:  map[string]^SVPackage,
	interfaces:        [dynamic]^SVInterface,
	interface_hash_map: map[string]^SVInterface,
	items:             [dynamic]SVItem, // compilation-unit items (e.g. top-level typedefs)
	type_names:        map[string]bool, // typedefs seen so far; disambiguates `name x;`
	iface_names:       map[string]bool, // interface names, usable as port/declaration types
	imports:           [dynamic]SVImport, // compilation-unit imports
	defines:           map[string]SVDefine, // `define table (conditional compilation + expansion)
	include_dirs:      [dynamic]string, // extra `include paths, after the includer's dir
	file_dirs:         [dynamic]string, // parsed file dirs (fallback for flattened trees)
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

SVPortDir :: enum {
	NONE,
	INPUT,
	OUTPUT,
	INOUT,
	REF,
}

SVPort :: struct {
	name:          string,
	dir:           SVPortDir,
	net_type:      SVNetType,
	data:          SVDataType,
	iface_name:    string, // interface port (`axi_if.Slave bus`)
	modport:       string,
	expr:          ^SVExpr, // explicit port expression `.P(expr)` / concatenated port
	unpacked_dims: [dynamic]SVRange,
	default_value: ^SVExpr,
}

SVNetType :: enum {
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

SVVarType :: enum {
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

SVTypeSpecKind :: enum { ENUM, STRUCT, UNION }

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
	var_type:    SVVarType,
	type_scope:  string, // package/class scope of a named type (`pkg::type`)
	type_name:   string, // user-defined type reference, "" for builtin/inline types
	spec:        ^SVTypeSpec, // inline enum/struct/union
	is_signed:   bool,
	packed_dims: [dynamic]SVRange,
}

SVTypeDecl :: struct {
	name:          string,
	data:          SVDataType,
	unpacked_dims: [dynamic]SVRange,
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
	net_type:    SVNetType, // NONE for variable declarations
	data:        SVDataType,
	declarators: [dynamic]SVDeclarator,
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
	is_local:    bool, // localparam
	is_type:     bool, // `parameter type T = ...`
	data:        SVDataType,
	assignments: [dynamic]SVParamAssign,
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

SVEdgeKind :: enum {
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

SVProcKind :: enum {
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
	subject: SVExpr,
	items:   [dynamic]SVGenCaseItem,
}

// ---- statements ------------------------------------------------------------------------

SVAssignOp :: enum {
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

SVQualifier :: enum {
	NONE,
	UNIQUE,
	UNIQUE0,
	PRIORITY,
}

SVCaseKind :: enum {
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

SVAssertKind :: enum { ASSERT, ASSUME, COVER, EXPECT }

SVAssert :: struct {
	kind:          SVAssertKind,
	is_property:   bool,
	cond:          SVExpr, // immediate assertion condition
	property_text: string, // raw property/sequence text (not part of the synth subset)
	pass_body:     ^SVStmt,
	else_body:     ^SVStmt,
}

SVJumpKind :: enum {
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

SVNumberBase :: enum {
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
	time_unit:  string, // "s", "ms", "us", "ns", "ps", "fs" for time literals
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

SVSelectKind :: enum {
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

SVStreamDir :: enum { LEFT, RIGHT }

SVStream :: struct {
	dir:   SVStreamDir, // {<<{...}} / {>>{...}}
	slice: ^SVExpr, // optional slice size
	parts: [dynamic]SVExpr,
}

SVCastKind :: enum {
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

SVUnOp :: enum {
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

SVBinOp :: enum {
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
	SVNumber,
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
	SVScopedName,
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

// ---------------------------------------------------------------------------------------
// Operator precedence (IEEE 1800-2023 Table 11-2), highest binds tightest
// ---------------------------------------------------------------------------------------

SV_PREC_TERNARY :: u8(1)
SV_PREC_LOG_OR :: u8(2)
SV_PREC_LOG_AND :: u8(3)
SV_PREC_BIT_OR :: u8(4)
SV_PREC_BIT_XOR :: u8(5)
SV_PREC_BIT_AND :: u8(6)
SV_PREC_EQ :: u8(7)
SV_PREC_REL :: u8(8)
SV_PREC_SHIFT :: u8(9)
SV_PREC_ADD :: u8(10)
SV_PREC_MUL :: u8(11)
SV_PREC_POW :: u8(12)

SVBinOpInfo :: struct {
	text: string,
	op:   SVBinOp,
	prec: u8,
}

// Matching picks the longest text, so `**` beats `*`, `<<<` beats `<<` beats `<`.
@(rodata)
SV_BINARY_OPS := [?]SVBinOpInfo {
	{"**", .POW, SV_PREC_POW},
	{"*", .MUL, SV_PREC_MUL},
	{"/", .DIV, SV_PREC_MUL},
	{"%", .MOD, SV_PREC_MUL},
	{"+", .ADD, SV_PREC_ADD},
	{"-", .SUB, SV_PREC_ADD},
	{"<<<", .ASH_L, SV_PREC_SHIFT},
	{">>>", .ASH_R, SV_PREC_SHIFT},
	{"<<", .SHL, SV_PREC_SHIFT},
	{">>", .SHR, SV_PREC_SHIFT},
	{"<=", .LE, SV_PREC_REL},
	{">=", .GE, SV_PREC_REL},
	{"<", .LT, SV_PREC_REL},
	{">", .GT, SV_PREC_REL},
	{"===", .CASE_EQ, SV_PREC_EQ},
	{"!==", .CASE_NE, SV_PREC_EQ},
	{"==?", .WILD_EQ, SV_PREC_EQ},
	{"!=?", .WILD_NE, SV_PREC_EQ},
	{"==", .EQ, SV_PREC_EQ},
	{"!=", .NE, SV_PREC_EQ},
	{"&", .BIT_AND, SV_PREC_BIT_AND},
	{"~^", .BIT_XNOR, SV_PREC_BIT_XOR},
	{"^~", .BIT_XNOR, SV_PREC_BIT_XOR},
	{"^", .BIT_XOR, SV_PREC_BIT_XOR},
	{"|", .BIT_OR, SV_PREC_BIT_OR},
	{"&&", .LOG_AND, SV_PREC_LOG_AND},
	{"||", .LOG_OR, SV_PREC_LOG_OR},
}

// ---------------------------------------------------------------------------------------
// Parser state & entry points
// ---------------------------------------------------------------------------------------

SV_MAX_INPUT_DEPTH :: 64 // nesting limit for `include and macro expansion

// Saved input position: real source resumes here once an included file or macro expansion
// is exhausted.
SVInputFrame :: struct {
	lexer: Lexer,
}

SVParser :: struct {
	l:           Lexer,
	ast:         ^SystemVerilogAST,
	allocator:   mem.Allocator,
	module:      ^SVModule, // module currently being parsed (non-ANSI port declarations)
	cond_stack:  [dynamic]bool, // `ifdef regions whose active branch is being parsed
	input_stack: [dynamic]SVInputFrame, // enclosing files/expansions, innermost last
}

SVState :: struct {
	idx:      int,
	newlines: u32,
}

sv_save :: #force_inline proc(p: ^SVParser) -> SVState {
	return {idx = p.l.idx, newlines = p.l.newlines}
}

sv_restore :: #force_inline proc(p: ^SVParser, s: SVState) {
	p.l.idx = s.idx
	p.l.newlines = s.newlines
}

// Pop exhausted macro expansions / included files until real input remains.
sv_pop_exhausted_inputs :: proc(p: ^SVParser) {
	for p.l.idx >= len(p.l.src) && len(p.input_stack) > 0 {
		frame := pop(&p.input_stack)
		p.l = frame.lexer
	}
}

// True at the end of the outermost input. Pops exhausted nested inputs first.
sv_at_eof :: proc(p: ^SVParser) -> bool {
	sv_pop_exhausted_inputs(p)
	return p.l.idx >= len(p.l.src)
}

// Suspend the current input and continue lexing `data` (an included file or a macro
// expansion). The suspended input resumes once `data` is exhausted.
sv_push_input :: proc(p: ^SVParser, data: []byte, filepath: string, newlines: u32) {
	lexer_ensure(&p.l, len(p.input_stack) < SV_MAX_INPUT_DEPTH, "`include/macro expansion nesting too deep")
	append(&p.input_stack, SVInputFrame{lexer = p.l})
	p.l = Lexer{src = data, idx = 0, newlines = newlines, filepath = filepath}
}

sv_bytes_copy :: proc(p: ^SVParser, text: string) -> []byte {
	data := make([]byte, len(text), p.allocator)
	copy(data, text)
	return data
}

sv_trim_space :: proc(text: []byte) -> string {
	start := 0
	end := len(text)
	for start < end {
		c := text[start]
		if c != WHITESPACE && c != WHITESPACE_TAB && c != NEWLINE && c != NEWLINE_CARRIAGE_RETURN { break }
		start += 1
	}
	for end > start {
		c := text[end - 1]
		if c != WHITESPACE && c != WHITESPACE_TAB && c != NEWLINE && c != NEWLINE_CARRIAGE_RETURN { break }
		end -= 1
	}
	return string(text[start:end])
}

sv_new :: proc(p: ^SVParser, $T: typeid) -> ^T {
	ptr, err := new(T, p.allocator)
	ensure(err == nil, "SystemVerilog AST allocation failed")
	return ptr
}

sv_new_expr :: proc(p: ^SVParser, e: SVExpr) -> ^SVExpr {
	ptr := sv_new(p, SVExpr)
	ptr^ = e
	return ptr
}

// Lazily initializes the AST's containers. Safe to call more than once.
system_verilog_ast_init :: proc(ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	if ast.modules == nil { ast.modules = make([dynamic]^SVModule, allocator) }
	if ast.module_hash_map == nil { ast.module_hash_map = make(map[string]^SVModule, allocator) }
	if ast.packages == nil { ast.packages = make([dynamic]^SVPackage, allocator) }
	if ast.package_hash_map == nil { ast.package_hash_map = make(map[string]^SVPackage, allocator) }
	if ast.items == nil { ast.items = make([dynamic]SVItem, allocator) }
	if ast.interfaces == nil { ast.interfaces = make([dynamic]^SVInterface, allocator) }
	if ast.interface_hash_map == nil { ast.interface_hash_map = make(map[string]^SVInterface, allocator) }
	if ast.type_names == nil { ast.type_names = make(map[string]bool, allocator) }
	if ast.iface_names == nil { ast.iface_names = make(map[string]bool, allocator) }
	if ast.imports == nil { ast.imports = make([dynamic]SVImport, allocator) }
	if ast.defines == nil { ast.defines = make(map[string]SVDefine, allocator) }
	if ast.include_dirs == nil { ast.include_dirs = make([dynamic]string, allocator) }
	if ast.file_dirs == nil { ast.file_dirs = make([dynamic]string, allocator) }
}

// Parse one file into the AST (appends, so several files share one database). If filepath
// is empty a file picker is shown, matching the LEF/Liberty readers.
system_verilog_parse_to_ast :: proc(filepath: string, ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	resolved_path := filepath
	if len(resolved_path) == 0 {
		fmt.println("Please select a SystemVerilog file")
		resolved_path = file_picker.pick_path({mode = .Open_File, title = "Select SystemVerilog file"})
	}
	ensure(len(resolved_path) > 0, "Program terminated as you did not select a SystemVerilog file")
	system_verilog_ast_init(ast, allocator)
	data, read_err := os.read_entire_file_from_path(resolved_path, allocator)
	ensure(read_err == nil, fmt.tprint("SystemVerilog File Read Err: ", read_err, " ", resolved_path))
	sv_parse_source_into_ast(data, resolved_path, ast, allocator)
}

// Parse in-memory source text (tests, generated RTL). `source` must stay alive as long as
// the AST is used: identifier and literal strings point into it (zero copy). `filepath`
// is only used for diagnostics and for resolving relative `include paths.
system_verilog_parse_source_to_ast :: proc(
	source: string,
	filepath: string,
	ast: ^SystemVerilogAST,
	allocator: mem.Allocator,
) {
	system_verilog_ast_init(ast, allocator)
	data := make([]byte, len(source), allocator)
	copy(data, source)
	sv_parse_source_into_ast(data, filepath, ast, allocator)
}

// Frontend entry point kept from the original stub: parses RTL into the AST. The lowering
// stages (bit-blast -> elaborate always blocks -> techmap) operate on this AST next.
system_verilog_to_gate_netlist :: proc(filepath: string, ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	// TODO(rahul): lower ast into NetlistHyperGraph once the parse stage is validated.
	system_verilog_parse_to_ast(filepath, ast, allocator)
}

sv_parse_source_into_ast :: proc(data: []byte, filepath: string, ast: ^SystemVerilogAST, allocator: mem.Allocator) {
	dir := sv_path_directory(filepath)
	if len(dir) > 0 {
		known := false
		for existing in ast.file_dirs {
			if existing == dir { known = true; break }
		}
		if !known { append(&ast.file_dirs, dir) }
	}
	p := SVParser {
		l           = Lexer{src = data, idx = 0, filepath = filepath},
		ast         = ast,
		allocator   = allocator,
		cond_stack  = make([dynamic]bool, allocator),
		input_stack = make([dynamic]SVInputFrame, allocator),
	}
	sv_parse_description(&p)
}

// source_text ::= { description } ; only modules are part of the synthesizable subset here.
sv_parse_description :: proc(p: ^SVParser) {
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) { break }
		sv_skip_attributes(p)
		sv_skip_trivia(p)
		if sv_at_eof(p) { break }
		start := sv_save(p)
		keyword := sv_scan_ident_required(p)
		switch keyword {
		case "module", "macromodule": sv_parse_module(p)
		case "package": _ = sv_parse_package(p)
		case "typedef": append(&p.ast.items, sv_parse_typedef(p))
		case "parameter", "localparam":
			decl := sv_parse_param_decl_after_keyword(p, keyword == "localparam")
			sv_skip_trivia(p)
			lexer_consume(&p.l, SEMICOLON)
			append(&p.ast.items, decl)
		case "function": append(&p.ast.items, sv_parse_subroutine(p, false))
		case "task": append(&p.ast.items, sv_parse_subroutine(p, true))
		case "interface": _ = sv_parse_interface(p)
		case "import": sv_parse_import_list(p, &p.ast.imports)
		case "class":
			// Classes are not synthesizable; skip the body so RTL sharing a file still parses.
			sv_skip_until_ident(p, "endclass")
			sv_skip_optional_end_label(p)
		case:
			sv_restore(p, start)
			lexer_panic(
				&p.l,
				fmt.tprintf("Unsupported top-level construct '%s'; only modules, packages and imports are supported", keyword),
			)
		}
	}
	lexer_ensure(&p.l, len(p.cond_stack) == 0, "Unterminated `ifdef/`ifndef at end of file")
}

// ---------------------------------------------------------------------------------------
// Trivia, comments and compiler directives (preprocessing inline with the parse)
// ---------------------------------------------------------------------------------------

sv_skip_trivia :: proc(p: ^SVParser) {
	for {
		sv_pop_exhausted_inputs(p)
		l := &p.l
		c := lexer_peek(l)
		switch c {
		case NEWLINE, NEWLINE_CARRIAGE_RETURN, WHITESPACE, WHITESPACE_TAB: lexer_skip_newlines_and_whitespaces(l)
		case SLASH: if lexer_peek(l, 1) == SLASH || lexer_peek(l, 1) == ASTERISK {
					netlist_handle_comments(l)
				} else {
					return
				}
		case '`':
			if sv_maybe_expand_macro(p) { continue }
			sv_handle_directive(p)
		case: return
		}
	}
}

// Whitespace and comments only. Lookahead helpers use this so a speculative parse can
// never expand macros or push include frames.
sv_skip_ws_and_comments :: proc(p: ^SVParser) {
	l := &p.l
	for {
		c := lexer_peek(l)
		switch c {
		case NEWLINE, NEWLINE_CARRIAGE_RETURN, WHITESPACE, WHITESPACE_TAB: lexer_skip_newlines_and_whitespaces(l)
		case SLASH: if lexer_peek(l, 1) == SLASH || lexer_peek(l, 1) == ASTERISK {
					netlist_handle_comments(l)
				} else {
					return
				}
		case: return
		}
	}
}

sv_skip_blank :: #force_inline proc(l: ^Lexer) {
	for {
		c := lexer_peek(l)
		if c != WHITESPACE && c != WHITESPACE_TAB { break }
		lexer_advance(l)
	}
}

sv_skip_to_line_end :: #force_inline proc(l: ^Lexer) {
	for lexer_peek(l) != NEWLINE && lexer_peek(l) != NEWLINE_CARRIAGE_RETURN && lexer_peek(l) != 0 {
		lexer_advance(l)
	}
	if lexer_peek(l) == NEWLINE_CARRIAGE_RETURN { lexer_advance(l) }
	if lexer_peek(l) == NEWLINE { lexer_advance(l) }
}


sv_handle_directive :: proc(p: ^SVParser) {
	l := &p.l
	start := sv_save(p)
	lexer_consume(l, '`')
	name := sv_scan_ident_required(p)
	switch name {
	case "define": sv_define_macro(p)
	case "undefineall": clear(&p.ast.defines)
	case "undef":
		sv_skip_blank(l)
		macro := sv_scan_ident_required(p)
		delete_key(&p.ast.defines, macro)
	case "ifdef", "ifndef":
		sv_skip_blank(l)
		macro := sv_scan_ident_required(p)
		defined := macro in p.ast.defines
		active := defined if name == "ifdef" else !defined
		if active {
			append(&p.cond_stack, true)
		} else {
			sv_resolve_inactive_branch(p, sv_skip_inactive_region(p))
		}
	case "elsif":
		lexer_ensure(l, len(p.cond_stack) > 0, "Unexpected `elsif")
		sv_skip_active_branches(p)
		_ = pop(&p.cond_stack)
	case "else":
		lexer_ensure(l, len(p.cond_stack) > 0, "Unexpected `else (compiler directive)")
		sv_skip_active_branches(p)
		_ = pop(&p.cond_stack)
	case "endif":
		lexer_ensure(l, len(p.cond_stack) > 0, "Unexpected `endif")
		_ = pop(&p.cond_stack)
	case "include":
		sv_restore(p, start)
		sv_push_include(p)
	case "timescale",
		 "default_nettype",
		 "celldefine",
		 "endcelldefine",
		 "pragma",
		 "resetall",
		 "line",
		 "begin_keywords",
		 "end_keywords",
		 "nounconnected_drive",
		 "unconnected_drive",
		 "default_decay_time",
		 "default_trireg_strength",
		 "delay_mode_distributed",
		 "delay_mode_path",
		 "delay_mode_unit",
		 "delay_mode_zero":
		sv_skip_to_line_end(l)
	case: lexer_panic(l, fmt.tprintf("Unsupported compiler directive `%s", name))
	}
}

sv_define_macro :: proc(p: ^SVParser) {
	l := &p.l
	sv_skip_blank(l)
	macro := sv_scan_ident_required(p)
	def := SVDefine {
		params         = make([dynamic]string, p.allocator),
		param_defaults = make([dynamic]string, p.allocator),
	}
	// Function-like only when '(' immediately follows the macro name (IEEE 1800-2023 22.5.1).
	if lexer_peek(l) == LPAREN {
		def.is_function_like = true
		lexer_advance(l)
		sv_skip_blank(l)
		if lexer_peek(l) != RPAREN {
			for {
				sv_skip_blank(l)
				append(&def.params, sv_scan_ident_required(p))
				sv_skip_blank(l)
				default_text := ""
				if lexer_peek(l) == EQUAL {
					lexer_advance(l)
					sv_skip_blank(l)
					start := l.idx
					depth := 0
					for {
						c := lexer_peek(l)
						lexer_ensure(l, l.idx < len(l.src), "Unterminated macro parameter default")
						if c == DOUBLE_QUOTE {
							_ = sv_scan_string(p)
							continue
						}
						if c == LPAREN { depth += 1 }
						if c == RPAREN {
							if depth == 0 { break }
							depth -= 1
						}
						if c == COMMA && depth == 0 { break }
						lexer_advance(l)
					}
					default_text = sv_trim_space(l.src[start:l.idx])
				}
				append(&def.param_defaults, default_text)
				sv_skip_blank(l)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					continue
				}
				break
			}
		}
		sv_skip_blank(l)
		lexer_consume(l, RPAREN)
	}
	// Replacement text runs to the end of the line; backslash-newline continues it and is
	// removed from the stored body. Comments are not part of the substituted text and
	// string literals are copied verbatim (22.5.1).
	b := strings.builder_make(p.allocator)
	for l.idx < len(l.src) {
		c := lexer_peek(l)
		if c == NEWLINE || c == NEWLINE_CARRIAGE_RETURN || c == 0 { break }
		if c == DOUBLE_QUOTE {
			start := l.idx
			lexer_advance(l)
			if lexer_peek(l) == DOUBLE_QUOTE && lexer_peek(l, 1) == DOUBLE_QUOTE {
				// triple-quoted string
				lexer_advance(l, 2)
				for l.idx < len(l.src) {
					if lexer_peek(l) == DOUBLE_QUOTE && lexer_peek(l, 1) == DOUBLE_QUOTE && lexer_peek(l, 2) == DOUBLE_QUOTE {
						lexer_advance(l, 3)
						break
					}
					if lexer_peek(l) == ESCAPE_SYMBOL {
						lexer_advance(l, 2)
						continue
					}
					lexer_advance(l)
				}
			} else {
				for l.idx < len(l.src) {
					if lexer_peek(l) == ESCAPE_SYMBOL {
						lexer_advance(l, 2)
						continue
					}
					if lexer_peek(l) == DOUBLE_QUOTE {
						lexer_advance(l)
						break
					}
					if lexer_peek(l) == NEWLINE || lexer_peek(l) == NEWLINE_CARRIAGE_RETURN { break }
					lexer_advance(l)
				}
			}
			strings.write_string(&b, string(l.src[start:l.idx]))
			continue
		}
		if c == SLASH && lexer_peek(l, 1) == SLASH {
			for lexer_peek(l) != NEWLINE && lexer_peek(l) != NEWLINE_CARRIAGE_RETURN && lexer_peek(l) != 0 {
				lexer_advance(l)
			}
			// a continued one-line comment ends before the backslash; the text continues
			continued := l.idx > 0 && l.src[l.idx - 1] == ESCAPE_SYMBOL
			if continued {
				if lexer_peek(l) == NEWLINE_CARRIAGE_RETURN { lexer_advance(l) }
				if lexer_peek(l) == NEWLINE { lexer_advance(l) }
				continue
			}
			break
		}
		if c == SLASH && lexer_peek(l, 1) == ASTERISK {
			lexer_advance(l, 2)
			for !(lexer_peek(l) == ASTERISK && lexer_peek(l, 1) == SLASH) && lexer_peek(l) != 0 {
				lexer_advance(l)
			}
			lexer_advance(l, 2)
			continue
		}
		if c == ESCAPE_SYMBOL {
			after := l.idx + 1
			if after < len(l.src) && l.src[after] == NEWLINE_CARRIAGE_RETURN { after += 1 }
			if after < len(l.src) && l.src[after] == NEWLINE {
				l.idx = after + 1
				continue
			}
		}
		strings.write_byte(&b, c)
		lexer_advance(l)
	}
	def.body = strings.to_string(b)
	p.ast.defines[macro] = def
	sv_skip_to_line_end(l)
}

// `include "file": push the file as the new input, so it can appear anywhere a token can,
// including inside a module body. Search order: absolute, includer's directory, then the
// AST's include_dirs.
sv_push_include :: proc(p: ^SVParser) {
	l := &p.l
	lexer_consume(l, '`')
	name := sv_scan_ident_required(p)
	lexer_ensure(l, name == "include", "Expected `include")
	sv_skip_blank(l)
	include_path: string
	if lexer_peek(l) == '`' {
		// `include `CONFIG_FILE — the macro expands to a quoted path
		lexer_advance(l)
		sv_skip_blank(l)
		macro := sv_scan_ident_required(p)
		definition, defined := p.ast.defines[macro]
		lexer_ensure(l, defined, fmt.tprintf("Undefined macro `%s used by `include", macro))
		include_path = strings.trim_space(definition.body)
		if len(include_path) >= 2 && include_path[0] == '"' && include_path[len(include_path) - 1] == '"' {
			include_path = include_path[1:len(include_path) - 1]
		}
	} else {
		lexer_ensure(l, lexer_peek(l) == DOUBLE_QUOTE, "Expected \" after `include")
		include_path = sv_scan_string(p)
	}

	path := sv_resolve_include_path(p, include_path, l.filepath)
	data, read_err := os.read_entire_file_from_path(path, p.allocator)
	ensure(read_err == nil, fmt.tprint("SystemVerilog include read error: ", read_err, " ", path))
	sv_push_input(p, data, path, 0)
}

sv_resolve_include_path :: proc(p: ^SVParser, include_path: string, current_file: string) -> string {
	if sv_path_is_absolute(include_path) {
		return strings.clone(include_path, p.allocator) or_else panic("OOM")
	}
	dir := sv_path_directory(current_file)
	if len(dir) > 0 {
		candidate := fmt.tprintf("%s/%s", dir, include_path)
		if os.exists(candidate) { return strings.clone(candidate, p.allocator) or_else panic("OOM") }
	} else if os.exists(include_path) {
		return strings.clone(include_path, p.allocator) or_else panic("OOM")
	}
	for include_dir in p.ast.include_dirs {
		candidate := fmt.tprintf("%s/%s", include_dir, include_path)
		if os.exists(candidate) { return strings.clone(candidate, p.allocator) or_else panic("OOM") }
	}
	// Flattened benchmark trees: try every directory of already parsed files, first with the
	// full relative path, then with just the basename.
	for file_dir in p.ast.file_dirs {
		candidate := fmt.tprintf("%s/%s", file_dir, include_path)
		if os.exists(candidate) { return strings.clone(candidate, p.allocator) or_else panic("OOM") }
	}
	base := sv_path_basename(include_path)
	for file_dir in p.ast.file_dirs {
		candidate := fmt.tprintf("%s/%s", file_dir, base)
		if os.exists(candidate) { return strings.clone(candidate, p.allocator) or_else panic("OOM") }
	}
	first_candidate := fmt.tprintf("%s/%s", dir, include_path) if len(dir) > 0 else include_path
	lexer_panic(l = &p.l, err_msg = fmt.tprintf("`include not found: %s (include_dirs searched too)", first_candidate))
	return ""
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

SVInactiveResult :: enum {
	ENDIF,
	ELSIF,
	ELSE,
}

// Skip an inactive conditional-compilation region. Stops after the directive that can make
// the region active again (`elsif/`else) or after the matching `endif.
sv_skip_inactive_region :: proc(p: ^SVParser) -> SVInactiveResult {
	l := &p.l
	depth := 0
	for l.idx < len(l.src) {
		c := lexer_peek(l)
		if c == DOUBLE_QUOTE {
			_ = sv_scan_string(p)
			continue
		}
		if c == SLASH && lexer_peek(l, 1) == SLASH {
			for lexer_peek(l) != NEWLINE && lexer_peek(l) != 0 { lexer_advance(l) }
			continue
		}
		if c == SLASH && lexer_peek(l, 1) == ASTERISK {
			lexer_advance(l, 2)
			for !(lexer_peek(l) == ASTERISK && lexer_peek(l, 1) == SLASH) && lexer_peek(l) != 0 { lexer_advance(l) }
			lexer_advance(l, 2)
			continue
		}
		if c == '`' {
			lexer_advance(l)
			sv_skip_blank(l)
			name := ""
			if lexer_is_ident_start(lexer_peek(l)) { name = lexer_scan_ident(l) }
			switch name {
			case "ifdef", "ifndef": depth += 1
			case "endif":
				if depth == 0 { return .ENDIF }
				depth -= 1
			case "elsif": if depth == 0 { return .ELSIF }
			case "else": if depth == 0 { return .ELSE }
			}
			continue
		}
		lexer_advance(l)
	}
	lexer_panic(l, "Unterminated `ifdef/`ifndef")
	return .ENDIF
}

sv_resolve_inactive_branch :: proc(p: ^SVParser, result: SVInactiveResult) {
	switch result {
	case .ENDIF: return
	case .ELSE: append(&p.cond_stack, true)
	case .ELSIF:
		sv_skip_blank(&p.l)
		macro := sv_scan_ident_required(p)
		if macro in p.ast.defines {
			append(&p.cond_stack, true)
		} else {
			sv_resolve_inactive_branch(p, sv_skip_inactive_region(p))
		}
	}
}

// We are inside the active branch of an `ifdef and reached its `elsif/`else: skip the
// remaining alternative branches up to and including the matching `endif.
sv_skip_active_branches :: proc(p: ^SVParser) {
	for {
		if sv_skip_inactive_region(p) == .ENDIF { return }
	}
}

// ---------------------------------------------------------------------------------------
// Lexical helpers
// ---------------------------------------------------------------------------------------

sv_skip_attributes :: proc(p: ^SVParser) {
	for {
		sv_skip_trivia(p)
		if lexer_peek(&p.l) == LPAREN && lexer_peek(&p.l, 1) == ASTERISK {
			check_for_and_handle_attribute(&p.l)
			continue
		}
		return
	}
}

sv_skip_space_tabs :: #force_inline proc(l: ^Lexer) {
	for {
		c := lexer_peek(l)
		if c != WHITESPACE && c != WHITESPACE_TAB { break }
		lexer_advance(l)
	}
}

// Expand a macro at the cursor without pushing an input frame (used for token pasting).
sv_expand_macro_at_cursor :: proc(p: ^SVParser) -> (text: string, ok: bool) {
	l := &p.l
	if lexer_peek(l) != '`' { return "", false }
	start := sv_save(p)
	lexer_advance(l)
	sv_skip_blank(l)
	name := ""
	if lexer_is_ident_start(lexer_peek(l)) { name = lexer_scan_ident(l) }
	if name == "__LINE__" {
		return fmt.aprintf("%d", l.newlines + 1, allocator = p.allocator), true
	}
	if name == "__FILE__" {
		return l.filepath, true
	}
	def, defined := p.ast.defines[name]
	if !defined {
		sv_restore(p, start)
		return "", false
	}
	args: [dynamic]string
	if def.is_function_like {
		sv_skip_ws_and_comments(p)
		if lexer_peek(l) != LPAREN {
			sv_restore(p, start)
			return "", false
		}
		args = sv_scan_macro_args(p)
	}
	return string(sv_expand_macro(p, def, args)), true
}

sv_scan_ident_required :: proc(p: ^SVParser) -> string {
	l := &p.l
	sv_skip_trivia(p)
	c := lexer_peek(l)
	lexer_ensure(l, lexer_is_ident_start(c) || c == ESCAPE_SYMBOL, "Expected an identifier")
	name := lexer_scan_ident(l)
	if lexer_peek(l) != '`' { return name }
	// token pasting: `foo`BAR expands adjacent pieces into one identifier
	b := strings.builder_make(p.allocator)
	strings.write_string(&b, name)
	for lexer_peek(l) == '`' {
		piece, ok := sv_expand_macro_at_cursor(p)
		if !ok { break }
		strings.write_string(&b, piece)
	}
	return strings.to_string(b)
}

sv_peek_ident :: proc(p: ^SVParser) -> string {
	sv_skip_trivia(p)
	start := sv_save(p)
	name := ""
	c := lexer_peek(&p.l)
	if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL { name = lexer_scan_ident(&p.l) }
	sv_restore(p, start)
	return name
}

sv_match_ident :: proc(p: ^SVParser, name: string) -> bool {
	sv_skip_trivia(p)
	start := sv_save(p)
	c := lexer_peek(&p.l)
	if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
		if lexer_scan_ident(&p.l) == name { return true }
	}
	sv_restore(p, start)
	return false
}

sv_scan_system_ident :: proc(p: ^SVParser) -> string {
	l := &p.l
	start := l.idx
	lexer_consume(l, '$')
	for lexer_is_ident_char(lexer_peek(l)) { lexer_advance(l) }
	return string(l.src[start:l.idx])
}

sv_scan_string :: proc(p: ^SVParser) -> string {
	l := &p.l
	// triple-quoted string literal (5.9): """ ... """
	if lexer_peek(l) == DOUBLE_QUOTE && lexer_peek(l, 1) == DOUBLE_QUOTE && lexer_peek(l, 2) == DOUBLE_QUOTE {
		lexer_advance(l, 3)
		start := l.idx
		for l.idx < len(l.src) {
			if lexer_peek(l) == DOUBLE_QUOTE && lexer_peek(l, 1) == DOUBLE_QUOTE && lexer_peek(l, 2) == DOUBLE_QUOTE {
				text := string(l.src[start:l.idx])
				lexer_advance(l, 3)
				return text
			}
			if lexer_peek(l) == ESCAPE_SYMBOL {
				lexer_advance(l, 2)
				continue
			}
			lexer_advance(l)
		}
		lexer_panic(l, "Unterminated triple-quoted string literal")
	}
	lexer_consume(l, DOUBLE_QUOTE)
	start := l.idx
	for l.idx < len(l.src) {
		c := lexer_peek(l)
		if c == ESCAPE_SYMBOL {
			lexer_advance(l, 2)
			continue
		}
		if c == DOUBLE_QUOTE { break }
		if c == NEWLINE || c == NEWLINE_CARRIAGE_RETURN { lexer_panic(l, "Unterminated string literal") }
		lexer_advance(l)
	}
	lexer_ensure(l, lexer_peek(l) == DOUBLE_QUOTE, "Unterminated string literal")
	text := string(l.src[start:l.idx])
	lexer_advance(l)
	return text
}

// ---------------------------------------------------------------------------------------
// Macro expansion
// ---------------------------------------------------------------------------------------

// Expand a defined macro at the cursor (object-like or function-like). Returns false when
// the cursor is not on a defined macro; the caller then handles a compiler directive.
sv_maybe_expand_macro :: proc(p: ^SVParser) -> bool {
	l := &p.l
	if lexer_peek(l) != '`' { return false }
	start := sv_save(p)
	lexer_advance(l)
	sv_skip_blank(l)
	name := ""
	if lexer_is_ident_start(lexer_peek(l)) { name = lexer_scan_ident(l) }
	if name == "__FILE__" || name == "__LINE__" {
		text: string
		if name == "__FILE__" {
			b := strings.builder_make(p.allocator)
			strings.write_byte(&b, '"')
			for c in l.filepath {
				if c == '\\' || c == '"' { strings.write_byte(&b, '\\') }
				strings.write_byte(&b, u8(c))
			}
			strings.write_byte(&b, '"')
			text = strings.to_string(b)
		} else {
			text = fmt.aprintf("%d", l.newlines + 1, allocator = p.allocator)
		}
		sv_push_input(p, sv_bytes_copy(p, text), l.filepath, l.newlines)
		return true
	}
	def, defined := p.ast.defines[name]
	if !defined {
		sv_restore(p, start)
		return false
	}
	args: [dynamic]string
	if def.is_function_like {
		sv_skip_ws_and_comments(p)
		lexer_ensure(l, lexer_peek(l) == LPAREN, fmt.tprintf("Macro `%s expects an argument list", name))
		args = sv_scan_macro_args(p)
	}
	text := sv_expand_macro(p, def, args)
	sv_push_input(p, text, l.filepath, l.newlines)
	return true
}

// Raw argument text between balanced parentheses, split on top-level commas.
sv_scan_macro_args :: proc(p: ^SVParser) -> [dynamic]string {
	l := &p.l
	args := make([dynamic]string, p.allocator)
	lexer_consume(l, LPAREN)
	sv_skip_ws_and_comments(p)
	if lexer_peek(l) == RPAREN {
		lexer_advance(l)
		return args
	}
	paren_depth := 0
	brace_depth := 0
	bracket_depth := 0
	arg_start := l.idx
	for {
		c := lexer_peek(l)
		lexer_ensure(l, l.idx < len(l.src), "Unterminated macro argument list")
		if c == DOUBLE_QUOTE {
			_ = sv_scan_string(p)
			continue
		}
		if c == SLASH && (lexer_peek(l, 1) == SLASH || lexer_peek(l, 1) == ASTERISK) {
			netlist_handle_comments(l)
			continue
		}
		switch c {
		case LPAREN:
			paren_depth += 1
		case RPAREN:
			if paren_depth == 0 && brace_depth == 0 && bracket_depth == 0 {
				append(&args, sv_trim_space(l.src[arg_start:l.idx]))
				lexer_advance(l)
				return args
			}
			if paren_depth > 0 { paren_depth -= 1 }
		case LCURLY:
			brace_depth += 1
		case RCURLY:
			if brace_depth > 0 { brace_depth -= 1 }
		case L_SQUARE_BRACKET:
			bracket_depth += 1
		case R_SQUARE_BRACKET:
			if bracket_depth > 0 { bracket_depth -= 1 }
		case COMMA:
			if paren_depth == 0 && brace_depth == 0 && bracket_depth == 0 {
				append(&args, sv_trim_space(l.src[arg_start:l.idx]))
				lexer_advance(l)
				arg_start = l.idx
				continue
			}
		}
		lexer_advance(l)
	}
}

// Substitute formal parameters in the replacement text. Plain identifiers matching a
// parameter are replaced by the corresponding argument text; everything else is copied
// verbatim and re-lexed by the normal parser (which also handles nested macro uses).
sv_expand_macro :: proc(p: ^SVParser, def: SVDefine, args: [dynamic]string) -> []byte {
	b := strings.builder_make(p.allocator)
	body := def.body
	i := 0
	in_macro_string := false
	for i < len(body) {
		c := body[i]
		if c == '`' {
			if i + 3 < len(body) && body[i + 1] == '\\' && body[i + 2] == '`' && body[i + 3] == '"' { // `\`"
				strings.write_string(&b, "\\\"")
				i += 4
				continue
			}
			if i + 1 < len(body) && body[i + 1] == '"' { // `"
				strings.write_byte(&b, '"')
				in_macro_string = !in_macro_string
				i += 2
				continue
			}
			if i + 1 < len(body) && body[i + 1] == '`' { // `` joins tokens, emits nothing
				i += 2
				continue
			}
			strings.write_byte(&b, '`') // nested macro usage, expanded on re-lex
			i += 1
			continue
		}
		if c == '"' && !in_macro_string {
			// literal string: copied verbatim, no macro/argument substitution
			j := i + 1
			if i + 2 < len(body) && body[i + 1] == '"' && body[i + 2] == '"' {
				// triple-quoted string
				j = i + 3
				for j + 2 < len(body) {
					if body[j] == '"' && body[j + 1] == '"' && body[j + 2] == '"' {
						j += 3
						break
					}
					j += 1
				}
			} else {
				for j < len(body) {
					if body[j] == ESCAPE_SYMBOL {
						j += 2
						continue
					}
					j += 1
					if body[j - 1] == '"' { break }
				}
			}
			strings.write_string(&b, body[i:j])
			i = j
			continue
		}
		if def.is_function_like && (lexer_is_ident_start(c) || c == ESCAPE_SYMBOL) {
			j := i + 1
			if c == ESCAPE_SYMBOL {
				for j < len(body) {
					ch := body[j]
					if ch == WHITESPACE || ch == WHITESPACE_TAB || ch == NEWLINE || ch == NEWLINE_CARRIAGE_RETURN { break }
					j += 1
				}
			} else {
				for j < len(body) && lexer_is_ident_char(body[j]) { j += 1 }
			}
			word := body[i:j]
			substituted := false
			for param, k in def.params {
				if param == word {
					if k < len(args) {
						strings.write_string(&b, args[k])
					} else if k < len(def.param_defaults) {
						strings.write_string(&b, def.param_defaults[k])
					}
					substituted = true
					break
				}
			}
			if !substituted { strings.write_string(&b, word) }
			i = j
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return b.buf[:]
}

sv_is_decimal_digit :: #force_inline proc(c: byte) -> bool { return c >= '0' && c <= '9' }

sv_is_hex_digit :: #force_inline proc(c: byte) -> bool {
	return sv_is_decimal_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

sv_is_number_digit :: #force_inline proc(c: byte) -> bool {
	return sv_is_hex_digit(c) || c == 'x' || c == 'X' || c == 'z' || c == 'Z' || c == '?' || c == '_'
}

sv_is_base_char :: #force_inline proc(c: byte) -> bool {
	return c == 'b' || c == 'B' || c == 'o' || c == 'O' || c == 'd' || c == 'D' || c == 'h' || c == 'H'
}

sv_number_base_of :: #force_inline proc(c: byte) -> SVNumberBase {
	switch c {
	case 'b', 'B': return .BIN
	case 'o', 'O': return .OCT
	case 'd', 'D': return .DEC
	case: return .HEX
	}
}

sv_parse_size_text :: proc(text: string) -> u32 {
	size: u32
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '_' { continue }
		if !sv_is_decimal_digit(c) { break }
		size = size * 10 + u32(c - '0')
	}
	return size
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
		d: u64
		switch c {
		case '_': continue
		case '0' ..= '9': d = u64(c - '0')
		case 'a' ..= 'f': d = u64(c - 'a' + 10)
		case 'A' ..= 'F': d = u64(c - 'A' + 10)
		case 'x', 'X', 'z', 'Z', '?':
			has_x_z = true
			continue
		case: continue
		}
		value = value * radix + d
	}
	return
}

// [size]'[s]base digits | plain decimal | real literal
sv_scan_number :: proc(p: ^SVParser) -> SVNumber {
	l := &p.l
	num: SVNumber
	text_start := l.idx
	for sv_is_decimal_digit(lexer_peek(l)) || lexer_peek(l) == '_' { lexer_advance(l) }
	size_text := string(l.src[text_start:l.idx])
	// `XLEN'd4`: the size is macro-expanded, the base follows in the parent input
	sv_pop_exhausted_inputs(p)

	is_real := false
	if lexer_peek(l) == DOT && sv_is_decimal_digit(lexer_peek(l, 1)) {
		is_real = true
		lexer_advance(l)
		for sv_is_decimal_digit(lexer_peek(l)) || lexer_peek(l) == '_' { lexer_advance(l) }
	}
	next := lexer_peek(l)
	if (next == 'e' || next == 'E') &&
	   (sv_is_decimal_digit(lexer_peek(l, 1)) || ((lexer_peek(l, 1) == '+' || lexer_peek(l, 1) == '-') && sv_is_decimal_digit(lexer_peek(l, 2)))) {
		is_real = true
		lexer_advance(l)
		if lexer_peek(l) == '+' || lexer_peek(l) == '-' { lexer_advance(l) }
		for sv_is_decimal_digit(lexer_peek(l)) || lexer_peek(l) == '_' { lexer_advance(l) }
	}
	if is_real {
		text := string(l.src[text_start:l.idx])
		value, _ := strconv.parse_f64(text)
		return SVNumber{raw = text, is_real = true, real_value = value, time_unit = sv_scan_time_unit(p)}
	}

	if lexer_peek(l) == SINGLE_QUOTE {
		base_char := lexer_peek(l, 1)
		is_based := sv_is_base_char(base_char)
		if base_char == 's' || base_char == 'S' { is_based = sv_is_base_char(lexer_peek(l, 2)) }
		if is_based {
			signed := false
			lexer_advance(l) // '
			sv_skip_space_tabs(l)
			c := lexer_peek(l)
			if c == 's' || c == 'S' {
				signed = true
				lexer_advance(l)
				sv_skip_space_tabs(l)
				c = lexer_peek(l)
			}
			base := sv_number_base_of(c)
			lexer_advance(l)
			sv_skip_space_tabs(l)
			digits_start := l.idx
			for sv_is_number_digit(lexer_peek(l)) { lexer_advance(l) }
			digits := string(l.src[digits_start:l.idx])
			value, has_x_z := sv_decode_number(digits, base)
			return SVNumber{raw = digits, width = sv_parse_size_text(size_text), base = base, is_signed = signed, value = value, has_x_z = has_x_z}
		}
	}

	value, has_x_z := sv_decode_number(size_text, .DEC)
	return SVNumber {
		raw       = size_text,
		base      = .DEC,
		is_signed = true, // unsized decimal literals are signed
		value     = value,
		has_x_z   = has_x_z,
		time_unit = sv_scan_time_unit(p),
	}
}

// Time unit directly following a number: s | ms | us | ns | ps | fs (no whitespace).
sv_scan_time_unit :: proc(p: ^SVParser) -> string {
	l := &p.l
	start := l.idx
	for lexer_is_ident_char(lexer_peek(l)) { lexer_advance(l) }
	unit := string(l.src[start:l.idx])
	switch unit {
	case "s", "ms", "us", "ns", "ps", "fs":
		return unit
	}
	l.idx = start
	return ""
}

// '0 '1 'x 'z : one bit whose value depends on the expression width
sv_scan_unbased_number :: proc(p: ^SVParser) -> SVNumber {
	l := &p.l
	lexer_consume(l, SINGLE_QUOTE)
	c := lexer_peek(l)
	num: SVNumber
	switch c {
	case '0': num = SVNumber {
				raw        = "0",
				is_signed  = true,
				is_unbased = true,
			}
	case '1': num = SVNumber {
				raw        = "1",
				is_signed  = true,
				is_unbased = true,
				value      = 1,
			}
	case 'x', 'X', 'z', 'Z', '?': num = SVNumber {
				raw        = string(l.src[l.idx:l.idx + 1]),
				is_signed  = true,
				is_unbased = true,
				has_x_z    = true,
			}
	case: lexer_panic(l, "Invalid unbased literal after '")
	}
	lexer_advance(l)
	return num
}

// ---------------------------------------------------------------------------------------
// Types, ranges, declarators
// ---------------------------------------------------------------------------------------

sv_var_type_keyword :: proc(name: string) -> (SVVarType, bool) {
	switch name {
	case "logic": return .LOGIC, true
	case "bit": return .BIT, true
	case "reg": return .REG, true
	case "int": return .INT, true
	case "integer": return .INTEGER, true
	case "shortint": return .SHORTINT, true
	case "longint": return .LONGINT, true
	case "byte": return .BYTE, true
	case "time": return .TIME, true
	case "real": return .REAL, true
	case "shortreal": return .SHORTREAL, true
	case "realtime": return .REALTIME, true
	case "string": return .STRING, true
	}
	return .IMPLICIT, false
}

sv_net_type_keyword :: proc(name: string) -> (SVNetType, bool) {
	switch name {
	case "wire": return .WIRE, true
	case "tri": return .TRI, true
	case "wand": return .WAND, true
	case "wor": return .WOR, true
	case "triand": return .TRIAND, true
	case "trior": return .TRIOR, true
	case "tri0": return .TRI0, true
	case "tri1": return .TRI1, true
	case "trireg": return .TRIREG, true
	case "supply0": return .SUPPLY0, true
	case "supply1": return .SUPPLY1, true
	case "uwire": return .UWIRE, true
	}
	return .NONE, false
}

sv_port_dir_keyword :: proc(name: string) -> (SVPortDir, bool) {
	switch name {
	case "input": return .INPUT, true
	case "output": return .OUTPUT, true
	case "inout": return .INOUT, true
	}
	return .NONE, false
}

sv_is_decl_keyword :: proc(name: string) -> bool {
	if _, ok := sv_var_type_keyword(name); ok { return true }
	if _, ok := sv_net_type_keyword(name); ok { return true }
	switch name {
	case "var", "const", "automatic", "static", "signed", "unsigned", "enum", "struct", "union", "string", "parameter", "localparam":
		return true
	}
	return false
}

sv_parse_type_signing_and_dims :: proc(p: ^SVParser, base: SVDataType) -> SVDataType {
	l := &p.l
	data := base
	sv_skip_trivia(p)
	if sv_match_ident(p, "signed") {
		data.is_signed = true
	} else if sv_match_ident(p, "unsigned") {
		data.is_signed = false
	}
	sv_skip_trivia(p)
	for lexer_peek(l) == L_SQUARE_BRACKET {
		append(&data.packed_dims, sv_parse_packed_dim(p))
		sv_skip_trivia(p)
	}
	return data
}

// data_type_or_implicit: type keyword, user-defined type, inline enum/struct/union,
// signing and packed dimensions.
sv_parse_data_type_or_implicit :: proc(p: ^SVParser) -> SVDataType {
	data: SVDataType
	name := sv_peek_ident(p)
	if vt, ok := sv_var_type_keyword(name); ok {
		_ = sv_scan_ident_required(p)
		data.var_type = vt
	} else if name == "var" {
		_ = sv_scan_ident_required(p)
	} else if name == "enum" {
		_ = sv_scan_ident_required(p)
		data.spec = sv_parse_type_spec_body(p, .ENUM)
	} else if name == "struct" || name == "union" {
		_ = sv_scan_ident_required(p)
		data.spec = sv_parse_type_spec_body(p, name == "struct" ? .STRUCT : .UNION)
	} else {
		data.type_scope, data.type_name = sv_parse_type_reference(p)
	}
	return sv_parse_type_signing_and_dims(p, data)
}

// True when a data type can start at the cursor (used to distinguish ANSI ports, type
// arguments and declarations from plain identifiers).
// Distinguishes a type argument (`#(.T(logic [3:0]))`) from an expression; a signing
// cast (`unsigned'(x)`) is an expression, not a type.
sv_starts_type_argument :: proc(p: ^SVParser) -> bool {
	l := &p.l
	start := sv_save(p)
	sv_skip_ws_and_comments(p)
	result := false
	c := lexer_peek(l)
	if c == L_SQUARE_BRACKET {
		result = true // implicit packed type argument
	} else if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
		name := lexer_scan_ident(l)
		sv_skip_space_tabs(l)
		switch name {
		case "struct", "enum", "union":
			result = true
		case "signed", "unsigned":
			result = lexer_peek(l) != SINGLE_QUOTE && lexer_peek(l) != LPAREN
		case:
			qualified := lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON
			if qualified {
				lexer_advance(l, 2)
				sv_skip_ws_and_comments(p)
				if lexer_is_ident_start(lexer_peek(l)) { _ = lexer_scan_ident(l) }
				sv_skip_space_tabs(l)
			}
			_, is_builtin := sv_var_type_keyword(name)
			known_type := is_builtin || qualified || name in p.ast.type_names || name in p.ast.iface_names
			if known_type {
				next := lexer_peek(l)
				// a type argument ends here or has packed dimensions; anything else
				// (operators, casts) is an expression
				result = next == RPAREN || next == L_SQUARE_BRACKET
			}
		}
	}
	sv_restore(p, start)
	return result
}

sv_starts_data_type :: proc(p: ^SVParser) -> bool {
	l := &p.l
	sv_skip_ws_and_comments(p)
	c := lexer_peek(l)
	if c == L_SQUARE_BRACKET { return true }
	if !lexer_is_ident_start(c) && c != ESCAPE_SYMBOL { return false }
	start := sv_save(p)
	name := lexer_scan_ident(l)
	result := false
	switch name {
	case "enum", "struct", "union", "signed", "unsigned", "var":
		result = true
	case:
		if _, ok := sv_var_type_keyword(name); ok {
			result = true
		} else if name in p.ast.type_names || name in p.ast.iface_names {
			result = true
		} else {
			sv_skip_space_tabs(l)
			result = lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON
		}
	}
	sv_restore(p, start)
	return result
}

// Returns ("", "") when the next token is not a known user-defined type reference.
sv_parse_type_reference :: proc(p: ^SVParser) -> (scope: string, name: string) {
	l := &p.l
	sv_skip_trivia(p)
	start := sv_save(p)
	c := lexer_peek(l)
	if !lexer_is_ident_start(c) && c != ESCAPE_SYMBOL { return }
	first := lexer_scan_ident(l)
	sv_skip_space_tabs(l)
	if lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON {
		lexer_advance(l, 2)
		sv_skip_trivia(p)
		return first, sv_scan_ident_required(p)
	}
	if first in p.ast.type_names || first in p.ast.iface_names { return "", first }
	sv_restore(p, start)
	return
}

// enum / struct / union body (keyword already consumed).
sv_parse_type_spec_body :: proc(p: ^SVParser, kind: SVTypeSpecKind) -> ^SVTypeSpec {
	l := &p.l
	spec := sv_new(p, SVTypeSpec)
	spec.kind = kind
	if kind == .ENUM {
		sv_skip_trivia(p)
		if lexer_peek(l) != LCURLY {
			spec.base = sv_parse_data_type_or_implicit(p)
		}
		sv_skip_trivia(p)
		lexer_consume(l, LCURLY)
		sv_skip_trivia(p)
		for {
			entry := SVEnumName {
				name = sv_scan_ident_required(p),
			}
			sv_skip_trivia(p)
			if lexer_peek(l) == L_SQUARE_BRACKET {
				// optional enum range NAME[lo:hi]; syntactic only
				for lexer_peek(l) != R_SQUARE_BRACKET && lexer_peek(l) != 0 { lexer_advance(l) }
				lexer_consume(l, R_SQUARE_BRACKET)
				sv_skip_trivia(p)
			}
			if lexer_peek(l) == EQUAL {
				lexer_advance(l)
				sv_skip_trivia(p)
				entry.value = sv_new_expr(p, sv_parse_expr(p, 0))
			}
			append(&spec.enum_names, entry)
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				sv_skip_trivia(p)
				continue
			}
			break
		}
		lexer_consume(l, RCURLY)
		return spec
	}

	// struct / union
	sv_skip_trivia(p)
	if sv_match_ident(p, "packed") {
		spec.is_packed = true
		_ = sv_match_ident(p, "signed")
	}
	sv_skip_trivia(p)
	lexer_consume(l, LCURLY)
	for {
		sv_skip_trivia(p)
		if lexer_peek(l) == RCURLY { break }
		data := sv_parse_data_type_or_implicit(p)
		// A member always has a data type, so an identifier that the type parser did not
		// recognize (e.g. a type imported from a package compiled separately) is the type.
		if data.type_name == "" &&
		   data.var_type == .IMPLICIT &&
		   data.spec == nil &&
		   len(data.packed_dims) == 0 &&
		   !data.is_signed {
			sv_skip_trivia(p)
			if name := sv_peek_ident(p); name != "" {
				data.type_name = sv_scan_ident_required(p)
				data = sv_parse_type_signing_and_dims(p, data)
			}
		}
		member := SVStructMember {
			data        = data,
			declarators = sv_parse_declarators(p),
		}
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		append(&spec.members, member)
	}
	lexer_consume(l, RCURLY)
	return spec
}

// typedef declaration (keyword consumed).
sv_parse_typedef :: proc(p: ^SVParser) -> ^SVTypeDecl {
	l := &p.l
	decl := sv_new(p, SVTypeDecl)
	decl.data = sv_parse_data_type_or_implicit(p)
	sv_skip_trivia(p)
	decl.name = sv_scan_ident_required(p)
	sv_skip_trivia(p)
	for lexer_peek(l) == L_SQUARE_BRACKET {
		append(&decl.unpacked_dims, sv_parse_unpacked_dim(p))
		sv_skip_trivia(p)
	}
	lexer_consume(l, SEMICOLON)
	p.ast.type_names[decl.name] = true
	return decl
}

// Declaration that begins with an already-consumed user-defined type name.
sv_parse_decl_after_type_name :: proc(p: ^SVParser, first: string) -> ^SVNetDecl {
	l := &p.l
	data := SVDataType{type_name = first}
	sv_skip_trivia(p)
	if lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON {
		lexer_advance(l, 2)
		data.type_scope = first
		data.type_name = sv_scan_ident_required(p)
	}
	data = sv_parse_type_signing_and_dims(p, data)
	return sv_parse_declaration_body(p, .NONE, data)
}

// After an identifier was scanned: is this the start of a declaration of a user-defined
// type (`type_t x;`, `pkg::type_t x;`) rather than an instantiation/statement?
// True when two identifiers appear in a row at the cursor (`TYPE name`).
sv_two_idents_ahead :: proc(p: ^SVParser) -> bool {
	l := &p.l
	start := sv_save(p)
	sv_skip_ws_and_comments(p)
	if !lexer_is_ident_start(lexer_peek(l)) && lexer_peek(l) != ESCAPE_SYMBOL {
		sv_restore(p, start)
		return false
	}
	_ = lexer_scan_ident(l)
	sv_skip_ws_and_comments(p)
	result := lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL
	sv_restore(p, start)
	return result
}

sv_ident_follows :: proc(p: ^SVParser) -> bool {
	l := &p.l
	start := sv_save(p)
	sv_skip_ws_and_comments(p)
	result := lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL
	sv_restore(p, start)
	return result
}

sv_is_user_type_decl_start :: proc(p: ^SVParser, name: string) -> bool {
	if name in p.ast.type_names || name in p.ast.iface_names { return true }
	l := &p.l
	start := sv_save(p)
	sv_skip_space_tabs(l)
	is_qualified := false
	if lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON {
		lexer_advance(l, 2)
		sv_skip_trivia(p)
		if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL {
			_ = lexer_scan_ident(l)
			sv_skip_space_tabs(l)
			// A scoped type declaration is followed by the declared name or packed dims.
			// `pkg::task;` / `pkg::func(...)` are scoped calls, not declarations.
			c := lexer_peek(l)
			is_qualified = lexer_is_ident_start(c) || c == ESCAPE_SYMBOL || c == L_SQUARE_BRACKET
		}
	}
	sv_restore(p, start)
	return is_qualified
}

// import pkg::name, pkg2::*; (keyword consumed)
sv_parse_import_list :: proc(p: ^SVParser, imports: ^[dynamic]SVImport) {
	l := &p.l
	sv_skip_trivia(p)
	if lexer_peek(l) == DOUBLE_QUOTE {
		// import "DPI-C" ...;  (not synthesizable)
		sv_skip_to_semicolon(p)
		return
	}
	for {
		sv_skip_trivia(p)
		pkg_name := sv_scan_ident_required(p)
		sv_skip_trivia(p)
		lexer_consume(l, COLON)
		lexer_consume(l, COLON)
		sv_skip_trivia(p)
		name := "*"
		if lexer_peek(l) == ASTERISK {
			lexer_advance(l)
		} else {
			name = sv_scan_ident_required(p)
			p.ast.type_names[name] = true
		}
		append(imports, SVImport{package_name = pkg_name, name = name})
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	lexer_consume(l, SEMICOLON)
}

// package name; { package_item } endpackage [: name]
sv_parse_package :: proc(p: ^SVParser) -> ^SVPackage {
	l := &p.l
	name := sv_scan_ident_required(p)
	pkg := sv_new(p, SVPackage)
	pkg^ = SVPackage {
		name    = name,
		imports = make([dynamic]SVImport, p.allocator),
		items   = make([dynamic]SVItem, p.allocator),
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, fmt.tprintf("Unterminated package '%s'", name))
		}
		if sv_match_ident(p, "endpackage") {
			sv_skip_optional_end_label(p)
			break
		}
		sv_parse_package_item(p, pkg)
	}
	if p.ast.package_hash_map[name] != nil {
		lexer_panic(l, fmt.tprintf("Duplicate package '%s'", name))
	}
	p.ast.package_hash_map[name] = pkg
	append(&p.ast.packages, pkg)
	return pkg
}

sv_parse_package_item :: proc(p: ^SVParser, pkg: ^SVPackage) {
	sv_skip_trivia(p)
	sv_skip_attributes(p)
	sv_skip_trivia(p)
	if sv_at_eof(p) { return }
	l := &p.l
	c := lexer_peek(l)
	if c == SEMICOLON {
		lexer_advance(l)
		return
	}
	if c == '$' {
		append(&pkg.items, sv_parse_system_task_item(p))
		return
	}
	if !lexer_is_ident_start(c) && c != ESCAPE_SYMBOL {
		lexer_panic(l, fmt.tprintf("Unexpected character '%r' in package body", c))
	}
	name := lexer_scan_ident(l)
	switch name {
	case "typedef":
		append(&pkg.items, sv_parse_typedef(p))
	case "parameter", "localparam":
		decl := sv_parse_param_decl_after_keyword(p, name == "localparam")
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		append(&pkg.items, decl)
	case "function":
		append(&pkg.items, sv_parse_subroutine(p, false))
	case "task":
		append(&pkg.items, sv_parse_subroutine(p, true))
	case "import":
		sv_parse_import_list(p, &pkg.imports)
	case "export", "timeunit", "timeprecision", "nettype":
		sv_skip_to_semicolon(p)
	case "class":
		sv_skip_until_ident(p, "endclass")
		sv_skip_optional_end_label(p)
	case "covergroup":
		sv_skip_until_ident(p, "endgroup")
		sv_skip_optional_end_label(p)
	case "wire", "tri", "wand", "wor", "triand", "trior", "tri0", "tri1", "trireg", "supply0", "supply1", "uwire":
		append(&pkg.items, sv_parse_net_var_decl(p, name))
	case "reg", "logic", "bit", "int", "integer", "shortint", "longint", "byte", "time", "real", "shortreal", "realtime", "var", "const", "signed", "unsigned":
		append(&pkg.items, sv_parse_net_var_decl(p, name))
	case:
		if sv_is_user_type_decl_start(p, name) {
			append(&pkg.items, sv_parse_decl_after_type_name(p, name))
		} else {
			lexer_panic(l, fmt.tprintf("Unsupported package item '%s'", name))
		}
	}
}

// Skip a nonsynthesizable construct up to and including `keyword` (e.g. class/endclass).
sv_skip_until_ident :: proc(p: ^SVParser, keyword: string) {
	l := &p.l
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, fmt.tprintf("Unterminated construct: expected '%s'", keyword))
		}
		c := lexer_peek(l)
		if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
			if lexer_scan_ident(l) == keyword { return }
		} else if c == DOUBLE_QUOTE {
			_ = sv_scan_string(p)
		} else {
			lexer_advance(l)
		}
	}
}

sv_skip_optional_end_label :: proc(p: ^SVParser) {
	sv_skip_space_tabs(&p.l)
	if lexer_peek(&p.l) == COLON {
		lexer_advance(&p.l)
		sv_skip_space_tabs(&p.l)
		_ = sv_scan_ident_required(p)
	}
}

// interface name [header] ; { interface_item } endinterface [: name]
sv_parse_interface :: proc(p: ^SVParser) -> ^SVInterface {
	l := &p.l
	name := sv_scan_ident_required(p)
	iface := sv_new(p, SVInterface)
	iface^ = SVInterface {
		name     = name,
		imports  = make([dynamic]SVImport, p.allocator),
		params   = make([dynamic]^SVParamDecl, p.allocator),
		ports    = make([dynamic]^SVPort, p.allocator),
		items    = make([dynamic]SVItem, p.allocator),
		modports = make([dynamic]SVModport, p.allocator),
	}
	sv_skip_trivia(p)
	if sv_match_ident(p, "automatic") || sv_match_ident(p, "static") {
		// lifetime, not represented
	}
	for sv_match_ident(p, "import") {
		sv_parse_import_list(p, &iface.imports)
	}
	sv_skip_trivia(p)
	if lexer_peek(l) == '#' {
		sv_parse_param_port_list(p, &iface.params)
		sv_skip_trivia(p)
	}
	header := sv_new(p, SVModule)
	header.ports = iface.ports
	header.imports = iface.imports
	if lexer_peek(l) == LPAREN {
		sv_parse_module_ports(p, header)
		sv_skip_trivia(p)
	}
	lexer_consume(l, SEMICOLON)
	sv_skip_trivia(p)

	previous_module := p.module
	p.module = header
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			p.module = previous_module
			lexer_panic(l, fmt.tprintf("Unterminated interface '%s'", name))
		}
		if sv_match_ident(p, "endinterface") {
			sv_skip_optional_end_label(p)
			break
		}
		if sv_peek_ident(p) == "modport" {
			_ = sv_scan_ident_required(p)
			sv_parse_modports(p, iface)
			continue
		}
		if sv_match_ident(p, "clocking") {
			sv_skip_until_ident(p, "endclocking")
			sv_skip_optional_end_label(p)
			continue
		}
		if sv_match_ident(p, "default") {
			sv_skip_to_semicolon(p)
			continue
		}
		sv_parse_module_item(p, &iface.items)
	}
	p.module = previous_module
	iface.ports = header.ports
	iface.imports = header.imports

	if p.ast.interface_hash_map[name] != nil {
		lexer_panic(l, fmt.tprintf("Duplicate interface '%s'", name))
	}
	// interface names can be used as port/declaration types (`AXI_BUS axi`)
	p.ast.iface_names[name] = true
	p.ast.interface_hash_map[name] = iface
	append(&p.ast.interfaces, iface)
	return iface
}

sv_parse_modports :: proc(p: ^SVParser, iface: ^SVInterface) {
	l := &p.l
	for {
		sv_skip_trivia(p)
		modport := SVModport {
			name  = sv_scan_ident_required(p),
			ports = make([dynamic]SVModportPort, p.allocator),
		}
		sv_skip_trivia(p)
		lexer_consume(l, LPAREN)
		sv_skip_trivia(p)
		dir := SVPortDir.NONE
		for {
			sv_skip_trivia(p)
			c := lexer_peek(l)
			if c == RPAREN || c == 0 { break }
			if c == COMMA {
				lexer_advance(l)
				continue
			}
			if c == DOT {
				// .name(expression) modport port
				lexer_advance(l)
				_ = sv_scan_ident_required(p)
				sv_skip_trivia(p)
				if lexer_peek(l) == LPAREN {
					sv_skip_balanced_parens(p)
				}
				continue
			}
			if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
				item_name := lexer_scan_ident(l)
				switch item_name {
				case "input":
					dir = .INPUT
				case "output":
					dir = .OUTPUT
				case "inout":
					dir = .INOUT
				case "ref":
					dir = .REF
				case "clocking":
					_ = sv_scan_ident_required(p) // clocking block name
				case "import", "export":
					// task/function prototypes; skip to the end of the list
					for lexer_peek(l) != RPAREN && lexer_peek(l) != 0 {
						if lexer_peek(l) == LPAREN { sv_skip_balanced_parens(p) } else { lexer_advance(l) }
					}
				case:
					append(&modport.ports, SVModportPort{dir = dir, name = item_name})
				}
				continue
			}
			lexer_advance(l)
		}
		lexer_consume(l, RPAREN)
		append(&iface.modports, modport)
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	lexer_consume(l, SEMICOLON)
}

// `iface.modport` lookahead (ANSI/interface ports).
sv_peek_interface_port :: proc(p: ^SVParser) -> (iface: string, modport: string, ok: bool) {
	l := &p.l
	sv_skip_ws_and_comments(p)
	start := sv_save(p)
	c := lexer_peek(l)
	if !lexer_is_ident_start(c) && c != ESCAPE_SYMBOL { return }
	first := lexer_scan_ident(l)
	sv_skip_space_tabs(l)
	if lexer_peek(l) != DOT { sv_restore(p, start); return }
	lexer_advance(l)
	sv_skip_space_tabs(l)
	if !lexer_is_ident_start(lexer_peek(l)) && lexer_peek(l) != ESCAPE_SYMBOL {
		sv_restore(p, start)
		return
	}
	second := lexer_scan_ident(l)
	sv_restore(p, start)
	return first, second, true
}

// `iface.modport names;` after the interface name was already scanned.
sv_parse_iface_decl_after_name :: proc(p: ^SVParser, iface: string) -> ^SVNetDecl {
	l := &p.l
	sv_skip_space_tabs(l)
	lexer_consume(l, DOT)
	sv_skip_space_tabs(l)
	modport := sv_scan_ident_required(p)
	sv_skip_trivia(p)
	decl := sv_new(p, SVNetDecl)
	decl.declarators = sv_parse_declarators(p)
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	for d in decl.declarators {
		port := sv_find_port(p.module, d.name)
		if port != nil {
			port.iface_name = iface
			port.modport = modport
			port.unpacked_dims = d.unpacked_dims
		}
	}
	return decl
}


sv_raw_skip_balanced :: proc(p: ^SVParser, open: byte, close: byte) {
	l := &p.l
	depth := 0
	for {
		c := lexer_peek(l)
		lexer_ensure(l, l.idx < len(l.src), "Unterminated bracket")
		if c == DOUBLE_QUOTE {
			_ = sv_scan_string(p)
			continue
		}
		if c == open { depth += 1 }
		if c == close {
			depth -= 1
			if depth == 0 {
				lexer_advance(l)
				return
			}
		}
		lexer_advance(l)
	}
}

// Cursor is after a cell/interface name. True when the item looks like an instantiation
// (`CELL [#(params)] inst [dims] (`) rather than a variable declaration.
sv_item_after_cell_is_instantiation :: proc(p: ^SVParser) -> bool {
	l := &p.l
	start := sv_save(p)
	sv_skip_ws_and_comments(p)
	if lexer_peek(l) == '#' {
		lexer_advance(l)
		sv_skip_ws_and_comments(p)
		if lexer_peek(l) == LPAREN { sv_raw_skip_balanced(p, LPAREN, RPAREN) }
	}
	sv_skip_ws_and_comments(p)
	if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL {
		_ = lexer_scan_ident(l)
	}
	sv_skip_ws_and_comments(p)
	for lexer_peek(l) == L_SQUARE_BRACKET {
		sv_raw_skip_balanced(p, L_SQUARE_BRACKET, R_SQUARE_BRACKET)
		sv_skip_ws_and_comments(p)
	}
	result := lexer_peek(l) == LPAREN
	sv_restore(p, start)
	return result
}

sv_is_iface_decl_after_name :: proc(p: ^SVParser) -> bool {
	start := sv_save(p)
	sv_skip_space_tabs(&p.l)
	result := lexer_peek(&p.l) == DOT
	sv_restore(p, start)
	return result
}

sv_parse_packed_dim :: proc(p: ^SVParser) -> SVRange {
	l := &p.l
	lexer_consume(l, L_SQUARE_BRACKET)
	sv_skip_trivia(p)
	if lexer_peek(l) == R_SQUARE_BRACKET {
		lexer_panic(l, "Unsized packed dimensions are not supported")
	}
	msb := sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, COLON)
	sv_skip_trivia(p)
	lsb := sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, R_SQUARE_BRACKET)
	return SVRange{msb = msb, lsb = lsb}
}

// [msb:lsb] or [size]; also used for port part-selects and instance arrays.
sv_parse_unpacked_dim :: proc(p: ^SVParser) -> SVRange {
	l := &p.l
	lexer_consume(l, L_SQUARE_BRACKET)
	sv_skip_trivia(p)
	if lexer_peek(l) == R_SQUARE_BRACKET {
		lexer_panic(l, "Unsized unpacked dimensions are not supported")
	}
	first := sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	if lexer_peek(l) == COLON {
		lexer_advance(l)
		sv_skip_trivia(p)
		second := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		lexer_consume(l, R_SQUARE_BRACKET)
		return SVRange{msb = first, lsb = second}
	}
	lexer_consume(l, R_SQUARE_BRACKET)
	return SVRange{msb = first, is_size = true}
}

sv_parse_declarators :: proc(p: ^SVParser) -> [dynamic]SVDeclarator {
	l := &p.l
	declarators := make([dynamic]SVDeclarator, p.allocator)
	for {
		sv_skip_trivia(p)
		d := SVDeclarator {
			name          = sv_scan_ident_required(p),
			unpacked_dims = make([dynamic]SVRange, p.allocator),
		}
		sv_skip_trivia(p)
		for lexer_peek(l) == L_SQUARE_BRACKET {
			append(&d.unpacked_dims, sv_parse_unpacked_dim(p))
			sv_skip_trivia(p)
		}
		if lexer_peek(l) == EQUAL {
			lexer_advance(l)
			sv_skip_trivia(p)
			d.init = sv_new_expr(p, sv_parse_expr(p, 0))
		}
		append(&declarators, d)
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	return declarators
}

// Declarators followed by the terminating semicolon.
sv_parse_declaration_body :: proc(p: ^SVParser, net_type: SVNetType, data: SVDataType) -> ^SVNetDecl {
	l := &p.l
	decl := sv_new(p, SVNetDecl)
	decl.net_type = net_type
	decl.data = data
	decl.declarators = sv_parse_declarators(p)
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	return decl
}

// Called after the leading net/var type keyword was consumed (keyword == "" for an
// implicit-type declaration such as `[3:0] x;`).
sv_parse_net_var_decl :: proc(p: ^SVParser, keyword: string) -> ^SVNetDecl {
	l := &p.l
	net_type := SVNetType.NONE
	data: SVDataType

	if nt, ok := sv_net_type_keyword(keyword); ok {
		net_type = nt
		sv_skip_trivia(p)
		if lexer_peek(l) == LPAREN {
			sv_skip_balanced_parens(p) // drive/charge strength, dropped
			sv_skip_trivia(p)
		}
		if sv_match_ident(p, "vectored") || sv_match_ident(p, "scalared") {
			// packed-ness hint only, irrelevant for the AST
		}
		sv_skip_trivia(p)
		if lexer_peek(l) == '#' { _ = sv_parse_delay_value(p) }
		sv_skip_trivia(p)
		data = sv_parse_data_type_or_implicit(p)
	} else if vt, ok := sv_var_type_keyword(keyword); ok {
		data.var_type = vt
		data = sv_parse_type_signing_and_dims(p, data)
	} else if keyword == "enum" || keyword == "struct" || keyword == "union" {
		kind := SVTypeSpecKind.ENUM
		if keyword == "struct" { kind = .STRUCT }
		if keyword == "union" { kind = .UNION }
		data.spec = sv_parse_type_spec_body(p, kind)
		data = sv_parse_type_signing_and_dims(p, data)
	} else if keyword == "var" || keyword == "const" || keyword == "automatic" || keyword == "static" || keyword == "string" {
		data = sv_parse_data_type_or_implicit(p)
	} else {
		// implicit data type, possibly a user-defined type reference
		was_signed := keyword == "signed"
		was_unsigned := keyword == "unsigned"
		data = sv_parse_data_type_or_implicit(p)
		if was_signed { data.is_signed = true }
		if was_unsigned { data.is_signed = false }
	}
	return sv_parse_declaration_body(p, net_type, data)
}

sv_skip_balanced_parens :: proc(p: ^SVParser) {
	l := &p.l
	lexer_consume(l, LPAREN)
	for lexer_peek(l) != RPAREN && lexer_peek(l) != 0 { lexer_advance(l) }
	lexer_consume(l, RPAREN)
}

// ---------------------------------------------------------------------------------------
// Modules, ports and parameter lists
// ---------------------------------------------------------------------------------------

sv_parse_module :: proc(p: ^SVParser) -> ^SVModule {
	l := &p.l
	sv_skip_trivia(p)
	name := sv_scan_ident_required(p)
	module := sv_new(p, SVModule)
	module^ = SVModule {
		name        = name,
		source_path = l.filepath,
		ports       = make([dynamic]^SVPort, p.allocator),
		params      = make([dynamic]^SVParamDecl, p.allocator),
		items       = make([dynamic]SVItem, p.allocator),
	}
	sv_skip_trivia(p)
	if sv_match_ident(p, "automatic") || sv_match_ident(p, "static") {
		// module lifetime, not represented in the AST
	}
	for sv_match_ident(p, "import") {
		sv_parse_import_list(p, &module.imports)
	}
	sv_skip_trivia(p)
	if lexer_peek(l) == '#' {
		sv_parse_param_port_list(p, &module.params)
		sv_skip_trivia(p)
	}
	if lexer_peek(l) == LPAREN {
		sv_parse_module_ports(p, module)
		sv_skip_trivia(p)
	}
	lexer_consume(l, SEMICOLON)
	sv_skip_trivia(p)

	previous_module := p.module
	p.module = module
	defer p.module = previous_module

	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, fmt.tprintf("Unterminated module '%s'", name))
		}
		if sv_match_ident(p, "endmodule") {
			sv_skip_trivia(p)
			if lexer_peek(l) == COLON {
				lexer_advance(l)
				sv_skip_space_tabs(l)
				_ = sv_scan_ident_required(p)
			}
			break
		}
		sv_parse_module_item(p, &module.items)
	}

	if existing := p.ast.module_hash_map[module.name]; existing != nil {
		lexer_panic(l, fmt.tprintf("Duplicate module '%s' (already parsed from '%s')", module.name, existing.source_path))
	}
	p.ast.module_hash_map[module.name] = module
	append(&p.ast.modules, module)
	return module
}

sv_parse_param_port_list :: proc(p: ^SVParser, params: ^[dynamic]^SVParamDecl) {
	l := &p.l
	lexer_consume(l, '#')
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	if lexer_peek(l) == RPAREN {
		lexer_advance(l)
		return
	}
	for {
		append(params, sv_parse_param_decl(p, true))
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			sv_skip_trivia(p)
			if lexer_peek(l) == RPAREN { break }  // tolerate a trailing comma
			continue
		}
		break
	}
	lexer_consume(l, RPAREN)
}

// After a comma inside a parameter port list: does the next entry start a new declaration
// (keyword/type/range) or is it another name in the current declaration?
sv_param_comma_starts_new_decl :: proc(p: ^SVParser) -> bool {
	sv_skip_trivia(p)
	start := sv_save(p)
	l := &p.l
	result := false
	if lexer_peek(l) == COMMA {
		lexer_advance(l)
		sv_skip_ws_and_comments(p)
		if lexer_peek(l) == L_SQUARE_BRACKET {
			result = true
		} else {
			name := ""
			c := lexer_peek(l)
			if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL { name = lexer_scan_ident(l) }
			if name == "parameter" || name == "localparam" || name == "type" || name == "signed" || name == "unsigned" {
				result = true
			} else if _, ok := sv_var_type_keyword(name); ok {
				result = true
			} else if name in p.ast.type_names || name in p.ast.iface_names {
				// typed value parameter: `T x = ...` (a type name followed by a name)
				sv_skip_ws_and_comments(p)
				if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL || lexer_peek(l) == L_SQUARE_BRACKET {
					result = true
				}
			}
		}
	}
	sv_restore(p, start)
	return result
}

// Parses the assignment list of one parameter declaration. Stops before a comma that
// starts a new declaration in a parameter port list.
sv_parse_param_assignments :: proc(p: ^SVParser, decl: ^SVParamDecl, in_port_list: bool) {
	l := &p.l
	for {
		sv_skip_trivia(p)
		assignment := SVParamAssign {
			name          = sv_scan_ident_required(p),
			unpacked_dims = make([dynamic]SVRange, p.allocator),
		}
		sv_skip_trivia(p)
		for lexer_peek(l) == L_SQUARE_BRACKET {
			append(&assignment.unpacked_dims, sv_parse_unpacked_dim(p))
			sv_skip_trivia(p)
		}
		if lexer_peek(l) == EQUAL {
			lexer_advance(l)
			sv_skip_trivia(p)
			assignment.value = sv_new_expr(p, sv_parse_expr(p, 0))
		}
		append(&decl.assignments, assignment)
		sv_skip_trivia(p)
		if lexer_peek(l) != COMMA { break }
		if in_port_list && sv_param_comma_starts_new_decl(p) { break }
		lexer_advance(l)
		sv_skip_trivia(p)
		if in_port_list && lexer_peek(l) == RPAREN { break }  // trailing comma
	}
}

// `parameter`/`localparam` keyword already consumed by the caller (module/block items).
// `type T = logic [7:0], U = ...` (the `parameter` keyword, when present, is consumed).
sv_parse_type_param_decl :: proc(p: ^SVParser, is_local: bool, in_port_list: bool) -> ^SVParamDecl {
	l := &p.l
	decl := sv_new(p, SVParamDecl)
	decl.is_local = is_local
	decl.is_type = true
	decl.assignments = make([dynamic]SVParamAssign, p.allocator)
	for {
		sv_skip_trivia(p)
		name := sv_scan_ident_required(p)
		assignment := SVParamAssign {
			name          = name,
			unpacked_dims = make([dynamic]SVRange, p.allocator),
		}
		p.ast.type_names[name] = true
		sv_skip_trivia(p)
		if lexer_peek(l) == EQUAL {
			lexer_advance(l)
			sv_skip_trivia(p)
			type_value := sv_new(p, SVDataType)
			type_value^ = sv_parse_data_type_or_implicit(p)
			assignment.type_value = type_value
		}
		append(&decl.assignments, assignment)
		sv_skip_trivia(p)
		if lexer_peek(l) != COMMA { break }
		if in_port_list && sv_param_comma_starts_new_decl(p) { break }
		lexer_advance(l)
		sv_skip_trivia(p)
		if in_port_list && lexer_peek(l) == RPAREN { break }  // trailing comma
	}
	return decl
}

sv_parse_param_decl_after_keyword :: proc(p: ^SVParser, is_local: bool, in_port_list := false) -> ^SVParamDecl {
	l := &p.l
	if sv_match_ident(p, "type") {
		return sv_parse_type_param_decl(p, is_local, in_port_list)
	}
	decl := sv_new(p, SVParamDecl)
	decl.is_local = is_local
	decl.assignments = make([dynamic]SVParamAssign, p.allocator)
	decl.data = sv_parse_data_type_or_implicit(p)
	sv_parse_param_assignments(p, decl, in_port_list)
	return decl
}

// One declaration in a parameter port list: `parameter`/`localparam` is optional there.
sv_parse_param_decl :: proc(p: ^SVParser, in_port_list: bool) -> ^SVParamDecl {
	l := &p.l
	sv_skip_trivia(p)
	is_local := false
	matched := false
	if sv_match_ident(p, "localparam") {
		is_local = true
		matched = true
	} else if sv_match_ident(p, "parameter") {
		matched = true
	} else if sv_match_ident(p, "type") {
		return sv_parse_type_param_decl(p, is_local, in_port_list)
	}
	if !matched && !in_port_list {
		lexer_panic(l, "Expected 'parameter' or 'localparam'")
	}
	return sv_parse_param_decl_after_keyword(p, is_local, in_port_list)
}

sv_find_port :: proc(module: ^SVModule, name: string) -> ^SVPort {
	for port in module.ports {
		if port.name == name { return port }
	}
	return nil
}

// After '(' in the module header: ANSI port declarations or non-ANSI port references?
sv_port_list_is_ansi :: proc(p: ^SVParser) -> bool {
	sv_skip_trivia(p)
	start := sv_save(p)
	l := &p.l
	result := false
	c := lexer_peek(l)
	if c == L_SQUARE_BRACKET {
		result = true
	} else if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
		name := lexer_scan_ident(l)
		if _, ok := sv_port_dir_keyword(name); ok {
			result = true
		} else if _, ok := sv_var_type_keyword(name); ok {
			result = true
		} else if _, ok := sv_net_type_keyword(name); ok {
			result = true
		} else if name == "var" || name == "const" || name == "signed" || name == "unsigned" || name == "ref" {
			result = true
		} else if name in p.ast.type_names {
			result = true
		} else {
			sv_skip_space_tabs(l)
			if lexer_peek(l) == DOT {
				result = true // interface port `iface.modport name`
			} else if lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON {
				result = true // scoped type
			} else if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL {
				result = true // `type_t name`
			}
		}
	}
	sv_restore(p, start)
	return result
}

sv_parse_module_ports :: proc(p: ^SVParser, module: ^SVModule) {
	l := &p.l
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	if lexer_peek(l) == RPAREN {
		lexer_advance(l)
		module.is_ansi = true
		return
	}
	// module m (.*); — ports declared in the body
	if lexer_peek(l) == DOT && lexer_peek(l, 1) == ASTERISK {
		lexer_advance(l, 2)
		sv_skip_trivia(p)
		lexer_consume(l, RPAREN)
		module.wildcard_ports = true
		module.is_ansi = true
		return
	}
	if sv_port_list_is_ansi(p) {
		module.is_ansi = true
		sv_parse_ansi_ports(p, module)
	} else {
		module.is_ansi = false
		sv_parse_nonansi_ports(p, module)
	}
	lexer_consume(l, RPAREN)
}

sv_parse_ansi_ports :: proc(p: ^SVParser, module: ^SVModule) {
	l := &p.l
	previous_dir := SVPortDir.NONE
	previous_net := SVNetType.NONE
	previous_data: SVDataType
	have_previous := false

	for {
		sv_skip_trivia(p)
		sv_skip_attributes(p)
		sv_skip_trivia(p)
		if lexer_peek(l) == RPAREN { break }

		port := sv_new(p, SVPort)
		dir := SVPortDir.NONE
		dir_given := false
		net_type := SVNetType.NONE
		data: SVDataType
		data_given := false

		name := sv_peek_ident(p)
		if d, ok := sv_port_dir_keyword(name); ok {
			_ = sv_scan_ident_required(p)
			dir = d
			dir_given = true
		} else if sv_match_ident(p, "ref") {
			dir = .REF
			dir_given = true
		}

		sv_skip_trivia(p)
		// explicit port expression: [direction] .port_identifier ( [expression] )
		if lexer_peek(l) == DOT {
			lexer_advance(l)
			sv_skip_trivia(p)
			port.name = sv_scan_ident_required(p)
			sv_skip_trivia(p)
			port.unpacked_dims = make([dynamic]SVRange, p.allocator)
			if lexer_peek(l) == LPAREN {
				lexer_advance(l)
				sv_skip_trivia(p)
				if lexer_peek(l) != RPAREN {
					port.expr = sv_new_expr(p, sv_parse_expr(p, 0))
					sv_skip_trivia(p)
				}
				lexer_consume(l, RPAREN)
			}
			port.dir = dir
			append(&module.ports, port)
			previous_dir = dir
			previous_net = SVNetType.NONE
			previous_data = SVDataType{}
			have_previous = true
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			break
		}

		iface_name, modport_name, is_iface := sv_peek_interface_port(p)
		type_name := sv_peek_ident(p)
		if sv_match_ident(p, "interface") {
			// generic interface port: `interface [.modport] name`
			port.iface_name = "interface"
			sv_skip_space_tabs(l)
			if lexer_peek(l) == DOT {
				lexer_advance(l)
				sv_skip_space_tabs(l)
				port.modport = sv_scan_ident_required(p)
			}
			data_given = true
		} else if is_iface {
			_ = sv_scan_ident_required(p)
			sv_skip_space_tabs(l)
			lexer_consume(l, DOT)
			sv_skip_space_tabs(l)
			_ = sv_scan_ident_required(p)
			port.iface_name = iface_name
			port.modport = modport_name
			data_given = true
		} else if nt, ok := sv_net_type_keyword(type_name); ok {
			_ = sv_scan_ident_required(p)
			net_type = nt
			data = sv_parse_data_type_or_implicit(p)
			data_given = true
		} else if type_name == "var" {
			_ = sv_scan_ident_required(p)
			data = sv_parse_data_type_or_implicit(p)
			if data.var_type == .IMPLICIT { data.var_type = .LOGIC }
			data_given = true
		} else if vt, ok := sv_var_type_keyword(type_name); ok {
			_ = sv_scan_ident_required(p)
			data.var_type = vt
			data = sv_parse_type_signing_and_dims(p, data)
			data_given = true
		} else if sv_starts_data_type(p) {
			data = sv_parse_data_type_or_implicit(p)
			data_given = true
		} else if sv_two_idents_ahead(p) {
			// forward-referenced user type / interface: `MEM_BUS in_narrow [N]`
			data.type_name = sv_scan_ident_required(p)
			data = sv_parse_type_signing_and_dims(p, data)
			data_given = true
		}
		if data.type_name != "" && data.type_name in p.ast.iface_names {
			port.iface_name = data.type_name
		}

		// `input [3:0] a, b` — a bare continuation entry inherits the previous header
		if !dir_given && have_previous {
			dir = previous_dir
			if !data_given {
				data = previous_data
				net_type = previous_net
			}
		}

		port.dir = dir
		port.net_type = net_type
		port.data = data
		port.name = sv_scan_ident_required(p)
		port.unpacked_dims = make([dynamic]SVRange, p.allocator)
		sv_skip_trivia(p)
		for lexer_peek(l) == L_SQUARE_BRACKET {
			append(&port.unpacked_dims, sv_parse_unpacked_dim(p))
			sv_skip_trivia(p)
		}
		if lexer_peek(l) == EQUAL {
			lexer_advance(l)
			sv_skip_trivia(p)
			port.default_value = sv_new_expr(p, sv_parse_expr(p, 0))
		}
		append(&module.ports, port)

		previous_dir = dir
		previous_net = net_type
		previous_data = data
		have_previous = true

		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
}

sv_parse_nonansi_ports :: proc(p: ^SVParser, module: ^SVModule) {
	l := &p.l
	for {
		sv_skip_trivia(p)
		if lexer_peek(l) == RPAREN { break }
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		if lexer_peek(l) == DOT {
			// explicit port: .port_identifier ( [ port_expression ] )
			lexer_advance(l)
			port := sv_new(p, SVPort)
			port.dir = .NONE
			port.name = sv_scan_ident_required(p)
			sv_skip_trivia(p)
			if lexer_peek(l) == LPAREN {
				lexer_advance(l)
				sv_skip_trivia(p)
				if lexer_peek(l) != RPAREN {
					port.expr = sv_new_expr(p, sv_parse_expr(p, 0))
					sv_skip_trivia(p)
				}
				lexer_consume(l, RPAREN)
			}
			append(&module.ports, port)
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			break
		}
		if lexer_peek(l) == LCURLY {
			// concatenated port expression: { a, b, c[3:0] }
			port := sv_new(p, SVPort)
			port.dir = .NONE
			port.expr = sv_new_expr(p, sv_parse_expr(p, 0))
			append(&module.ports, port)
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			break
		}
		port := sv_new(p, SVPort)
		port.dir = .NONE
		port.name = sv_scan_ident_required(p)
		port.unpacked_dims = make([dynamic]SVRange, p.allocator)
		sv_skip_trivia(p)
		for lexer_peek(l) == L_SQUARE_BRACKET {
			append(&port.unpacked_dims, sv_parse_unpacked_dim(p))
			sv_skip_trivia(p)
		}
		append(&module.ports, port)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
}

// A port declaration in the module body (non-ANSI style): input/output/inout ... ;
sv_parse_port_declaration :: proc(p: ^SVParser, dir: SVPortDir) -> ^SVPortDecl {
	l := &p.l
	net_type := SVNetType.NONE
	data: SVDataType
	sv_skip_trivia(p)
	if iface_name, modport_name, is_iface := sv_peek_interface_port(p); is_iface {
		_ = sv_scan_ident_required(p)
		sv_skip_space_tabs(l)
		lexer_consume(l, DOT)
		sv_skip_space_tabs(l)
		_ = sv_scan_ident_required(p)
		decl := sv_new(p, SVNetDecl)
		decl.declarators = sv_parse_declarators(p)
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		for d in decl.declarators {
			port := sv_find_port(p.module, d.name)
			if port != nil {
				port.dir = dir
				port.iface_name = iface_name
				port.modport = modport_name
				port.unpacked_dims = d.unpacked_dims
			}
		}
		port_decl := sv_new(p, SVPortDecl)
		port_decl.dir = dir
		port_decl.decl = decl
		return port_decl
	}
	type_name := sv_peek_ident(p)
	if nt, ok := sv_net_type_keyword(type_name); ok {
		_ = sv_scan_ident_required(p)
		net_type = nt
		data = sv_parse_data_type_or_implicit(p)
	} else if type_name == "var" {
		_ = sv_scan_ident_required(p)
		data = sv_parse_data_type_or_implicit(p)
	} else if vt, ok := sv_var_type_keyword(type_name); ok {
		_ = sv_scan_ident_required(p)
		data.var_type = vt
		data = sv_parse_type_signing_and_dims(p, data)
	} else if sv_starts_data_type(p) {
		data = sv_parse_data_type_or_implicit(p)
	}

	decl := sv_parse_declaration_body(p, net_type, data)
	for d in decl.declarators {
		port := sv_find_port(p.module, d.name)
		if port == nil {
			if !p.module.wildcard_ports {
				lexer_panic(l, fmt.tprintf("Port '%s' is declared but not listed in the module header", d.name))
			}
			// module m (.*); — body declarations define the port list
			port = sv_new(p, SVPort)
			port.name = d.name
			append(&p.module.ports, port)
		}
		port.dir = dir
		port.net_type = net_type
		port.data = data
		port.unpacked_dims = d.unpacked_dims
		if d.init != nil { port.default_value = d.init }
	}
	port_decl := sv_new(p, SVPortDecl)
	port_decl.dir = dir
	port_decl.decl = decl
	return port_decl
}

// ---------------------------------------------------------------------------------------
// Module items
// ---------------------------------------------------------------------------------------

// Elaboration severity task at module/package/generate scope: $fatal(...), $error(...),
// $warning(...), $info(...) followed by ';'.
sv_parse_system_task_item :: proc(p: ^SVParser) -> ^SVCall {
	l := &p.l
	name := sv_scan_system_ident(p)
	sv_skip_trivia(p)
	call: ^SVCall
	if lexer_peek(l) == LPAREN {
		expr := sv_parse_call(p, name, true)
		call = expr.(^SVCall)
	} else {
		call = sv_new(p, SVCall)
		call^ = SVCall{name = name, is_system = true, args = make([dynamic]SVCallArg, p.allocator)}
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	return call
}

sv_parse_module_item :: proc(p: ^SVParser, items: ^[dynamic]SVItem) {
	sv_skip_trivia(p)
	sv_skip_attributes(p)
	sv_skip_trivia(p)
	l := &p.l
	if sv_at_eof(p) {
		lexer_panic(l, "Unexpected end of file in module body")
	}

	// generate block label: `label : begin ... end`
	if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL {
		start := sv_save(p)
		name := lexer_scan_ident(l)
		sv_skip_space_tabs(l)
		if lexer_peek(l) == COLON && lexer_peek(l, 1) != COLON && name != "begin" {
			lexer_advance(l)
			sv_skip_trivia(p)
			if sv_match_ident(p, "assert") {
				append(items, sv_parse_assertion(p, .ASSERT))
				return
			}
			if sv_match_ident(p, "assume") {
				append(items, sv_parse_assertion(p, .ASSUME))
				return
			}
			if sv_match_ident(p, "cover") {
				append(items, sv_parse_assertion(p, .COVER))
				return
			}
			lexer_ensure(l, sv_match_ident(p, "begin"), "Expected 'begin' after a generate block label")
			block := sv_parse_gen_block_after_begin(p, name)
			region := sv_new(p, SVGenRegion)
			region.label = block.label
			region.items = block.items
			append(items, region)
			return
		}
		sv_restore(p, start)
	}

	c := lexer_peek(l)
	switch {
	case c == SEMICOLON: lexer_advance(l)
	case c == '$': append(items, sv_parse_system_task_item(p))
	case c == L_SQUARE_BRACKET: append(items, sv_parse_net_var_decl(p, ""))
	case lexer_is_ident_start(c) || c == ESCAPE_SYMBOL:
		name := lexer_scan_ident(l)
		sv_parse_module_item_after_ident(p, name, items)
	case: lexer_panic(l, fmt.tprintf("Unexpected character '%r' in module body", c))
	}
}

sv_parse_module_item_after_ident :: proc(p: ^SVParser, name: string, items: ^[dynamic]SVItem) {
	l := &p.l
	switch name {
	case "input": append(items, sv_parse_port_declaration(p, .INPUT))
	case "output": append(items, sv_parse_port_declaration(p, .OUTPUT))
	case "inout": append(items, sv_parse_port_declaration(p, .INOUT))
	case "ref": append(items, sv_parse_port_declaration(p, .REF))
	case "parameter", "localparam":
		decl := sv_parse_param_decl_after_keyword(p, name == "localparam")
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		append(items, decl)
	case "wire", "tri", "wand", "wor", "triand", "trior", "tri0", "tri1", "trireg", "supply0", "supply1", "uwire":
		append(items, sv_parse_net_var_decl(p, name))
	case "reg",
		 "logic",
		 "bit",
		 "int",
		 "integer",
		 "shortint",
		 "longint",
		 "byte",
		 "time",
		 "real",
		 "shortreal",
		 "realtime",
		 "var",
		 "const",
		 "signed",
		 "unsigned",
		 "enum",
		 "struct",
		 "union",
		 "string":
		append(items, sv_parse_net_var_decl(p, name))
	case "genvar":
		genvar := sv_new(p, SVGenvarDecl)
		genvar.names = make([dynamic]string, p.allocator)
		for {
			append(&genvar.names, sv_scan_ident_required(p))
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			break
		}
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		append(items, genvar)
	case "assert": append(items, sv_parse_assertion(p, .ASSERT))
	case "assume": append(items, sv_parse_assertion(p, .ASSUME))
	case "cover": append(items, sv_parse_assertion(p, .COVER))
	case "assign": append(items, sv_parse_cont_assign(p))
	case "alias": append(items, sv_parse_alias(p))
	case "defparam": append(items, sv_parse_defparam(p))
	case "class":
		sv_skip_until_ident(p, "endclass")
		sv_skip_optional_end_label(p)
	case "restrict":
		// restrict property (...);  (verification only)
		sv_skip_trivia(p)
		if sv_match_ident(p, "property") {
			sv_skip_trivia(p)
			_ = sv_scan_balanced_parens_text(p)
		}
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
	case "initial": append(items, sv_parse_proc(p, .INITIAL))
	case "final":
		final_proc := sv_new(p, SVProc)
		final_proc.kind = .FINAL
		sv_skip_trivia(p)
		final_proc.body = sv_parse_statement(p)
		append(items, final_proc)
	case "always": append(items, sv_parse_proc(p, .ALWAYS))
	case "always_comb": append(items, sv_parse_proc(p, .ALWAYS_COMB))
	case "always_ff": append(items, sv_parse_proc(p, .ALWAYS_FF))
	case "always_latch": append(items, sv_parse_proc(p, .ALWAYS_LATCH))
	case "function": append(items, sv_parse_subroutine(p, false))
	case "task": append(items, sv_parse_subroutine(p, true))
	case "typedef":
		append(items, sv_parse_typedef(p))
	case "import":
		sv_parse_import_list(p, &p.module.imports)
	case "generate": append(items, sv_parse_generate_region(p))
	case "begin":
		block := sv_parse_gen_block_after_begin(p, "")
		region := sv_new(p, SVGenRegion)
		region.label = block.label
		region.items = block.items
		append(items, region)
	case "for": append(items, sv_parse_gen_loop(p))
	case "if": append(items, sv_parse_gen_if(p))
	case "case": append(items, sv_parse_gen_case(p))
	case "module", "macromodule": // nested module declaration: a legal top-level design element
			_ = sv_parse_module(p)
	case "specify": sv_skip_specify(p)
	case "default": sv_skip_to_semicolon(p) // default disable iff (...) / default clocking ...
	case "property":
		sv_skip_until_ident(p, "endproperty")
		sv_skip_optional_end_label(p)
	case "sequence":
		sv_skip_until_ident(p, "endsequence")
		sv_skip_optional_end_label(p)
	case "covergroup":
		sv_skip_until_ident(p, "endgroup")
		sv_skip_optional_end_label(p)
	case "clocking":
		sv_skip_until_ident(p, "endclocking")
		sv_skip_optional_end_label(p)
	case "timeunit", "timeprecision": sv_skip_to_semicolon(p)
	case "event",
		 "chandle",
		 "export",
		 "interface",
		 "package",
		 "program",
		 "primitive",
		 "checker",
		 "coverpoint",
		 "modport",
		 "nettype",
		 "bind",
		 "config",
		 "let",
		 "specparam",
		 "automatic",
		 "static":
		lexer_panic(l, fmt.tprintf("Unsupported module item '%s' (outside the synthesizable subset)", name))
	case:
		if name in p.ast.iface_names && sv_item_after_cell_is_instantiation(p) {
			sv_parse_instantiation(p, name, false, items)
			return
		}
		if sv_is_iface_decl_after_name(p) {
			append(items, sv_parse_iface_decl_after_name(p, name))
			return
		}
		if sv_is_user_type_decl_start(p, name) {
			append(items, sv_parse_decl_after_type_name(p, name))
			return
		}
		if !sv_item_after_cell_is_instantiation(p) && sv_ident_follows(p) {
			// declaration with a not-yet-seen user type: `TYPE name;`
			append(items, sv_parse_decl_after_type_name(p, name))
			return
		}
		is_gate, _ := sv_gate_keyword(name)
		if is_gate {
			sv_parse_instantiation(p, name, true, items)
		} else if sv_is_reserved_keyword(name) {
			lexer_panic(l, fmt.tprintf("Unsupported module item keyword '%s'", name))
		} else {
			sv_parse_instantiation(p, name, false, items)
		}
	}
}

sv_gate_keyword :: proc(name: string) -> (bool, bool) {
	switch name {
	case "and",
		 "nand",
		 "or",
		 "nor",
		 "xor",
		 "xnor",
		 "buf",
		 "not",
		 "bufif0",
		 "bufif1",
		 "notif0",
		 "notif1",
		 "nmos",
		 "pmos",
		 "rnmos",
		 "rpmos",
		 "cmos",
		 "rcmos",
		 "tran",
		 "rtran",
		 "tranif0",
		 "tranif1",
		 "rtranif0",
		 "rtranif1",
		 "pullup",
		 "pulldown":
		return true, true
	}
	return false, false
}

sv_skip_specify :: proc(p: ^SVParser) {
	l := &p.l
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) { lexer_panic(l, "Unterminated specify block") }
		c := lexer_peek(l)
		if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
			if lexer_scan_ident(l) == "endspecify" { return }
		} else if c == DOUBLE_QUOTE {
			_ = sv_scan_string(p)
		} else {
			lexer_advance(l)
		}
	}
}

sv_skip_to_semicolon :: proc(p: ^SVParser) {
	l := &p.l
	for lexer_peek(l) != SEMICOLON && lexer_peek(l) != 0 { lexer_advance(l) }
	lexer_consume(l, SEMICOLON)
}

sv_parse_generate_region :: proc(p: ^SVParser) -> ^SVGenRegion {
	region := sv_new(p, SVGenRegion)
	region.items = make([dynamic]SVItem, p.allocator)
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(&p.l, "Unterminated generate region")
		}
		if sv_match_ident(p, "endgenerate") { break }
		sv_parse_module_item(p, &region.items)
	}
	return region
}

// begin [ : label ] { generate_item } end [ : label ]
sv_parse_gen_block_after_begin :: proc(p: ^SVParser, label: string) -> ^SVGenBlock {
	l := &p.l
	block := sv_new(p, SVGenBlock)
	block.label = label
	block.items = make([dynamic]SVItem, p.allocator)
	sv_skip_trivia(p)
	if lexer_peek(l) == COLON {
		lexer_advance(l)
		sv_skip_space_tabs(l)
		block.label = sv_scan_ident_required(p)
	}
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, "Unterminated generate block")
		}
		if sv_match_ident(p, "end") {
			sv_skip_trivia(p)
			if lexer_peek(l) == COLON {
				lexer_advance(l)
				sv_skip_space_tabs(l)
				_ = sv_scan_ident_required(p)
			}
			return block
		}
		sv_parse_module_item(p, &block.items)
	}
}

sv_parse_generate_block :: proc(p: ^SVParser, prefix_label := "") -> ^SVGenBlock {
	l := &p.l
	block: ^SVGenBlock
	label := prefix_label
	sv_skip_trivia(p)
	if len(label) == 0 && (lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL) {
		start := sv_save(p)
		name := lexer_scan_ident(l)
		sv_skip_space_tabs(l)
		if name != "begin" && lexer_peek(l) == COLON && lexer_peek(l, 1) != COLON {
			lexer_advance(l)
			sv_skip_trivia(p)
			label = name
		} else {
			sv_restore(p, start)
		}
	}
	if sv_match_ident(p, "begin") {
		block = sv_parse_gen_block_after_begin(p, label)
	} else {
		// single generate item
		block = sv_new(p, SVGenBlock)
		block.label = label
		block.items = make([dynamic]SVItem, p.allocator)
		sv_parse_module_item(p, &block.items)
	}
	return block
}

sv_parse_gen_loop :: proc(p: ^SVParser) -> ^SVGenLoop {
	l := &p.l
	loop := sv_new(p, SVGenLoop)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	_ = sv_match_ident(p, "genvar")
	loop.var = sv_scan_ident_required(p)
	sv_skip_trivia(p)
	lexer_consume(l, EQUAL)
	sv_skip_trivia(p)
	loop.init = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	sv_skip_trivia(p)
	loop.cond = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	sv_skip_trivia(p)
	loop.step = sv_parse_assignment_or_call(p, sv_parse_statement_base(p))
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	sv_skip_trivia(p)
	loop.body = sv_parse_generate_block(p)
	return loop
}

sv_parse_gen_if :: proc(p: ^SVParser) -> ^SVGenIf {
	l := &p.l
	node := sv_new(p, SVGenIf)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	node.cond = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	sv_skip_trivia(p)
	node.then_blk = sv_parse_generate_block(p)
	sv_skip_trivia(p)
	if sv_match_ident(p, "else") {
		sv_skip_trivia(p)
		node.else_blk = sv_parse_generate_block(p)
	}
	return node
}

sv_parse_gen_case :: proc(p: ^SVParser) -> ^SVGenCase {
	l := &p.l
	node := sv_new(p, SVGenCase)
	node.items = make([dynamic]SVGenCaseItem, p.allocator)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	node.subject = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, "Unterminated generate case")
		}
		if sv_match_ident(p, "endcase") { break }
		item := SVGenCaseItem {
			exprs = make([dynamic]SVExpr, p.allocator),
		}
		if sv_match_ident(p, "default") {
			item.is_default = true
			sv_skip_trivia(p)
			if lexer_peek(l) == COLON { lexer_advance(l) }
		} else {
			for {
				sv_skip_trivia(p)
				append(&item.exprs, sv_parse_expr(p, 0))
				sv_skip_trivia(p)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					continue
				}
				break
			}
			sv_skip_trivia(p)
			lexer_consume(l, COLON)
			sv_skip_trivia(p)
		}
		item.body = sv_parse_generate_block(p)
		append(&node.items, item)
	}
	return node
}

// alias net_lvalue = net_lvalue { = net_lvalue } ;
sv_parse_alias :: proc(p: ^SVParser) -> ^SVAlias {
	l := &p.l
	node := sv_new(p, SVAlias)
	node.names = make([dynamic]SVExpr, p.allocator)
	for {
		sv_skip_trivia(p)
		append(&node.names, sv_parse_expr(p, 0))
		sv_skip_trivia(p)
		if lexer_peek(l) == EQUAL {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	return node
}

// defparam hierarchical_parameter_identifier = expr { , ... } ;
sv_parse_defparam :: proc(p: ^SVParser) -> ^SVDefparam {
	l := &p.l
	node := sv_new(p, SVDefparam)
	node.pairs = make([dynamic]SVAssignPair, p.allocator)
	for {
		sv_skip_trivia(p)
		lhs := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		lexer_consume(l, EQUAL)
		sv_skip_trivia(p)
		rhs := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		for lexer_peek(l) == COLON { // mintypmax: keep the minimum
			lexer_advance(l)
			sv_skip_trivia(p)
			_ = sv_parse_expr(p, 0)
			sv_skip_trivia(p)
		}
		append(&node.pairs, SVAssignPair{lhs = lhs, rhs = rhs})
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	return node
}

sv_parse_cont_assign :: proc(p: ^SVParser) -> ^SVContAssign {
	l := &p.l
	assign := sv_new(p, SVContAssign)
	assign.pairs = make([dynamic]SVAssignPair, p.allocator)
	sv_skip_trivia(p)
	if lexer_peek(l) == LPAREN {
		sv_skip_balanced_parens(p) // drive strength
		sv_skip_trivia(p)
	}
	if lexer_peek(l) == '#' {
		_ = sv_parse_delay_value(p)
		sv_skip_trivia(p)
	}
	for {
		sv_skip_trivia(p)
		lhs := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		lexer_consume(l, EQUAL)
		sv_skip_trivia(p)
		rhs := sv_parse_expr(p, 0)
		append(&assign.pairs, SVAssignPair{lhs = lhs, rhs = rhs})
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	return assign
}

sv_parse_instantiation :: proc(p: ^SVParser, cell_name: string, is_gate: bool, items: ^[dynamic]SVItem) {
	l := &p.l
	sv_skip_trivia(p)
	param_overrides := make([dynamic]SVParamOverride, p.allocator)

	if lexer_peek(l) == '#' {
		if is_gate {
			_ = sv_parse_delay_value(p) // gate delay, not represented in the AST
			sv_skip_trivia(p)
		} else {
			lexer_advance(l)
			sv_skip_trivia(p)
			if lexer_peek(l) == LPAREN {
				param_overrides = sv_parse_param_overrides(p)
			} else {
				_ = sv_parse_primary(p) // #5 style delay on an instance: tolerate and drop
			}
			sv_skip_trivia(p)
		}
	}

	if is_gate && lexer_peek(l) == LPAREN {
		if sv_paren_is_strength(p) {
			sv_skip_balanced_parens(p) // gate drive strength
			sv_skip_trivia(p)
		}
	}

	for {
		sv_skip_trivia(p)
		instance := sv_new(p, SVInstance)
		instance^ = SVInstance {
			cell_name       = cell_name,
			is_gate         = is_gate,
			param_overrides = param_overrides,
			port_conns      = make([dynamic]SVPortConn, p.allocator),
			unpacked_dims   = make([dynamic]SVRange, p.allocator),
		}
		if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL {
			instance.name = sv_scan_ident_required(p)
		} else if !is_gate {
			lexer_panic(l, fmt.tprintf("Expected an instance name after cell '%s'", cell_name))
		}
		sv_skip_trivia(p)
		for lexer_peek(l) == L_SQUARE_BRACKET {
			append(&instance.unpacked_dims, sv_parse_unpacked_dim(p))
			sv_skip_trivia(p)
		}
		lexer_ensure(l, lexer_peek(l) == LPAREN, "Expected '(' for instance port connections")
		sv_parse_port_connections(p, instance)
		append(items, instance)
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
}

sv_paren_is_strength :: proc(p: ^SVParser) -> bool {
	start := sv_save(p)
	l := &p.l
	result := false
	if lexer_peek(l) == LPAREN {
		lexer_advance(l)
		sv_skip_ws_and_comments(p)
		name := ""
		if lexer_is_ident_start(lexer_peek(l)) { name = lexer_scan_ident(l) }
		switch name {
		case "supply0", "supply1", "strong0", "strong1", "pull0", "pull1", "weak0", "weak1", "highz0", "highz1": result = true
		}
	}
	sv_restore(p, start)
	return result
}

sv_parse_param_overrides :: proc(p: ^SVParser) -> [dynamic]SVParamOverride {
	l := &p.l
	overrides := make([dynamic]SVParamOverride, p.allocator)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	if lexer_peek(l) == RPAREN {
		lexer_advance(l)
		return overrides
	}
	for {
		sv_skip_trivia(p)
		override: SVParamOverride
		if lexer_peek(l) == DOT {
			lexer_advance(l)
			sv_skip_trivia(p)
			override.name = sv_scan_ident_required(p)
			sv_skip_trivia(p)
			lexer_consume(l, LPAREN)
			sv_skip_trivia(p)
			if lexer_peek(l) != RPAREN {
				if sv_starts_type_argument(p) {
					type_value := sv_new(p, SVDataType)
					type_value^ = sv_parse_data_type_or_implicit(p)
					override.type_value = type_value
				} else {
					override.value = sv_new_expr(p, sv_parse_expr(p, 0))
				}
				sv_skip_trivia(p)
			}
			lexer_consume(l, RPAREN)
		} else {
			if sv_starts_type_argument(p) {
				type_value := sv_new(p, SVDataType)
				type_value^ = sv_parse_data_type_or_implicit(p)
				override.type_value = type_value
			} else {
				override.value = sv_new_expr(p, sv_parse_expr(p, 0))
			}
			sv_skip_trivia(p)
			for lexer_peek(l) == COLON { 	// mintypmax: keep the minimum
				lexer_advance(l)
				sv_skip_trivia(p)
				_ = sv_parse_expr(p, 0)
				sv_skip_trivia(p)
			}
		}
		append(&overrides, override)
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	lexer_consume(l, RPAREN)
	return overrides
}

sv_parse_port_connections :: proc(p: ^SVParser, instance: ^SVInstance) {
	l := &p.l
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	if lexer_peek(l) == RPAREN {
		lexer_advance(l)
		return
	}
	for {
		sv_skip_trivia(p)
		sv_skip_attributes(p)
		sv_skip_trivia(p)
		connection: SVPortConn
		c := lexer_peek(l)
		if c == DOT {
			lexer_advance(l)
			sv_skip_trivia(p)
			if lexer_peek(l) == ASTERISK {
				lexer_advance(l)
				instance.wildcard_ports = true
				sv_skip_trivia(p)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					continue
				}
				break
			}
			connection.name = sv_scan_ident_required(p)
			sv_skip_trivia(p)
			if lexer_peek(l) == LPAREN {
				lexer_advance(l)
				sv_skip_trivia(p)
				if lexer_peek(l) != RPAREN {
					connection.value = sv_new_expr(p, sv_parse_expr(p, 0))
					sv_skip_trivia(p)
				}
				lexer_consume(l, RPAREN)
			}
		} else if c != COMMA && c != RPAREN {
			connection.value = sv_new_expr(p, sv_parse_expr(p, 0))
		}
		append(&instance.port_conns, connection)
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
}

// ---------------------------------------------------------------------------------------
// Procedural blocks and subroutines
// ---------------------------------------------------------------------------------------

sv_parse_proc :: proc(p: ^SVParser, kind: SVProcKind) -> ^SVProc {
	l := &p.l
	proc_node := sv_new(p, SVProc)
	proc_node.kind = kind
	sv_skip_trivia(p)

	if lexer_peek(l) == '@' {
		ctl := sv_parse_timing_ctl(p)
		proc_node.events = ctl.events
		proc_node.any_event = ctl.any_event
		sv_skip_trivia(p)
		proc_node.body = sv_parse_statement(p)
		return proc_node
	}
	if lexer_peek(l) == '#' {
		ctl := sv_parse_timing_ctl(p)
		stmt := sv_new(p, SVTimingStmt)
		stmt.timing = ctl
		inner := sv_parse_statement_or_null(p)
		stmt.body = inner
		proc_node.body = stmt
		return proc_node
	}
	proc_node.body = sv_parse_statement(p)
	return proc_node
}

sv_parse_subroutine :: proc(p: ^SVParser, is_task: bool) -> ^SVSubroutine {
	l := &p.l
	sub := sv_new(p, SVSubroutine)
	sub^ = SVSubroutine {
		is_task = is_task,
		ports = make([dynamic]SVTFPort, p.allocator),
		body = SVBlock{decls = make([dynamic]SVBlockDecl, p.allocator), stmts = make([dynamic]SVStmt, p.allocator)},
	}
	sv_skip_trivia(p)
	if sv_match_ident(p, "automatic") {
		sub.is_automatic = true
	} else if sv_match_ident(p, "static") {
		// static is the default
	}
	sv_skip_trivia(p)
	if is_task {
		sub.return_data.var_type = .VOID
	} else if sv_match_ident(p, "void") {
		sub.return_data.var_type = .VOID
	} else {
		sub.return_data = sv_parse_data_type_or_implicit(p)
	}
	sv_skip_trivia(p)
	sub.name = sv_scan_ident_required(p)
	sv_skip_trivia(p)
	if lexer_peek(l) == LPAREN {
		sv_parse_tf_ports(p, sub)
		sv_skip_trivia(p)
	}
	lexer_consume(l, SEMICOLON)
	sv_skip_trivia(p)

	end_keyword := is_task ? "endtask" : "endfunction"
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, fmt.tprintf("Unterminated %s '%s'", is_task ? "task" : "function", sub.name))
		}
		if sv_match_ident(p, end_keyword) {
			sv_skip_trivia(p)
			if lexer_peek(l) == COLON {
				lexer_advance(l)
				sv_skip_space_tabs(l)
				_ = sv_scan_ident_required(p)
			}
			return sub
		}
		c := lexer_peek(l)
		if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
			start := sv_save(p)
			name := lexer_scan_ident(l)
			if dir, is_dir := sv_port_dir_keyword(name); is_dir {
				// legacy tf_port_declaration: input [7:0] a, b;
				decl := sv_parse_declaration_body_after_dir(p, dir)
				for d in decl.declarators {
					port := SVTFPort {
						dir           = dir,
						data          = decl.data,
						name          = d.name,
						unpacked_dims = d.unpacked_dims,
						default_value = d.init,
					}
					append(&sub.ports, port)
				}
				continue
			}
			if name == "import" {
				sv_parse_import_list(p, &sub.body.imports)
				continue
			}
			if name == "typedef" {
				append(&sub.body.decls, sv_parse_typedef(p))
				continue
			}
			if sv_is_user_type_decl_start(p, name) {
				append(&sub.body.decls, sv_parse_decl_after_type_name(p, name))
				continue
			}
			if sv_is_decl_keyword(name) {
				if name == "parameter" || name == "localparam" {
					decl := sv_parse_param_decl_after_keyword(p, name == "localparam")
					sv_skip_trivia(p)
					lexer_consume(l, SEMICOLON)
					append(&sub.body.decls, decl)
				} else {
					append(&sub.body.decls, sv_parse_net_var_decl(p, name))
				}
				continue
			}
			sv_restore(p, start)
		}
		append(&sub.body.stmts, sv_parse_statement(p))
	}
}

// Declarators (and ';') for a port/tf declaration whose direction keyword was consumed.
sv_parse_declaration_body_after_dir :: proc(p: ^SVParser, dir: SVPortDir) -> ^SVNetDecl {
	net_type := SVNetType.NONE
	data: SVDataType
	sv_skip_trivia(p)
	type_name := sv_peek_ident(p)
	if nt, ok := sv_net_type_keyword(type_name); ok {
		_ = sv_scan_ident_required(p)
		net_type = nt
		data = sv_parse_data_type_or_implicit(p)
	} else if type_name == "var" {
		_ = sv_scan_ident_required(p)
		data = sv_parse_data_type_or_implicit(p)
	} else if vt, ok := sv_var_type_keyword(type_name); ok {
		_ = sv_scan_ident_required(p)
		data.var_type = vt
		data = sv_parse_type_signing_and_dims(p, data)
	} else if sv_starts_data_type(p) {
		data = sv_parse_data_type_or_implicit(p)
	}
	return sv_parse_declaration_body(p, net_type, data)
}

sv_parse_tf_ports :: proc(p: ^SVParser, sub: ^SVSubroutine) {
	l := &p.l
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	if lexer_peek(l) == RPAREN {
		lexer_advance(l)
		return
	}
	previous_dir := SVPortDir.NONE
	previous_data: SVDataType
	have_previous := false
	for {
		sv_skip_trivia(p)
		if lexer_peek(l) == RPAREN { break }
		port := SVTFPort {
			unpacked_dims = make([dynamic]SVRange, p.allocator),
		}
		dir := SVPortDir.NONE
		dir_given := false
		name := sv_peek_ident(p)
		if d, ok := sv_port_dir_keyword(name); ok {
			_ = sv_scan_ident_required(p)
			dir = d
			dir_given = true
		} else if name == "ref" {
			lexer_panic(l, "'ref' tf ports are not supported")
		}
		_ = sv_match_ident(p, "var")
		data_given := false
		sv_skip_trivia(p)
		if sv_starts_data_type(p) {
			data_given = true
		}
		port.data = sv_parse_data_type_or_implicit(p)
		if !dir_given && have_previous { dir = previous_dir }
		if !dir_given && !data_given && have_previous { port.data = previous_data }
		port.dir = dir
		port.name = sv_scan_ident_required(p)
		sv_skip_trivia(p)
		for lexer_peek(l) == L_SQUARE_BRACKET {
			append(&port.unpacked_dims, sv_parse_unpacked_dim(p))
			sv_skip_trivia(p)
		}
		if lexer_peek(l) == EQUAL {
			lexer_advance(l)
			sv_skip_trivia(p)
			port.default_value = sv_new_expr(p, sv_parse_expr(p, 0))
		}
		append(&sub.ports, port)
		previous_dir = dir
		previous_data = port.data
		have_previous = true
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
}

// ---------------------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------------------

// Raw text inside balanced parentheses; used for property/sequence expressions whose
// grammar is outside the synthesizable subset.
sv_scan_balanced_parens_text :: proc(p: ^SVParser) -> string {
	l := &p.l
	lexer_consume(l, LPAREN)
	start := l.idx
	depth := 0
	for {
		c := lexer_peek(l)
		lexer_ensure(l, l.idx < len(l.src), "Unterminated parenthesized expression")
		if c == DOUBLE_QUOTE {
			_ = sv_scan_string(p)
			continue
		}
		if c == LPAREN { depth += 1 }
		if c == RPAREN {
			if depth == 0 {
				text := string(l.src[start:l.idx])
				lexer_advance(l)
				return text
			}
			depth -= 1
		}
		lexer_advance(l)
	}
}

// Immediate or concurrent assertion. Property/sequence bodies are captured as raw text:
// they are verification-only and outside the synthesizable subset.
sv_parse_assertion :: proc(p: ^SVParser, kind: SVAssertKind) -> ^SVAssert {
	l := &p.l
	node := sv_new(p, SVAssert)
	node.kind = kind
	sv_skip_trivia(p)
	// deferred forms: assert #0 (...) / assert final (...)
	if lexer_peek(l) == '#' {
		lexer_advance(l)
		sv_skip_trivia(p)
		_ = sv_parse_primary(p)
		sv_skip_trivia(p)
	} else if sv_match_ident(p, "final") {
		sv_skip_trivia(p)
	}
	if sv_match_ident(p, "property") {
		node.is_property = true
		sv_skip_trivia(p)
		node.property_text = sv_scan_balanced_parens_text(p)
	} else if sv_match_ident(p, "sequence") {
		node.is_property = true
		sv_skip_trivia(p)
		node.property_text = sv_scan_balanced_parens_text(p)
	} else {
		lexer_consume(l, LPAREN)
		sv_skip_trivia(p)
		node.cond = sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		lexer_consume(l, RPAREN)
	}
	sv_skip_trivia(p)
	if sv_peek_ident(p) != "else" {
		node.pass_body = sv_parse_statement_or_null(p)
		sv_skip_trivia(p)
	}
	if sv_match_ident(p, "else") {
		sv_skip_trivia(p)
		node.else_body = sv_parse_statement_or_null(p)
	}
	return node
}

sv_parse_statement_or_null :: proc(p: ^SVParser) -> ^SVStmt {
	sv_skip_trivia(p)
	sv_skip_attributes(p)
	sv_skip_trivia(p)
	if lexer_peek(&p.l) == SEMICOLON {
		lexer_advance(&p.l)
		return nil
	}
	stmt := sv_parse_statement(p)
	ptr := sv_new(p, SVStmt)
	ptr^ = stmt
	return ptr
}

sv_parse_statement :: proc(p: ^SVParser) -> SVStmt {
	sv_skip_trivia(p)
	sv_skip_attributes(p)
	sv_skip_trivia(p)
	l := &p.l
	c := lexer_peek(l)

	// optional statement label: `name : statement`. `begin : label` is a block label,
	// handled by sv_parse_block, so it is not treated as a statement label here.
	if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
		start := sv_save(p)
		name := lexer_scan_ident(l)
		sv_skip_space_tabs(l)
		if name != "begin" && lexer_peek(l) == COLON && lexer_peek(l, 1) != COLON {
			lexer_advance(l)
			return sv_parse_statement(p)
		}
		sv_restore(p, start)
	}

	switch {
	case c == SEMICOLON:
		// null statement in a context that wants a statement
		lexer_advance(l)
		empty := sv_new(p, SVBlock)
		empty.decls = make([dynamic]SVBlockDecl, p.allocator)
		empty.stmts = make([dynamic]SVStmt, p.allocator)
		return empty
	case c == '@' || c == '#':
		timing := sv_parse_timing_ctl(p)
		stmt := sv_new(p, SVTimingStmt)
		stmt.timing = timing
		stmt.body = sv_parse_statement_or_null(p)
		return stmt
	case c == '$':
		name := sv_scan_system_ident(p)
		sv_skip_trivia(p)
		call: ^SVCall
		if lexer_peek(l) == LPAREN {
			expr := sv_parse_call(p, name, true)
			call = expr.(^SVCall)
		} else {
			call = sv_new(p, SVCall)
			call^ = SVCall {
				name      = name,
				is_system = true,
				args      = make([dynamic]SVCallArg, p.allocator),
			}
		}
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		return call
	case lexer_is_ident_start(c) || c == ESCAPE_SYMBOL:
		name := lexer_scan_ident(l)
		return sv_parse_statement_after_ident(p, name, c == ESCAPE_SYMBOL)
	case: return sv_parse_expr_statement(p, sv_parse_primary(p))
	}
}

sv_parse_statement_after_ident :: proc(p: ^SVParser, name: string, escaped := false) -> SVStmt {
	l := &p.l
	if escaped {
		// Escaped identifiers are never keywords: `\if` is just a signal named "if".
		return sv_parse_expr_statement(p, string(name))
	}
	switch name {
	case "begin": return sv_parse_block(p)
	case "if": return sv_parse_if(p, .NONE)
	case "unique", "unique0", "priority":
		qualifier: SVQualifier = .UNIQUE
		if name == "unique0" { qualifier = .UNIQUE0 }
		if name == "priority" { qualifier = .PRIORITY }
		sv_skip_trivia(p)
		next := sv_scan_ident_required(p)
		switch next {
		case "if": return sv_parse_if(p, qualifier)
		case "case", "casez", "casex": return sv_parse_case(p, qualifier, next)
		case: lexer_panic(l, "Expected 'if' or 'case' after unique/priority")
		}
		lexer_panic(l, "Expected 'if' or 'case' after unique/priority")
	case "case", "casez", "casex": return sv_parse_case(p, .NONE, name)
	case "for": return sv_parse_for(p)
	case "while": return sv_parse_while(p, false)
	case "do": return sv_parse_while(p, true)
	case "repeat": return sv_parse_repeat(p)
	case "forever": return sv_parse_forever(p)
	case "foreach": return sv_parse_foreach(p)
	case "break", "continue":
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		jump := sv_new(p, SVJump)
		jump.kind = name == "break" ? .BREAK : .CONTINUE
		return jump
	case "return":
		jump := sv_new(p, SVJump)
		jump.kind = .RETURN
		sv_skip_trivia(p)
		if lexer_peek(l) != SEMICOLON {
			jump.value = sv_new_expr(p, sv_parse_expr(p, 0))
		}
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		return jump
	case "void":
		// void'( subroutine_call );
		sv_skip_trivia(p)
		lexer_consume(l, SINGLE_QUOTE)
		sv_skip_trivia(p)
		lexer_consume(l, LPAREN)
		sv_skip_trivia(p)
		expr := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		lexer_consume(l, RPAREN)
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
		call, is_call := expr.(^SVCall)
		lexer_ensure(l, is_call, "void' expects a subroutine call")
		return call
	case "assert": return sv_parse_assertion(p, .ASSERT)
	case "assume": return sv_parse_assertion(p, .ASSUME)
	case "cover": return sv_parse_assertion(p, .COVER)
	case "expect": return sv_parse_assertion(p, .EXPECT)
	case "wait",
		 "fork",
		 "join",
		 "join_any",
		 "join_none",
		 "disable",
		 "assign",
		 "deassign",
		 "force",
		 "release",
		 "randcase",
		 "randsequence":
		lexer_panic(l, fmt.tprintf("Unsupported procedural construct '%s' (outside the synthesizable subset)", name))
	case:
		if !escaped && sv_is_reserved_keyword(name) {
			lexer_panic(l, fmt.tprintf("Unsupported procedural construct '%s'", name))
		}
		return sv_parse_expr_statement(p, string(name))
	}
	// unreachable: every case above either returns or panics
	empty := sv_new(p, SVBlock)
	empty.decls = make([dynamic]SVBlockDecl, p.allocator)
	empty.stmts = make([dynamic]SVStmt, p.allocator)
	return empty
}

sv_parse_block :: proc(p: ^SVParser) -> SVStmt {
	l := &p.l
	block := sv_new(p, SVBlock)
	block.decls = make([dynamic]SVBlockDecl, p.allocator)
	block.stmts = make([dynamic]SVStmt, p.allocator)
	sv_skip_trivia(p)
	sv_skip_space_tabs(l)
	if lexer_peek(l) == COLON {
		lexer_advance(l)
		sv_skip_space_tabs(l)
		block.label = sv_scan_ident_required(p)
	}
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, "Unterminated begin block")
		}
		c := lexer_peek(l)
		if c == SEMICOLON {
			lexer_advance(l)
			continue
		}
		if lexer_is_ident_start(c) || c == ESCAPE_SYMBOL {
			escaped := c == ESCAPE_SYMBOL
			name := lexer_scan_ident(l)
			if !escaped && name == "end" {
				sv_skip_trivia(p)
				if lexer_peek(l) == COLON {
					lexer_advance(l)
					sv_skip_space_tabs(l)
					_ = sv_scan_ident_required(p)
				}
				return block
			}
			// statement label: `name : statement`
			sv_skip_space_tabs(l)
			if !escaped && name != "begin" && lexer_peek(l) == COLON && lexer_peek(l, 1) != COLON {
				lexer_advance(l)
				append(&block.stmts, sv_parse_statement(p))
				continue
			}
			if !escaped && name == "import" {
				sv_parse_import_list(p, &block.imports)
				continue
			}
			if !escaped && name == "typedef" {
				append(&block.decls, sv_parse_typedef(p))
				continue
			}
			if !escaped && sv_is_user_type_decl_start(p, name) {
				append(&block.decls, sv_parse_decl_after_type_name(p, name))
				continue
			}
			if !escaped && sv_is_decl_keyword(name) {
				if name == "parameter" || name == "localparam" {
					decl := sv_parse_param_decl_after_keyword(p, name == "localparam")
					sv_skip_trivia(p)
					lexer_consume(l, SEMICOLON)
					append(&block.decls, decl)
				} else if name == "automatic" || name == "static" || name == "const" || name == "var" {
					// lifetime/qualifier before a data type
					append(&block.decls, sv_parse_net_var_decl(p, name))
				} else {
					append(&block.decls, sv_parse_net_var_decl(p, name))
				}
				continue
			}
			append(&block.stmts, sv_parse_statement_after_ident(p, name, escaped))
			continue
		}
		if c == L_SQUARE_BRACKET {
			append(&block.decls, sv_parse_net_var_decl(p, ""))
			continue
		}
		append(&block.stmts, sv_parse_statement(p))
	}
}

sv_parse_if :: proc(p: ^SVParser, qualifier: SVQualifier) -> SVStmt {
	l := &p.l
	node := sv_new(p, SVIf)
	node.qualifier = qualifier
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	node.cond = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	sv_skip_trivia(p)
	node.then_body = sv_parse_statement_or_null(p)
	sv_skip_trivia(p)
	if sv_match_ident(p, "else") {
		sv_skip_trivia(p)
		node.else_body = sv_parse_statement_or_null(p)
	}
	return node
}

sv_parse_case :: proc(p: ^SVParser, qualifier: SVQualifier, keyword: string) -> SVStmt {
	l := &p.l
	node := sv_new(p, SVCase)
	node.qualifier = qualifier
	node.kind = .CASE
	if keyword == "casez" { node.kind = .CASEZ }
	if keyword == "casex" { node.kind = .CASEX }
	node.items = make([dynamic]SVCaseItem, p.allocator)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	node.subject = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	if sv_match_ident(p, "inside") {
		node.is_inside = true
	} else if sv_match_ident(p, "matches") {
		lexer_panic(l, "case ... matches is not supported")
	}
	for {
		sv_skip_trivia(p)
		if sv_at_eof(p) {
			lexer_panic(l, fmt.tprintf("Unterminated %s statement", keyword))
		}
		if sv_match_ident(p, "endcase") { break }
		item := SVCaseItem {
			exprs  = make([dynamic]SVExpr, p.allocator),
			ranges = make([dynamic]SVInsideRange, p.allocator),
		}
		if sv_match_ident(p, "default") {
			item.is_default = true
			sv_skip_trivia(p)
			if lexer_peek(l) == COLON { lexer_advance(l) }
		} else if node.is_inside {
			for {
				sv_skip_trivia(p)
				range: SVInsideRange
				if lexer_peek(l) == L_SQUARE_BRACKET {
					lexer_advance(l)
					sv_skip_trivia(p)
					range.lo = sv_parse_expr(p, 0)
					sv_skip_trivia(p)
					if lexer_peek(l) == COLON {
						lexer_advance(l)
						sv_skip_trivia(p)
						range.hi = sv_parse_expr(p, 0)
						range.has_hi = true
						sv_skip_trivia(p)
					}
					lexer_consume(l, R_SQUARE_BRACKET)
				} else {
					range.lo = sv_parse_expr(p, 0)
				}
				append(&item.ranges, range)
				sv_skip_trivia(p)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					continue
				}
				break
			}
			sv_skip_trivia(p)
			lexer_consume(l, COLON)
		} else {
			for {
				sv_skip_trivia(p)
				append(&item.exprs, sv_parse_expr(p, 0))
				sv_skip_trivia(p)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					continue
				}
				break
			}
			sv_skip_trivia(p)
			lexer_consume(l, COLON)
		}
		sv_skip_trivia(p)
		item.body = sv_parse_statement_or_null(p)
		append(&node.items, item)
	}
	return node
}

sv_parse_for :: proc(p: ^SVParser) -> SVStmt {
	l := &p.l
	node := sv_new(p, SVFor)
	node.var_decls = make([dynamic]^SVNetDecl, p.allocator)
	node.init_assigns = make([dynamic]^SVAssignStmt, p.allocator)
	node.steps = make([dynamic]SVStmt, p.allocator)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)

	if lexer_peek(l) != SEMICOLON {
		type_name := sv_peek_ident(p)
		_, is_type := sv_var_type_keyword(type_name)
		decl_started := is_type || type_name == "var" || type_name == "signed" || type_name == "unsigned" || lexer_peek(l) == L_SQUARE_BRACKET || sv_is_user_type_decl_start(p, type_name)
		if decl_started {
			_ = sv_match_ident(p, "var")
			data := sv_parse_data_type_or_implicit(p)
			decl := sv_new(p, SVNetDecl)
			decl.data = data
			decl.declarators = sv_parse_declarators(p)
			append(&node.var_decls, decl)
		} else {
			for {
				stmt := sv_parse_assignment_or_call(p, sv_parse_statement_base(p))
				assign, is_assign := stmt.(^SVAssignStmt)
				lexer_ensure(l, is_assign, "Expected an assignment in the for-loop initialization")
				append(&node.init_assigns, assign)
				sv_skip_trivia(p)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					continue
				}
				break
			}
		}
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	sv_skip_trivia(p)
	if lexer_peek(l) != SEMICOLON {
		node.cond = sv_new_expr(p, sv_parse_expr(p, 0))
	}
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	sv_skip_trivia(p)
	if lexer_peek(l) != RPAREN {
		for {
			append(&node.steps, sv_parse_assignment_or_call(p, sv_parse_statement_base(p)))
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			break
		}
	}
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	sv_skip_trivia(p)
	node.body = sv_parse_statement_or_null(p)
	return node
}

sv_parse_while :: proc(p: ^SVParser, do_while: bool) -> SVStmt {
	l := &p.l
	node := sv_new(p, SVWhile)
	node.do_while = do_while
	if do_while {
		sv_skip_trivia(p)
		node.body = sv_parse_statement_or_null(p)
		sv_skip_trivia(p)
		lexer_ensure(l, sv_match_ident(p, "while"), "Expected 'while' after do body")
		sv_skip_trivia(p)
	}
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	node.cond = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	if do_while {
		sv_skip_trivia(p)
		lexer_consume(l, SEMICOLON)
	} else {
		sv_skip_trivia(p)
		node.body = sv_parse_statement_or_null(p)
	}
	return node
}

sv_parse_repeat :: proc(p: ^SVParser) -> SVStmt {
	l := &p.l
	node := sv_new(p, SVRepeat)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	node.count = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	sv_skip_trivia(p)
	node.body = sv_parse_statement_or_null(p)
	return node
}

sv_parse_forever :: proc(p: ^SVParser) -> SVStmt {
	node := sv_new(p, SVForever)
	sv_skip_trivia(p)
	node.body = sv_parse_statement_or_null(p)
	return node
}

// foreach ( array_identifier [ loop_variables ] ) statement
sv_parse_foreach :: proc(p: ^SVParser) -> SVStmt {
	l := &p.l
	node := sv_new(p, SVForeach)
	node.loop_vars = make([dynamic]string, p.allocator)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)

	// array identifier (no selects; the brackets hold the loop variables)
	parts := make([dynamic]SVSelectPart, p.allocator)
	name := sv_scan_ident_required(p)
	for {
		sv_skip_space_tabs(l)
		if lexer_peek(l) != DOT { break }
		lexer_advance(l)
		sv_skip_space_tabs(l)
		append(&parts, SVSelectPart{member = sv_scan_ident_required(p)})
	}
	if len(parts) == 0 {
		node.array = name
	} else {
		select_node := sv_new(p, SVSelect)
		select_node^ = SVSelect{base = name, parts = parts}
		node.array = select_node
	}

	sv_skip_trivia(p)
	lexer_consume(l, L_SQUARE_BRACKET)
	sv_skip_trivia(p)
	if lexer_peek(l) != R_SQUARE_BRACKET {
		for {
			sv_skip_trivia(p)
			loop_var := ""
			if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL {
				loop_var = lexer_scan_ident(l)
			}
			append(&node.loop_vars, loop_var)
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			break
		}
	}
	sv_skip_trivia(p)
	lexer_consume(l, R_SQUARE_BRACKET)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	sv_skip_trivia(p)
	node.body = sv_parse_statement_or_null(p)
	return node
}

// Parse the start of an assignment/call statement: handles prefix ++/-- and unary
// operators as statement heads (e.g. `for (...; ...; ++i)`).
sv_parse_statement_base :: proc(p: ^SVParser) -> SVExpr {
	l := &p.l
	sv_skip_trivia(p)
	c := lexer_peek(l)
	if c == '+' || c == '-' || c == '!' || c == '~' || c == '&' || c == '|' || c == '^' {
		return sv_parse_unary(p)
	}
	return sv_parse_primary(p)
}

// assignment / nonblocking assignment / compound assignment / call / ++ / -- without the
// terminating semicolon. `prefix` is the already parsed start of the statement.
sv_parse_assignment_or_call :: proc(p: ^SVParser, prefix: SVExpr) -> SVStmt {
	l := &p.l
	base := sv_parse_postfix(p, prefix)
	sv_skip_trivia(p)
	c := lexer_peek(l)

	if c == SEMICOLON || c == COMMA || c == RPAREN {
		if call, is_call := base.(^SVCall); is_call { return call }
		if inc, is_inc := base.(^SVIncDec); is_inc { return inc }
		if c == SEMICOLON {
			// Task call without arguments or parentheses: `task_name;` / `pkg::task_name;`.
			if ident, is_ident := base.(string); is_ident {
				call := sv_new(p, SVCall)
				call^ = SVCall {
					name = ident,
					args = make([dynamic]SVCallArg, p.allocator),
				}
				return call
			}
			if scoped, is_scoped := base.(SVScopedName); is_scoped {
				call := sv_new(p, SVCall)
				call^ = SVCall {
					name = strings.concatenate({scoped.scope, "::", scoped.name}, p.allocator),
					args = make([dynamic]SVCallArg, p.allocator),
				}
				return call
			}
		}
		lexer_panic(l, "Only subroutine calls and ++/-- can stand alone as expressions")
	}

	op := SVAssignOp.EQ
	length := 0
	matched := true
	nonblocking := false
	if c == EQUAL {
		length = 1
	} else if c == '<' && lexer_peek(l, 1) == '=' {
		length = 2
		nonblocking = true
	} else {
		op, length, matched = sv_match_op_assign(l)
	}
	if !matched {
		lexer_panic(l, "Expected '=', '<=', a compound assignment, or a call")
	}
	lexer_advance(l, length)
	sv_skip_trivia(p)

	timing: ^SVTimingCtl
	if lexer_peek(l) == '#' || lexer_peek(l) == '@' {
		ctl := sv_parse_timing_ctl(p)
		timing = sv_new(p, SVTimingCtl)
		timing^ = ctl
		sv_skip_trivia(p)
	}
	rhs := sv_parse_expr(p, 0)
	assign := sv_new(p, SVAssignStmt)
	assign^ = SVAssignStmt {
		lhs         = base,
		op          = op,
		rhs         = rhs,
		nonblocking = nonblocking,
		timing      = timing,
	}
	return assign
}

sv_match_op_assign :: proc(l: ^Lexer) -> (op: SVAssignOp, length: int, ok: bool) {
	c := lexer_peek(l)
	n := lexer_peek(l, 1)
	switch c {
	case '+': if n == '=' { return .ADD_EQ, 2, true }
	case '-': if n == '=' { return .SUB_EQ, 2, true }
	case '*': if n == '=' { return .MUL_EQ, 2, true }
	case '/': if n == '=' { return .DIV_EQ, 2, true }
	case '%': if n == '=' { return .MOD_EQ, 2, true }
	case '&': if n == '=' { return .AND_EQ, 2, true }
	case '|': if n == '=' { return .OR_EQ, 2, true }
	case '^': if n == '=' { return .XOR_EQ, 2, true }
	case '<': if n == '<' {
				if lexer_peek(l, 2) == '<' && lexer_peek(l, 3) == '=' { return .ASH_L_EQ, 4, true }
				if lexer_peek(l, 2) == '=' { return .SHL_EQ, 3, true }
			}
	case '>': if n == '>' {
				if lexer_peek(l, 2) == '>' && lexer_peek(l, 3) == '=' { return .ASH_R_EQ, 4, true }
				if lexer_peek(l, 2) == '=' { return .SHR_EQ, 3, true }
			}
	}
	return
}

sv_parse_expr_statement :: proc(p: ^SVParser, base: SVExpr) -> SVStmt {
	l := &p.l
	stmt := sv_parse_assignment_or_call(p, base)
	sv_skip_trivia(p)
	lexer_consume(l, SEMICOLON)
	return stmt
}

// ---------------------------------------------------------------------------------------
// Timing controls
// ---------------------------------------------------------------------------------------

sv_parse_timing_ctl :: proc(p: ^SVParser) -> SVTimingCtl {
	l := &p.l
	sv_skip_trivia(p)
	ctl: SVTimingCtl
	if lexer_peek(l) == '#' {
		ctl.is_delay = true
		ctl.delay = sv_parse_delay_value(p)
		return ctl
	}
	lexer_consume(l, '@')
	sv_skip_trivia(p)
	if lexer_peek(l) == ASTERISK {
		lexer_advance(l)
		ctl.any_event = true
		return ctl
	}
	if lexer_peek(l) == LPAREN {
		lexer_advance(l)
		sv_skip_trivia(p)
		if lexer_peek(l) == ASTERISK {
			lexer_advance(l)
			sv_skip_trivia(p)
			lexer_consume(l, RPAREN)
			ctl.any_event = true
			return ctl
		}
		ctl.events = make([dynamic]SVEvent, p.allocator)
		for {
			append(&ctl.events, sv_parse_event(p))
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			if sv_match_ident(p, "or") { continue }
			break
		}
		lexer_consume(l, RPAREN)
		return ctl
	}
	ctl.events = make([dynamic]SVEvent, p.allocator)
	append(&ctl.events, sv_parse_event(p))
	return ctl
}

sv_parse_event :: proc(p: ^SVParser) -> SVEvent {
	l := &p.l
	event: SVEvent
	name := sv_peek_ident(p)
	switch name {
	case "posedge":
		event.edge = .POSEDGE
		_ = sv_scan_ident_required(p)
	case "negedge":
		event.edge = .NEGEDGE
		_ = sv_scan_ident_required(p)
	case "edge":
		event.edge = .EDGE
		_ = sv_scan_ident_required(p)
		sv_skip_trivia(p)
		if lexer_peek(l) == L_SQUARE_BRACKET {
			for lexer_peek(l) != R_SQUARE_BRACKET && lexer_peek(l) != 0 { lexer_advance(l) }
			lexer_consume(l, R_SQUARE_BRACKET)
		}
	}
	sv_skip_trivia(p)
	event.expr = sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	if sv_match_ident(p, "iff") {
		sv_skip_trivia(p)
		event.iff = sv_new_expr(p, sv_parse_expr(p, 0))
	}
	return event
}

// #delay_value or #(mintypmax). Returns the minimum of a mintypmax expression.
sv_parse_delay_value :: proc(p: ^SVParser) -> SVExpr {
	l := &p.l
	lexer_consume(l, '#')
	sv_skip_trivia(p)
	if lexer_peek(l) == LPAREN {
		lexer_advance(l)
		sv_skip_trivia(p)
		value := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		// mintypmax (min:typ:max) or delay2/delay3 commas (rise, fall, turn-off)
		for lexer_peek(l) == COLON || lexer_peek(l) == COMMA {
			lexer_advance(l)
			sv_skip_trivia(p)
			_ = sv_parse_expr(p, 0)
			sv_skip_trivia(p)
		}
		lexer_consume(l, RPAREN)
		return value
	}
	value := sv_parse_primary(p)
	// time literal suffix, e.g. 1ns
	if lexer_is_ident_start(lexer_peek(l)) {
		_ = lexer_scan_ident(l)
	}
	return value
}

// ---------------------------------------------------------------------------------------
// Expressions: precedence climbing over SV_BINARY_OPS
// ---------------------------------------------------------------------------------------

sv_peek_binary_op :: proc(p: ^SVParser) -> (info: SVBinOpInfo, ok: bool) {
	l := &p.l
	if l.idx >= len(l.src) { return }
	// `base +: width` / `base -: width` are indexed part-selects, not additions.
	if (lexer_peek(l) == '+' || lexer_peek(l) == '-') && lexer_peek(l, 1) == ':' { return }
	// `lhs <= #delay expr` / `lhs <= @(event) expr` is a nonblocking assignment with an
	// intra-assignment timing control, never a comparison.
	if lexer_peek(l) == '<' && lexer_peek(l, 1) == '=' {
		scan := l.idx + 2
		for scan < len(l.src) {
			c := l.src[scan]
			if c != WHITESPACE && c != WHITESPACE_TAB && c != NEWLINE && c != NEWLINE_CARRIAGE_RETURN { break }
			scan += 1
		}
		if scan < len(l.src) && (l.src[scan] == '#' || l.src[scan] == '@') { return }
	}
	best_length := 0
	for entry in SV_BINARY_OPS {
		entry_length := len(entry.text)
		if entry_length <= best_length { continue }
		if l.idx + entry_length > len(l.src) { continue }
		matched := true
		for i in 0 ..< entry_length {
			if l.src[l.idx + i] != entry.text[i] {
				matched = false
				break
			}
		}
		if matched {
			info = entry
			best_length = entry_length
		}
	}
	if best_length == 0 { return }
	return info, true
}

sv_parse_expr :: proc(p: ^SVParser, min_prec: u8 = 0) -> SVExpr {
	l := &p.l
	lhs := sv_parse_unary(p)
	for {
		sv_skip_trivia(p)
		// `expr inside { range_list }` (same precedence as the relational operators)
		if min_prec <= SV_PREC_REL && sv_match_ident(p, "inside") {
			sv_skip_trivia(p)
			lexer_consume(l, LCURLY)
			ranges := make([dynamic]SVInsideRange, p.allocator)
			for {
				sv_skip_trivia(p)
				range: SVInsideRange
				if lexer_peek(l) == L_SQUARE_BRACKET {
					lexer_advance(l)
					sv_skip_trivia(p)
					range.lo = sv_parse_expr(p, 0)
					sv_skip_trivia(p)
					if lexer_peek(l) == COLON {
						lexer_advance(l)
						sv_skip_trivia(p)
						range.hi = sv_parse_expr(p, 0)
						range.has_hi = true
						sv_skip_trivia(p)
					}
					lexer_consume(l, R_SQUARE_BRACKET)
				} else {
					range.lo = sv_parse_expr(p, 0)
				}
				append(&ranges, range)
				sv_skip_trivia(p)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					continue
				}
				break
			}
			sv_skip_trivia(p)
			lexer_consume(l, RCURLY)
			node := sv_new(p, SVInside)
			node^ = SVInside{subject = lhs, ranges = ranges}
			lhs = node
			continue
		}
		if lexer_peek(l) == '?' && min_prec <= SV_PREC_TERNARY {
			lexer_advance(l)
			sv_skip_trivia(p)
			when_true := sv_parse_expr(p, 0)
			sv_skip_trivia(p)
			lexer_consume(l, COLON)
			sv_skip_trivia(p)
			when_false := sv_parse_expr(p, SV_PREC_TERNARY) // right associative
			node := sv_new(p, SVTernary)
			node^ = SVTernary {
				cond = lhs,
				lhs  = when_true,
				rhs  = when_false,
			}
			lhs = node
			continue
		}
		info, ok := sv_peek_binary_op(p)
		if !ok || info.prec < min_prec { break }
		lexer_advance(l, len(info.text))
		sv_skip_trivia(p)
		rhs := sv_parse_expr(p, info.prec + 1) // left associative
		node := sv_new(p, SVBinary)
		node^ = SVBinary {
			op  = info.op,
			lhs = lhs,
			rhs = rhs,
		}
		lhs = node
	}
	return lhs
}

sv_parse_unary :: proc(p: ^SVParser) -> SVExpr {
	l := &p.l
	sv_skip_trivia(p)
	c := lexer_peek(l)
	if (c == '+' && lexer_peek(l, 1) == '+') || (c == '-' && lexer_peek(l, 1) == '-') {
		is_dec := c == '-'
		lexer_advance(l, 2)
		operand := sv_parse_unary(p)
		node := sv_new(p, SVIncDec)
		node^ = SVIncDec {
			operand   = operand,
			is_dec    = is_dec,
			is_prefix = true,
		}
		return node
	}

	op := SVUnOp.PLUS
	has_op := true
	switch c {
	case '+': op = .PLUS
	case '-': op = .MINUS
	case '!': op = .NOT
	case '~': switch lexer_peek(l, 1) {
			case '&':
				op = .RED_NAND
				lexer_advance(l)
			case '|':
				op = .RED_NOR
				lexer_advance(l)
			case '^':
				op = .RED_XNOR
				lexer_advance(l)
			case: op = .BIT_NOT
			}
	case '&': op = .RED_AND
	case '|': op = .RED_OR
	case '^': if lexer_peek(l, 1) == '~' {
				op = .RED_XNOR
				lexer_advance(l)
			} else {
				op = .RED_XOR
			}
	case: has_op = false
	}
	if !has_op {
		return sv_parse_postfix(p, sv_parse_primary(p))
	}
	lexer_advance(l)
	operand := sv_parse_unary(p)
	node := sv_new(p, SVUnary)
	node^ = SVUnary {
		op      = op,
		operand = operand,
	}
	return node
}

sv_parse_postfix :: proc(p: ^SVParser, prefix: SVExpr) -> SVExpr {
	l := &p.l
	base := prefix
	if name, is_ident := base.(string); is_ident {
		sv_skip_trivia(p)
		if lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON {
			lexer_advance(l, 2)
			sv_skip_trivia(p)
			member := sv_scan_ident_required(p)
			base = SVScopedName{scope = name, name = member}
			sv_skip_trivia(p)
			if lexer_peek(l) == LPAREN {
				qual := strings.concatenate({name, "::", member}, p.allocator)
				base = sv_parse_call(p, qual, false)
			}
		} else if lexer_peek(l) == LPAREN {
			base = sv_parse_call(p, name, false)
		}
	}

	parts := make([dynamic]SVSelectPart, p.allocator)
	for {
		sv_skip_trivia(p)
		c := lexer_peek(l)
		if c == L_SQUARE_BRACKET {
			lexer_advance(l)
			sv_skip_trivia(p)
			first := sv_parse_expr(p, 0)
			sv_skip_trivia(p)
			part := SVSelectPart {
				kind  = .BIT,
				first = first,
			}
			if lexer_peek(l) == COLON {
				lexer_advance(l)
				sv_skip_trivia(p)
				part.kind = .PART
				part.second = sv_parse_expr(p, 0)
				part.has_second = true
			} else if lexer_peek(l) == '+' && lexer_peek(l, 1) == ':' {
				lexer_advance(l, 2)
				sv_skip_trivia(p)
				part.kind = .INDEXED_PLUS
				part.second = sv_parse_expr(p, 0)
				part.has_second = true
			} else if lexer_peek(l) == '-' && lexer_peek(l, 1) == ':' {
				lexer_advance(l, 2)
				sv_skip_trivia(p)
				part.kind = .INDEXED_MINUS
				part.second = sv_parse_expr(p, 0)
				part.has_second = true
			}
			sv_skip_trivia(p)
			lexer_consume(l, R_SQUARE_BRACKET)
			append(&parts, part)
			continue
		}
		if c == DOT {
			lexer_advance(l)
			sv_skip_trivia(p)
			member := sv_scan_ident_required(p)
			sv_skip_trivia(p)
			if lexer_peek(l) == LPAREN {
				// Method-style call (`queue.push_back(x)`): keep the flattened dotted path as
				// the call name. Only pure identifier paths are accepted.
				if ident, is_ident := base.(string); is_ident {
					b := strings.builder_make(p.allocator)
					strings.write_string(&b, ident)
					for part in parts {
						if part.member == "" {
							lexer_panic(l, "Unsupported method call target")
						}
						strings.write_byte(&b, '.')
						strings.write_string(&b, part.member)
					}
					strings.write_byte(&b, '.')
					strings.write_string(&b, member)
					return sv_parse_call(p, strings.to_string(b), false)
				}
				lexer_panic(l, "Method calls are not supported in the synthesizable subset")
			}
			append(&parts, SVSelectPart{member = member})
			continue
		}
		break
	}

	sv_skip_trivia(p)
	sv_pop_exhausted_inputs(p)
	sv_skip_ws_and_comments(p)
	// size cast whose target is a constant primary, e.g. `$clog2(N)'(x)`
	if sv_peek_cast_paren(p) {
		selected := base
		if len(parts) > 0 {
			select_node := sv_new(p, SVSelect)
			select_node^ = SVSelect {
				base  = base,
				parts = parts,
			}
			selected = select_node
		}
		lexer_advance(l)
		sv_skip_trivia(p)
		lexer_consume(l, LPAREN)
		sv_skip_trivia(p)
		operand := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		lexer_consume(l, RPAREN)
		cast_node := sv_new(p, SVCast)
		cast_node.kind = .SIZE
		cast_node.size = sv_new_expr(p, selected)
		cast_node.operand = operand
		return cast_node
	}
	if (lexer_peek(l) == '+' && lexer_peek(l, 1) == '+') || (lexer_peek(l) == '-' && lexer_peek(l, 1) == '-') {
		is_dec := lexer_peek(l) == '-'
		lexer_advance(l, 2)
		selected := base
		if len(parts) > 0 {
			select_node := sv_new(p, SVSelect)
			select_node^ = SVSelect {
				base  = base,
				parts = parts,
			}
			selected = select_node
		}
		node := sv_new(p, SVIncDec)
		node^ = SVIncDec {
			operand = selected,
			is_dec  = is_dec,
		}
		return node
	}

	if len(parts) == 0 { return base }
	select_node := sv_new(p, SVSelect)
	select_node^ = SVSelect {
		base  = base,
		parts = parts,
	}
	return select_node
}

sv_parse_call :: proc(p: ^SVParser, name: string, is_system: bool) -> SVExpr {
	l := &p.l
	lexer_consume(l, LPAREN)
	call := sv_new(p, SVCall)
	call^ = SVCall {
		name      = name,
		is_system = is_system,
		args      = make([dynamic]SVCallArg, p.allocator),
	}
	sv_skip_trivia(p)
	if lexer_peek(l) != RPAREN {
		for {
			sv_skip_trivia(p)
			arg: SVCallArg
			c := lexer_peek(l)
			if c == DOT {
				lexer_advance(l)
				sv_skip_trivia(p)
				arg.name = sv_scan_ident_required(p)
				sv_skip_trivia(p)
				lexer_consume(l, LPAREN)
				sv_skip_trivia(p)
				if lexer_peek(l) != RPAREN {
					arg.value = sv_new_expr(p, sv_parse_expr(p, 0))
					sv_skip_trivia(p)
				}
				lexer_consume(l, RPAREN)
			} else if c != COMMA && c != RPAREN {
				arg.value = sv_new_expr(p, sv_parse_expr(p, 0))
			}
			append(&call.args, arg)
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				sv_skip_trivia(p)
				if lexer_peek(l) == RPAREN { break }
				continue
			}
			break
		}
	}
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	return call
}

sv_parse_primary :: proc(p: ^SVParser) -> SVExpr {
	l := &p.l
	sv_skip_trivia(p)
	c := lexer_peek(l)
	switch {
	case c == LPAREN:
		lexer_advance(l)
		sv_skip_trivia(p)
		expr := sv_parse_expr(p, 0)
		sv_skip_trivia(p)
		if lexer_peek(l) == COLON {
			lexer_panic(l, "Mintypmax expressions are not supported in this context")
		}
		lexer_consume(l, RPAREN)
		// size cast with a parenthesized constant: (expr)'(operand)
		sv_skip_trivia(p)
		if sv_peek_cast_paren(p) {
			lexer_advance(l)
			sv_skip_trivia(p)
			lexer_consume(l, LPAREN)
			sv_skip_trivia(p)
			operand := sv_parse_expr(p, 0)
			sv_skip_trivia(p)
			lexer_consume(l, RPAREN)
			cast_node := sv_new(p, SVCast)
			cast_node.kind = .SIZE
			cast_node.size = sv_new_expr(p, expr)
			cast_node.operand = operand
			return cast_node
		}
		return expr

	case c == LCURLY: return sv_parse_concat(p)

	case c == SINGLE_QUOTE:
		// '{...} assignment pattern, unsized based number ('hFF, 'b0, 'sd10) or an
		// unbased unsized literal ('0, '1, 'x, 'z).
		if lexer_peek(l, 1) == LCURLY {
			return sv_parse_aggregate(p)
		}
		if sv_is_base_char(lexer_peek(l, 1)) || ((lexer_peek(l, 1) == 's' || lexer_peek(l, 1) == 'S') && sv_is_base_char(lexer_peek(l, 2))) {
			return sv_scan_number(p)
		}
		return sv_scan_unbased_number(p)

	case sv_is_decimal_digit(c):
		number := sv_scan_number(p)
		end_state := sv_save(p)
		crossed := false
		if l.idx >= len(l.src) {
			crossed = true
			sv_pop_exhausted_inputs(p)
		}
		sv_skip_ws_and_comments(p)
		if sv_peek_cast_paren(p) {
			// size cast_node: 8'(expr)
			lexer_advance(l)
			lexer_consume(l, LPAREN)
			sv_skip_trivia(p)
			operand := sv_parse_expr(p, 0)
			sv_skip_trivia(p)
			lexer_consume(l, RPAREN)
			cast_node := sv_new(p, SVCast)
			cast_node.kind = .SIZE
			cast_node.size = sv_new_expr(p, number)
			cast_node.operand = operand
			return cast_node
		}
		if !crossed {
			sv_restore(p, end_state) // leave the cursor right after the literal
		}
		return number

	case c == DOUBLE_QUOTE: return SVStringLit(sv_scan_string(p))

	case c == '$':
		name := sv_scan_system_ident(p)
		sv_skip_trivia(p)
		if lexer_peek(l) == LPAREN {
			return sv_parse_call(p, name, true)
		}
		call := sv_new(p, SVCall)
		call^ = SVCall {
			name      = name,
			is_system = true,
			args      = make([dynamic]SVCallArg, p.allocator),
		}
		return call

	case lexer_is_ident_start(c) || c == ESCAPE_SYMBOL:
		name := lexer_scan_ident(l)
		end_state := sv_save(p)
		sv_skip_space_tabs(l)
		if lexer_peek(l) == COLON && lexer_peek(l, 1) == COLON {
			lexer_advance(l, 2)
			sv_skip_trivia(p)
			scoped := SVScopedName {
				scope = name,
				name  = sv_scan_ident_required(p),
			}
			sv_skip_ws_and_comments(p)
			if lexer_peek(l) == LPAREN {
				call_name := fmt.aprintf("%s::%s", scoped.scope, scoped.name, allocator = p.allocator)
				return sv_parse_call(p, call_name, false)
			}
			if sv_peek_cast_paren(p) {
				target := fmt.aprintf("%s::%s", scoped.scope, scoped.name, allocator = p.allocator)
				return sv_parse_cast(p, target)
			}
			if lexer_peek(l) == SINGLE_QUOTE && lexer_peek(l, 1) == LCURLY {
				lexer_advance(l)
				aggregate := sv_parse_aggregate_body(p)
				node := aggregate.(^SVAggregate)
				node.type_scope = scoped.scope
				node.type_name = scoped.name
				return node
			}
			return scoped
		}
		crossed_boundary := false
		if l.idx >= len(l.src) {
			// identifier ended a macro expansion: continue in the parent input
			crossed_boundary = true
			sv_pop_exhausted_inputs(p)
		}
		sv_skip_ws_and_comments(p)
		if sv_peek_cast_paren(p) {
			return sv_parse_cast(p, name)
		}
		if lexer_peek(l) == SINGLE_QUOTE && lexer_peek(l, 1) == LCURLY {
			lexer_advance(l)
			aggregate := sv_parse_aggregate_body(p)
			node := aggregate.(^SVAggregate)
			node.type_name = name
			return node
		}
		if !crossed_boundary {
			sv_restore(p, end_state) // leave the cursor right after the identifier
		}
		return string(name)
	}

	lexer_panic(l, fmt.tprintf("Unexpected character '%r' in expression", c))
	return SVNumber{}
}

// True for `'(` (whitespace allowed between the quote and the parenthesis).
sv_peek_cast_paren :: proc(p: ^SVParser) -> bool {
	l := &p.l
	if lexer_peek(l) != SINGLE_QUOTE { return false }
	start := sv_save(p)
	lexer_advance(l)
	sv_skip_ws_and_comments(p)
	ok := lexer_peek(l) == LPAREN
	sv_restore(p, start)
	return ok
}

sv_parse_cast :: proc(p: ^SVParser, target: string) -> SVExpr {
	l := &p.l
	lexer_consume(l, SINGLE_QUOTE)
	sv_skip_trivia(p)
	lexer_consume(l, LPAREN)
	sv_skip_trivia(p)
	operand := sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	lexer_consume(l, RPAREN)
	cast_node := sv_new(p, SVCast)
	cast_node.operand = operand
	if target == "signed" || target == "unsigned" {
		cast_node.kind = .SIGNING
		cast_node.target = target
	} else {
		cast_node.kind = .TYPE
		cast_node.target = target
		if vt, ok := sv_var_type_keyword(target); ok {
			cast_node.data.var_type = vt
		}
	}
	return cast_node
}

// Assignment pattern: '{ [key:] value, ... } or '{ count { value, ... } }
sv_parse_aggregate :: proc(p: ^SVParser) -> SVExpr {
	l := &p.l
	lexer_consume(l, SINGLE_QUOTE)
	return sv_parse_aggregate_body(p)
}

sv_parse_aggregate_body :: proc(p: ^SVParser) -> SVExpr {
	l := &p.l
	lexer_consume(l, LCURLY)
	node := sv_new(p, SVAggregate)
	node^ = SVAggregate{entries = make([dynamic]SVAggregateEntry, p.allocator)}
	sv_skip_trivia(p)
	if lexer_peek(l) == RCURLY {
		lexer_advance(l)
		return node
	}
	for {
		sv_skip_trivia(p)
		entry: SVAggregateEntry
		// optional key: identifier or constant expression followed by ':'
		if lexer_is_ident_start(lexer_peek(l)) || lexer_peek(l) == ESCAPE_SYMBOL {
			start := sv_save(p)
			name := lexer_scan_ident(l)
			sv_skip_space_tabs(l)
			if lexer_peek(l) == COLON && lexer_peek(l, 1) != COLON {
				lexer_advance(l)
				entry.key = name
				sv_skip_trivia(p)
			} else {
				sv_restore(p, start)
			}
		} else if sv_is_decimal_digit(lexer_peek(l)) {
			start := sv_save(p)
			number := sv_scan_number(p)
			sv_skip_space_tabs(l)
			if lexer_peek(l) == COLON && lexer_peek(l, 1) != COLON {
				lexer_advance(l)
				entry.key = number.raw
				sv_skip_trivia(p)
			} else {
				sv_restore(p, start)
			}
		} else if lexer_peek(l) == DOUBLE_QUOTE {
			// string keys: '{ "name": value, ... }
			start := sv_save(p)
			text := sv_scan_string(p)
			sv_skip_space_tabs(l)
			if lexer_peek(l) == COLON && lexer_peek(l, 1) != COLON {
				lexer_advance(l)
				entry.key = text
				sv_skip_trivia(p)
			} else {
				sv_restore(p, start)
			}
		}
		entry.value = sv_parse_expr(p, 0)
		sv_skip_trivia(p)

		// replication form: the first expression is the count and '{' follows
		if len(node.entries) == 0 && lexer_peek(l) == LCURLY {
			node.count = sv_new_expr(p, entry.value)
			lexer_advance(l)
			sv_skip_trivia(p)
			for lexer_peek(l) != RCURLY {
				append(&node.entries, SVAggregateEntry{value = sv_parse_expr(p, 0)})
				sv_skip_trivia(p)
				if lexer_peek(l) == COMMA {
					lexer_advance(l)
					sv_skip_trivia(p)
					continue
				}
				break
			}
			lexer_consume(l, RCURLY)
			sv_skip_trivia(p)
			lexer_consume(l, RCURLY)
			return node
		}

		append(&node.entries, entry)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, RCURLY)
	return node
}

sv_parse_concat :: proc(p: ^SVParser) -> SVExpr {
	l := &p.l
	lexer_consume(l, LCURLY)
	sv_skip_trivia(p)
	// streaming concatenation: {<< [slice] { a, b }} / {>> ...}
	if (lexer_peek(l) == '<' && lexer_peek(l, 1) == '<') || (lexer_peek(l) == '>' && lexer_peek(l, 1) == '>') {
		stream := sv_new(p, SVStream)
		stream.dir = lexer_peek(l) == '<' ? .LEFT : .RIGHT
		lexer_advance(l, 2)
		sv_skip_trivia(p)
		if lexer_peek(l) != LCURLY {
			stream.slice = sv_new_expr(p, sv_parse_expr(p, 0))
			sv_skip_trivia(p)
		}
		lexer_consume(l, LCURLY)
		for {
			sv_skip_trivia(p)
			append(&stream.parts, sv_parse_expr(p, 0))
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				continue
			}
			break
		}
		sv_skip_trivia(p)
		lexer_consume(l, RCURLY)
		sv_skip_trivia(p)
		lexer_consume(l, RCURLY)
		return stream
	}
	if lexer_peek(l) == RCURLY {
		// `{}` is not legal SV, but appears in real code as an empty queue/concatenation
		// literal (e.g. clearing a queue). Accept it as an empty concatenation.
		lexer_advance(l)
		node := sv_new(p, SVConcat)
		node^ = SVConcat {
			parts = make([dynamic]SVExpr, p.allocator),
		}
		return node
	}
	first := sv_parse_expr(p, 0)
	sv_skip_trivia(p)
	node := sv_new(p, SVConcat)
	node^ = SVConcat {
		parts = make([dynamic]SVExpr, p.allocator),
	}

	if lexer_peek(l) == LCURLY {
		// replication: {count{ a, b }}
		lexer_advance(l)
		sv_skip_trivia(p)
		for {
			append(&node.parts, sv_parse_expr(p, 0))
			sv_skip_trivia(p)
			if lexer_peek(l) == COMMA {
				lexer_advance(l)
				sv_skip_trivia(p)
				continue
			}
			break
		}
		lexer_consume(l, RCURLY)
		sv_skip_trivia(p)
		lexer_consume(l, RCURLY)
		node.count = sv_new_expr(p, first)
		return node
	}

	append(&node.parts, first)
	for {
		sv_skip_trivia(p)
		if lexer_peek(l) == COMMA {
			lexer_advance(l)
			sv_skip_trivia(p)
			append(&node.parts, sv_parse_expr(p, 0))
			continue
		}
		break
	}
	sv_skip_trivia(p)
	lexer_consume(l, RCURLY)
	return node
}

// ---------------------------------------------------------------------------------------
// Reserved keywords (IEEE 1800-2023 Annex B). Used to reject unsupported constructs with
// a clear message instead of mis-parsing them as instantiations or expression statements.
// ---------------------------------------------------------------------------------------

sv_is_reserved_keyword :: proc(name: string) -> bool {
	switch name {
	case "accept_on",
		 "alias",
		 "always",
		 "always_comb",
		 "always_ff",
		 "always_latch",
		 "and",
		 "assert",
		 "assign",
		 "assume",
		 "automatic",
		 "before",
		 "begin",
		 "bind",
		 "bins",
		 "binsof",
		 "bit",
		 "break",
		 "buf",
		 "bufif0",
		 "bufif1",
		 "byte",
		 "case",
		 "casex",
		 "casez",
		 "cell",
		 "chandle",
		 "checker",
		 "class",
		 "clocking",
		 "cmos",
		 "config",
		 "const",
		 "constraint",
		 "context",
		 "continue",
		 "cover",
		 "covergroup",
		 "coverpoint",
		 "cross",
		 "deassign",
		 "default",
		 "defparam",
		 "design",
		 "disable",
		 "dist",
		 "do",
		 "edge",
		 "else",
		 "end",
		 "endcase",
		 "endchecker",
		 "endclass",
		 "endclocking",
		 "endconfig",
		 "endfunction",
		 "endgenerate",
		 "endgroup",
		 "endinterface",
		 "endmodule",
		 "endpackage",
		 "endprimitive",
		 "endprogram",
		 "endproperty",
		 "endspecify",
		 "endsequence",
		 "endtable",
		 "endtask",
		 "enum",
		 "event",
		 "eventually",
		 "expect",
		 "export",
		 "extends",
		 "extern",
		 "final",
		 "first_match",
		 "for",
		 "force",
		 "foreach",
		 "forever",
		 "fork",
		 "forkjoin",
		 "function",
		 "generate",
		 "genvar",
		 "global",
		 "highz0",
		 "highz1",
		 "if",
		 "iff",
		 "ifnone",
		 "ignore_bins",
		 "illegal_bins",
		 "implements",
		 "implies",
		 "import",
		 "incdir",
		 "include",
		 "initial",
		 "inout",
		 "input",
		 "inside",
		 "instance",
		 "int",
		 "integer",
		 "interconnect",
		 "interface",
		 "intersect",
		 "join",
		 "join_any",
		 "join_none",
		 "large",
		 "let",
		 "liblist",
		 "library",
		 "local",
		 "localparam",
		 "logic",
		 "longint",
		 "macromodule",
		 "matches",
		 "medium",
		 "modport",
		 "module",
		 "nand",
		 "negedge",
		 "nettype",
		 "new",
		 "nexttime",
		 "nmos",
		 "nor",
		 "noshowcancelled",
		 "not",
		 "notif0",
		 "notif1",
		 "null",
		 "or",
		 "output",
		 "package",
		 "packed",
		 "parameter",
		 "pmos",
		 "posedge",
		 "primitive",
		 "priority",
		 "program",
		 "property",
		 "protected",
		 "pull0",
		 "pull1",
		 "pulldown",
		 "pullup",
		 "pulsestyle_ondetect",
		 "pulsestyle_onevent",
		 "pure",
		 "rand",
		 "randc",
		 "randcase",
		 "randsequence",
		 "rcmos",
		 "real",
		 "realtime",
		 "ref",
		 "reg",
		 "reject_on",
		 "release",
		 "repeat",
		 "restrict",
		 "return",
		 "rnmos",
		 "rpmos",
		 "rtran",
		 "rtranif0",
		 "rtranif1",
		 "s_always",
		 "s_eventually",
		 "s_nexttime",
		 "s_until",
		 "s_until_with",
		 "scalared",
		 "sequence",
		 "shortint",
		 "shortreal",
		 "showcancelled",
		 "signed",
		 "small",
		 "soft",
		 "solve",
		 "specify",
		 "specparam",
		 "static",
		 "string",
		 "strong",
		 "strong0",
		 "strong1",
		 "struct",
		 "super",
		 "supply0",
		 "supply1",
		 "sync_accept_on",
		 "sync_reject_on",
		 "table",
		 "tagged",
		 "task",
		 "this",
		 "throughout",
		 "time",
		 "timeprecision",
		 "timeunit",
		 "tran",
		 "tranif0",
		 "tranif1",
		 "tri",
		 "tri0",
		 "tri1",
		 "triand",
		 "trior",
		 "trireg",
		 "type",
		 "typedef",
		 "union",
		 "unique",
		 "unique0",
		 "unsigned",
		 "until",
		 "until_with",
		 "untyped",
		 "use",
		 "uwire",
		 "var",
		 "vectored",
		 "virtual",
		 "void",
		 "wait",
		 "wait_order",
		 "wand",
		 "weak",
		 "weak0",
		 "weak1",
		 "while",
		 "wildcard",
		 "wire",
		 "with",
		 "within",
		 "wor",
		 "xnor",
		 "xor":
		return true
	}
	return false
}
