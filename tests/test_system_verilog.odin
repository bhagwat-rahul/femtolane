/*
Regression tests for the SystemVerilog frontend in src/system_verilog.odin.

The parser is single pass and builds a typed AST; these tests pin down the AST shape for
every construct in the ASIC synthesizable subset (IEEE 1800-2023 grammar, Annex A), plus
the inline preprocessing (macros, conditionals, includes). Each test uses an in-memory
source string (no external files) except the `include tests, which use a temporary
directory under tests/.
*/

package tests

import main "../src"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------------------

SVTestContext :: struct {
	arena: virtual.Arena,
	ast:   main.SystemVerilogAST,
	alloc: mem.Allocator,
}

sv_test_begin :: proc(ctx: ^SVTestContext) {
	ensure(virtual.arena_init_growing(&ctx.arena) == nil)
	ctx.alloc = virtual.arena_allocator(&ctx.arena)
	main.system_verilog_ast_init(&ctx.ast, ctx.alloc)
}

sv_test_parse :: proc(ctx: ^SVTestContext, source: string, filepath := "sv_unit_test.sv") {
	main.system_verilog_parse_source_to_ast(source, filepath, &ctx.ast, ctx.alloc)
}

// Join Verilog source lines (avoids quoting huge strings in the test bodies).
sv_src :: proc(lines: ..string) -> string {
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// Convenience: parse one source string and return the only module in it.
sv_single_module :: proc(t: ^testing.T, ctx: ^SVTestContext, source: string) -> ^main.SVModule {
	sv_test_parse(ctx, source)
	testing.expectf(t, len(ctx.ast.modules) == 1, "expected 1 module, got %d", len(ctx.ast.modules))
	if len(ctx.ast.modules) != 1 { return nil }
	return ctx.ast.modules[0]
}

sv_module :: proc(t: ^testing.T, ctx: ^SVTestContext, name: string) -> ^main.SVModule {
	module := ctx.ast.module_hash_map[name]
	testing.expectf(t, module != nil, "module %q not found", name)
	return module
}

sv_find_port :: proc(t: ^testing.T, module: ^main.SVModule, name: string) -> ^main.SVPort {
	for port in module.ports {
		if port.name == name { return port }
	}
	testing.expectf(t, false, "port %q not found in %s", name, module.name)
	return nil
}

sv_assign_rhs :: proc(t: ^testing.T, module: ^main.SVModule, lhs: string) -> (rhs: main.SVExpr, found: bool) {
	for item in module.items {
		#partial switch v in item {
		case ^main.SVContAssign:
			for pair in v.pairs {
				if name, is_name := pair.lhs.(string); is_name && name == lhs {
					return pair.rhs, true
				}
			}
		}
	}
	testing.expectf(t, false, "continuous assign to %q not found", lhs)
	return
}

sv_binary :: proc(t: ^testing.T, expr: main.SVExpr, op: main.SVBinOp) -> ^main.SVBinary {
	node, ok := expr.(^main.SVBinary)
	testing.expect(t, ok, "expected a binary expression")
	if !ok { return nil }
	testing.expect_value(t, node.op, op)
	return node
}

sv_ternary :: proc(t: ^testing.T, expr: main.SVExpr) -> ^main.SVTernary {
	node, ok := expr.(^main.SVTernary)
	testing.expect(t, ok, "expected a ternary expression")
	return ok ? node : nil
}

sv_select :: proc(t: ^testing.T, expr: main.SVExpr) -> ^main.SVSelect {
	node, ok := expr.(^main.SVSelect)
	testing.expect(t, ok, "expected a select expression")
	return ok ? node : nil
}

sv_number :: proc(t: ^testing.T, expr: main.SVExpr) -> main.SVNumber {
	number, ok := expr.(^main.SVNumber)
	testing.expect(t, ok, "expected a numeric literal")
	return number^
}

sv_find_decl :: proc(t: ^testing.T, module: ^main.SVModule, name: string) -> ^main.SVNetDecl {
	for item in module.items {
		#partial switch v in item {
		case ^main.SVNetDecl:
			for d in v.declarators {
				if d.name == name { return v }
			}
		}
	}
	testing.expectf(t, false, "declaration %q not found", name)
	return nil
}

sv_find_typedef :: proc(t: ^testing.T, module: ^main.SVModule, name: string) -> ^main.SVTypeDecl {
	for item in module.items {
		#partial switch v in item {
		case ^main.SVTypeDecl:
			if v.name == name { return v }
		}
	}
	testing.expectf(t, false, "typedef %q not found", name)
	return nil
}

sv_param_expr :: proc(t: ^testing.T, module: ^main.SVModule, name: string) -> ^main.SVExpr {
	for item in module.items {
		#partial switch v in item {
		case ^main.SVParamDecl:
			for assignment in v.assignments {
				if assignment.name == name && assignment.value != nil { return assignment.value }
			}
		}
	}
	testing.expectf(t, false, "param %q not found", name)
	return nil
}

sv_param_number :: proc(t: ^testing.T, module: ^main.SVModule, name: string) -> main.SVNumber {
	value := sv_param_expr(t, module, name)
	if value == nil { return {} }
	return sv_number(t, value^)
}

sv_proc :: proc(t: ^testing.T, module: ^main.SVModule, kind: main.SVProcKind) -> ^main.SVProc {
	for item in module.items {
		#partial switch v in item {
		case ^main.SVProc:
			if v.kind == kind { return v }
		}
	}
	testing.expectf(t, false, "process kind %v not found in %s", kind, module.name)
	return nil
}

sv_block :: proc(t: ^testing.T, stmt: main.SVStmt) -> ^main.SVBlock {
	block, ok := stmt.(^main.SVBlock)
	testing.expect(t, ok, "expected a begin/end block")
	return ok ? block : nil
}

// ---------------------------------------------------------------------------------------
// Lexical conventions: numbers, strings, comments, attributes
// ---------------------------------------------------------------------------------------

@(test)
test_sv_numbers :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"// comment",
		"module numbers;",
		"  localparam HEX   = 8'hFF;",
		"  localparam BIN   = 4'b1010;",
		"  localparam OCT   = 3'o7;",
		"  localparam UHEX  = 'hx;",
		"  localparam UBIN  = 'b0;",
		"  localparam UDEC  = 'sd10;",
		"  localparam ZERO  = '0;",
		"  localparam ONE   = '1;",
		"  localparam XBIT  = 'x;",
		"  localparam DEC   = 12_345;",
		"  localparam REAL  = 3.5;",
		"  localparam EXP   = 1e3;",
		"  localparam TIME  = 300ps;",
		"  localparam SPACE = 4'h 0;", // tolerated generator output (not strict LRM)
		"  localparam TQ = \"\"\"hello \"world\" \"\"\";",
		"  (* keep *) wire attr_w;",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	hex := sv_param_number(t, module, "HEX")
	testing.expect_value(t, hex.width, u32(8))
	testing.expect_value(t, hex.base, main.SVNumberBase.HEX)
	testing.expect_value(t, hex.value, u64(0xFF))
	testing.expect_value(t, hex.is_signed, false)

	bin := sv_param_number(t, module, "BIN")
	testing.expect_value(t, bin.base, main.SVNumberBase.BIN)
	testing.expect_value(t, bin.value, u64(10))

	oct := sv_param_number(t, module, "OCT")
	testing.expect_value(t, oct.base, main.SVNumberBase.OCT)
	testing.expect_value(t, oct.value, u64(7))

	uhex := sv_param_number(t, module, "UHEX")
	testing.expect_value(t, uhex.width, u32(0))
	testing.expect_value(t, uhex.base, main.SVNumberBase.HEX)
	testing.expect(t, uhex.has_x_z, "x digit should set has_x_z")

	udec := sv_param_number(t, module, "UDEC")
	testing.expect_value(t, udec.is_signed, true)
	testing.expect_value(t, udec.value, u64(10))

	zero := sv_param_number(t, module, "ZERO")
	testing.expect_value(t, zero.is_unbased, true)
	testing.expect_value(t, zero.value, u64(0))

	one := sv_param_number(t, module, "ONE")
	testing.expect_value(t, one.is_unbased, true)
	testing.expect_value(t, one.value, u64(1))

	xbit := sv_param_number(t, module, "XBIT")
	testing.expect(t, xbit.has_x_z, "unbased 'x should set has_x_z")

	dec := sv_param_number(t, module, "DEC")
	testing.expect_value(t, dec.value, u64(12345))

	real := sv_param_number(t, module, "REAL")
	testing.expect_value(t, real.is_real, true)
	testing.expect(t, real.real_value == f64(3.5), "real literal value")

	exp := sv_param_number(t, module, "EXP")
	testing.expect_value(t, exp.is_real, true)
	testing.expect(t, exp.real_value == f64(1000.0), "exponent literal value")

	tim := sv_param_number(t, module, "TIME")
	testing.expect_value(t, tim.time_unit, main.SVTimeUnit.PS)
	testing.expect_value(t, tim.value, u64(300))

	space := sv_param_number(t, module, "SPACE")
	testing.expect_value(t, space.value, u64(0))

	tq := sv_param_expr(t, module, "TQ")
	if tq != nil {
		triple, is_triple := tq^.(main.SVStringLit)
		testing.expect(t, is_triple, "expected a triple-quoted string literal")
		if is_triple {
			testing.expect(t, strings.contains(string(triple), "\"world\""), "triple-quoted string content")
		}
	}
}

// ---------------------------------------------------------------------------------------
// Modules and ports: ANSI, non-ANSI, wildcard headers, interface ports
// ---------------------------------------------------------------------------------------

@(test)
test_sv_modules_and_ports :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module ansi #(",
		"  parameter int W = 8,",
		"  parameter [3:0] M = 4'd3,",
		"  localparam E = 1,",
		"  parameter type T = logic [7:0]",
		") (",
		"  input  wire             clk,",
		"  input  wire [W-1:0]     a, b,",
		"  output reg  [W-1:0]     q,",
		"  output logic            v = 1'b0,",
		"  inout  wire             io,",
		"  input  wire [7:0]       mem [0:3],",
		"  my_if.slave             bus",
		");",
		"endmodule",
		"module nonansi (a, q);",
		"  input [7:0] a;",
		"  output [7:0] q;",
		"  reg [7:0] q;",
		"endmodule",
		"module wild (.*);",
		"  input clk;",
		"  output [3:0] q;",
		"endmodule",
		"module typed_params #(int N = 5, M = N*16, type T = int, T x = 0) ();",
		"endmodule",
	)
	sv_test_parse(&ctx, source)

	ansi := sv_module(t, &ctx, "ansi")
	testing.expect_value(t, ansi.is_ansi, true)
	testing.expect_value(t, len(ansi.params), 4)
	testing.expect_value(t, ansi.params[3].is_type, true)
	testing.expect_value(t, ansi.params[3].assignments[0].name, "T")
	default_type := ansi.params[3].assignments[0].type_value
	testing.expect(t, default_type != nil, "type parameter default missing")
	if default_type != nil {
		testing.expect_value(t, default_type.var_type, main.SVVarType.LOGIC)
		testing.expect_value(t, len(default_type.packed_dims), 1)
	}

	testing.expect_value(t, len(ansi.ports), 8)
	clk := sv_find_port(t, ansi, "clk")
	testing.expect_value(t, clk.dir, main.SVPortDir.INPUT)
	testing.expect_value(t, clk.net_type, main.SVNetType.WIRE)

	a := sv_find_port(t, ansi, "a")
	testing.expect_value(t, a.dir, main.SVPortDir.INPUT)
	testing.expect_value(t, len(a.data.packed_dims), 1)

	b := sv_find_port(t, ansi, "b")
	testing.expect_value(t, len(b.data.packed_dims), 1) // inherited from `a`

	q := sv_find_port(t, ansi, "q")
	testing.expect_value(t, q.dir, main.SVPortDir.OUTPUT)
	testing.expect_value(t, q.data.var_type, main.SVVarType.REG)

	v := sv_find_port(t, ansi, "v")
	testing.expect_value(t, v.data.var_type, main.SVVarType.LOGIC)
	testing.expect(t, v.default_value != nil, "ANSI port default missing")

	io := sv_find_port(t, ansi, "io")
	testing.expect_value(t, io.dir, main.SVPortDir.INOUT)

	mem := sv_find_port(t, ansi, "mem")
	testing.expect_value(t, len(mem.unpacked_dims), 1)
	testing.expect_value(t, mem.unpacked_dims[0].is_size, false) // [0:3] range

	bus := sv_find_port(t, ansi, "bus")
	testing.expect_value(t, bus.iface_name, "my_if")
	testing.expect_value(t, bus.modport, "slave")

	nonansi := sv_module(t, &ctx, "nonansi")
	testing.expect_value(t, nonansi.is_ansi, false)
	nonansi_q := sv_find_port(t, nonansi, "q")
	testing.expect_value(t, nonansi_q.dir, main.SVPortDir.OUTPUT)

	wild := sv_module(t, &ctx, "wild")
	testing.expect_value(t, wild.wildcard_ports, true)
	testing.expect_value(t, len(wild.ports), 2)

	typed := sv_module(t, &ctx, "typed_params")
	testing.expect_value(t, len(typed.params), 3) // `int N, M` groups two assignments
	testing.expect_value(t, len(typed.params[0].assignments), 2)
	testing.expect_value(t, typed.params[1].is_type, true)
	testing.expect_value(t, typed.params[2].data.type_name, "T")
	testing.expect_value(t, typed.params[2].assignments[0].name, "x")
	testing.expect(t, typed.params[2].assignments[0].value != nil, "typed value parameter default missing")
}

// ---------------------------------------------------------------------------------------
// Declarations, typedefs, enums, packed structs/unions and type references
// ---------------------------------------------------------------------------------------

@(test)
test_sv_declarations_and_types :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module decl;",
		"  wire w0;",
		"  wire signed [7:0] w1 = 8'h1, w2 = 8'h2;",
		"  reg [3:0] r0;",
		"  logic [1:0][3:0] packed2d;",
		"  bit b0;",
		"  int i0;",
		"  integer i1;",
		"  byte y0;",
		"  time t0;",
		"  real f0;",
		"  realtime rt0;",
		"  string s0;",
		"  signed [3:0] imp0;",
		"  const int c0 = 5;",
		"  var logic v0;",
		"  wire [3:0] arr0 [0:3];",
		"  typedef logic [7:0] byte_t;",
		"  typedef enum logic [1:0] { IDLE, RUN = 2, DONE } state_t;",
		"  typedef struct packed { logic [3:0] a; byte_t b; } s_t;",
		"  typedef union packed { logic [7:0] all; byte_t bytes; } u_t;",
		"  typedef byte_t word_t [0:1];",
		"  byte_t x0;",
		"  state_t st;",
		"  s_t s1;",
		"  pkg::other_t o0;",
		"  enum logic { A, B } e0;",
		"  struct packed { logic x; } s2;",
		"  struct packed { ext_t e; logic y; } s3;",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)
	testing.expect_value(t, len(ctx.ast.type_names), 5) // byte_t, state_t, s_t, u_t, word_t

	w1 := sv_find_decl(t, module, "w1")
	testing.expect_value(t, w1.net_type, main.SVNetType.WIRE)
	testing.expect_value(t, w1.data.is_signed, true)
	testing.expect_value(t, len(w1.data.packed_dims), 1)
	testing.expect(t, w1.declarators[0].init != nil, "net initialization missing")
	testing.expect(t, w1.declarators[1].init != nil, "second declarator init missing")

	packed2d := sv_find_decl(t, module, "packed2d")
	testing.expect_value(t, len(packed2d.data.packed_dims), 2)

	imp := sv_find_decl(t, module, "imp0")
	testing.expect_value(t, imp.data.is_signed, true)

	arr := sv_find_decl(t, module, "arr0")
	testing.expect_value(t, len(arr.declarators[0].unpacked_dims), 1)

	byte_t := sv_find_typedef(t, module, "byte_t")
	testing.expect_value(t, byte_t.data.var_type, main.SVVarType.LOGIC)
	testing.expect_value(t, len(byte_t.data.packed_dims), 1)

	state_t := sv_find_typedef(t, module, "state_t")
	testing.expect(t, state_t.data.spec != nil, "enum spec missing")
	if state_t.data.spec != nil {
		testing.expect_value(t, state_t.data.spec.kind, main.SVTypeSpecKind.ENUM)
		testing.expect_value(t, len(state_t.data.spec.enum_names), 3)
		testing.expect_value(t, state_t.data.spec.enum_names[0].name, "IDLE")
		testing.expect(t, state_t.data.spec.enum_names[1].value != nil, "enum value missing")
	}

	s_t := sv_find_typedef(t, module, "s_t")
	testing.expect(t, s_t.data.spec != nil, "struct spec missing")
	if s_t.data.spec != nil {
		testing.expect_value(t, s_t.data.spec.kind, main.SVTypeSpecKind.STRUCT)
		testing.expect_value(t, s_t.data.spec.is_packed, true)
		testing.expect_value(t, len(s_t.data.spec.members), 2)
		testing.expect_value(t, s_t.data.spec.members[1].declarators[0].name, "b")
	}

	u_t := sv_find_typedef(t, module, "u_t")
	testing.expect(t, u_t.data.spec != nil, "union spec missing")
	if u_t.data.spec != nil {
		testing.expect_value(t, u_t.data.spec.kind, main.SVTypeSpecKind.UNION)
	}

	word_t := sv_find_typedef(t, module, "word_t")
	testing.expect_value(t, len(word_t.unpacked_dims), 1)
	testing.expect_value(t, word_t.data.type_name, "byte_t")

	x0 := sv_find_decl(t, module, "x0")
	testing.expect_value(t, x0.data.type_name, "byte_t")

	o0 := sv_find_decl(t, module, "o0")
	testing.expect_value(t, o0.data.type_scope, "pkg")
	testing.expect_value(t, o0.data.type_name, "other_t")

	e0 := sv_find_decl(t, module, "e0")
	testing.expect(t, e0.data.spec != nil, "inline enum declaration missing")

	s3 := sv_find_decl(t, module, "s3")
	testing.expect(t, s3.data.spec != nil, "inline struct declaration missing")
	if s3.data.spec != nil {
		testing.expect_value(t, s3.data.spec.members[0].data.type_name, "ext_t")
		testing.expect_value(t, s3.data.spec.members[0].declarators[0].name, "e")
	}
}

// ---------------------------------------------------------------------------------------
// Expressions: precedence, unary/reduction operators, ternary, casts
// ---------------------------------------------------------------------------------------

@(test)
test_sv_expressions :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module expr;",
		"  logic [7:0] a, b, c, d, e;",
		"  assign p0 = a + b * c;",
		"  assign p1 = (a + b) * c;",
		"  assign p2 = a | b & c ^ d;",
		"  assign p3 = a == b && c != d;",
		"  assign p4 = ~a & ~&b | ^c;",
		"  assign p5 = a << 2 + 1;",
		"  assign p6 = -a ** 2;",
		"  assign p7 = a ? b : c ? d : e;",
		"  assign cast0 = signed'(a);",
		"  assign cast1 = 8'(a);",
		"  assign cast2 = (4)'(a);",
		"  assign cast3 = ( 2 ) ' (a);",
		"  assign cast4 = pkg::t'(a);",
		"  assign cast5 = $clog2(8)'(a);",
		"  assign sys0 = $unsigned(a);",
		"  assign scoped = pkg::CONST;",
		"  assign call = pkg::func(a, .x(b));",
		"  assign inc0 = a++;",
		"  assign inc1 = ++a;",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	p0, _ := sv_assign_rhs(t, module, "p0")
	add := sv_binary(t, p0, .ADD)
	if add != nil {
		mul := sv_binary(t, add.rhs, .MUL)
		testing.expect(t, mul != nil, "multiplication should bind tighter than addition")
	}

	p1, _ := sv_assign_rhs(t, module, "p1")
	mul := sv_binary(t, p1, .MUL)
	if mul != nil {
		sv_binary(t, mul.lhs, .ADD)
	}

	p2, _ := sv_assign_rhs(t, module, "p2")
	or_node := sv_binary(t, p2, .BIT_OR)
	if or_node != nil {
		xor_node := sv_binary(t, or_node.rhs, .BIT_XOR)
		if xor_node != nil {
			sv_binary(t, xor_node.lhs, .BIT_AND)
		}
	}

	p3, _ := sv_assign_rhs(t, module, "p3")
	log_and := sv_binary(t, p3, .LOG_AND)
	if log_and != nil {
		sv_binary(t, log_and.lhs, .EQ)
		sv_binary(t, log_and.rhs, .NE)
	}

	p4, _ := sv_assign_rhs(t, module, "p4")
	bit_or := sv_binary(t, p4, .BIT_OR)
	if bit_or != nil {
		left := sv_binary(t, bit_or.lhs, .BIT_AND)
		if left != nil {
			unary, ok := left.lhs.(^main.SVUnary)
			testing.expect(t, ok && unary.op == .BIT_NOT, "expected ~a")
		}
		right, ok := bit_or.rhs.(^main.SVUnary)
		testing.expect(t, ok && right.op == .RED_XOR, "expected ^c")
	}

	p5, _ := sv_assign_rhs(t, module, "p5")
	shl := sv_binary(t, p5, .SHL)
	if shl != nil {
		sv_binary(t, shl.rhs, .ADD) // a << (2 + 1)
	}

	p6, _ := sv_assign_rhs(t, module, "p6")
	pow := sv_binary(t, p6, .POW)
	if pow != nil {
		_, is_unary := pow.lhs.(^main.SVUnary)
		testing.expect(t, is_unary, "unary minus binds tighter than **")
	}

	p7, _ := sv_assign_rhs(t, module, "p7")
	ternary := sv_ternary(t, p7)
	if ternary != nil {
		nested, is_ternary := ternary.rhs.(^main.SVTernary)
		testing.expect(t, is_ternary, "ternary should be right associative")
		_ = nested
	}

	cast0, _ := sv_assign_rhs(t, module, "cast0")
	cast_node, is_cast := cast0.(^main.SVCast)
	testing.expect(t, is_cast, "expected a cast")
	if is_cast {
		testing.expect_value(t, cast_node.kind, main.SVCastKind.SIGNING)
		testing.expect_value(t, cast_node.target, "signed")
	}

	cast1, _ := sv_assign_rhs(t, module, "cast1")
	size_cast, is_size := cast1.(^main.SVCast)
	testing.expect(t, is_size, "expected a size cast")
	if is_size {
		testing.expect_value(t, size_cast.kind, main.SVCastKind.SIZE)
	}

	cast4, _ := sv_assign_rhs(t, module, "cast4")
	scoped_cast, is_scoped := cast4.(^main.SVCast)
	testing.expect(t, is_scoped, "expected a scoped type cast")
	if is_scoped {
		testing.expect_value(t, scoped_cast.target, "pkg::t")
	}

	cast5, _ := sv_assign_rhs(t, module, "cast5")
	call_cast, is_call_cast := cast5.(^main.SVCast)
	testing.expect(t, is_call_cast, "expected a constant call cast")
	if is_call_cast {
		_, size_is_call := call_cast.size^.(^main.SVCall)
		testing.expect(t, size_is_call, "size cast target should be the $clog2 call")
	}

	sys0, _ := sv_assign_rhs(t, module, "sys0")
	sys_call, is_sys := sys0.(^main.SVCall)
	testing.expect(t, is_sys && sys_call.is_system && sys_call.name == "$unsigned", "system call missing")

	scoped_expr, _ := sv_assign_rhs(t, module, "scoped")
	scoped_name, is_name := scoped_expr.(^main.SVScopedName)
	testing.expect(t, is_name, "expected a scoped name")
	if is_name {
		testing.expect_value(t, scoped_name.scope, "pkg")
		testing.expect_value(t, scoped_name.name, "CONST")
	}

	call_expr, _ := sv_assign_rhs(t, module, "call")
	call, is_call := call_expr.(^main.SVCall)
	testing.expect(t, is_call, "expected a scoped function call")
	if is_call {
		testing.expect_value(t, call.name, "pkg::func")
		testing.expect_value(t, len(call.args), 2)
		testing.expect_value(t, call.args[1].name, "x")
	}

	inc0, _ := sv_assign_rhs(t, module, "inc0")
	post_inc, is_post := inc0.(^main.SVIncDec)
	testing.expect(t, is_post && !post_inc.is_prefix && !post_inc.is_dec, "postfix ++ missing")

	inc1, _ := sv_assign_rhs(t, module, "inc1")
	pre_inc, is_pre := inc1.(^main.SVIncDec)
	testing.expect(t, is_pre && pre_inc.is_prefix, "prefix ++ missing")
}

// ---------------------------------------------------------------------------------------
// Selects, concatenation, replication, streaming, inside, assignment patterns
// ---------------------------------------------------------------------------------------

@(test)
test_sv_selects_concat_patterns :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module shapes;",
		"  logic [7:0] a, b;",
		"  logic [7:0] mem [0:3];",
		"  int i;",
		"  assign s_bit   = a[3];",
		"  assign s_part  = a[7:4];",
		"  assign s_plus  = a[i +: 4];",
		"  assign s_minus = a[i -: 2];",
		"  assign s_chain = mem[a][i];",
		"  assign c_plain = {a, b, 2'b01};",
		"  assign c_rep   = {2{a, b}};",
		"  assign c_left  = {<<{a}};",
		"  assign c_right = {>> 4 {a, b}};",
		"  assign in_expr = a inside {1, [4:8], [9:$]};",
		"  assign ap_pos  = '{1, 2, 3};",
		"  assign ap_key  = '{default: 0, foo: 1, \"bar\": 2};",
		"  assign ap_rep  = '{2{1'b1}};",
		"  assign ap_typed = my_t'{a: 1, b: 2};",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	bit, _ := sv_assign_rhs(t, module, "s_bit")
	bit_sel := sv_select(t, bit)
	if bit_sel != nil {
		testing.expect_value(t, len(bit_sel.parts), 1)
		testing.expect_value(t, bit_sel.parts[0].kind, main.SVSelectKind.BIT)
	}

	part, _ := sv_assign_rhs(t, module, "s_part")
	part_sel := sv_select(t, part)
	if part_sel != nil {
		testing.expect_value(t, part_sel.parts[0].kind, main.SVSelectKind.PART)
		testing.expect_value(t, part_sel.parts[0].has_second, true)
	}

	plus, _ := sv_assign_rhs(t, module, "s_plus")
	plus_sel := sv_select(t, plus)
	if plus_sel != nil {
		testing.expect_value(t, plus_sel.parts[0].kind, main.SVSelectKind.INDEXED_PLUS)
	}

	minus, _ := sv_assign_rhs(t, module, "s_minus")
	minus_sel := sv_select(t, minus)
	if minus_sel != nil {
		testing.expect_value(t, minus_sel.parts[0].kind, main.SVSelectKind.INDEXED_MINUS)
	}

	chain, _ := sv_assign_rhs(t, module, "s_chain")
	chain_sel := sv_select(t, chain)
	if chain_sel != nil {
		testing.expect_value(t, len(chain_sel.parts), 2)
	}

	plain, _ := sv_assign_rhs(t, module, "c_plain")
	concat, ok := plain.(^main.SVConcat)
	testing.expect(t, ok, "expected concatenation")
	if ok {
		testing.expect_value(t, len(concat.parts), 3)
		testing.expect(t, concat.count == nil, "plain concat must not have a count")
	}

	rep, _ := sv_assign_rhs(t, module, "c_rep")
	replicated, is_rep := rep.(^main.SVConcat)
	testing.expect(t, is_rep, "expected replication")
	if is_rep {
		testing.expect(t, replicated.count != nil, "replication count missing")
		testing.expect_value(t, len(replicated.parts), 2)
	}

	left, _ := sv_assign_rhs(t, module, "c_left")
	stream_left, is_stream := left.(^main.SVStream)
	testing.expect(t, is_stream, "expected streaming concatenation")
	if is_stream {
		testing.expect_value(t, stream_left.dir, main.SVStreamDir.LEFT)
	}

	right, _ := sv_assign_rhs(t, module, "c_right")
	stream_right, is_stream_right := right.(^main.SVStream)
	testing.expect(t, is_stream_right, "expected streaming concatenation")
	if is_stream_right {
		testing.expect_value(t, stream_right.dir, main.SVStreamDir.RIGHT)
		testing.expect(t, stream_right.slice != nil, "stream slice size missing")
	}

	inside_expr, _ := sv_assign_rhs(t, module, "in_expr")
	inside, is_inside := inside_expr.(^main.SVInside)
	testing.expect(t, is_inside, "expected inside expression")
	if is_inside {
		testing.expect_value(t, len(inside.ranges), 3)
		testing.expect_value(t, inside.ranges[1].has_hi, true)
	}

	ap_pos, _ := sv_assign_rhs(t, module, "ap_pos")
	pos_pattern, is_pattern := ap_pos.(^main.SVAggregate)
	testing.expect(t, is_pattern, "expected assignment pattern")
	if is_pattern {
		testing.expect_value(t, len(pos_pattern.entries), 3)
	}

	ap_key, _ := sv_assign_rhs(t, module, "ap_key")
	key_pattern, is_key_pattern := ap_key.(^main.SVAggregate)
	testing.expect(t, is_key_pattern, "expected keyed assignment pattern")
	if is_key_pattern {
		testing.expect_value(t, len(key_pattern.entries), 3)
		testing.expect_value(t, key_pattern.entries[0].key, "default")
		testing.expect_value(t, key_pattern.entries[1].key, "foo")
		testing.expect_value(t, key_pattern.entries[2].key, "bar")
	}

	ap_rep, _ := sv_assign_rhs(t, module, "ap_rep")
	rep_pattern, is_rep_pattern := ap_rep.(^main.SVAggregate)
	testing.expect(t, is_rep_pattern, "expected replicated assignment pattern")
	if is_rep_pattern {
		testing.expect(t, rep_pattern.count != nil, "pattern replication count missing")
	}

	ap_typed, _ := sv_assign_rhs(t, module, "ap_typed")
	typed_pattern, is_typed_pattern := ap_typed.(^main.SVAggregate)
	testing.expect(t, is_typed_pattern, "expected typed assignment pattern")
	if is_typed_pattern {
		testing.expect_value(t, typed_pattern.type_name, "my_t")
	}
}

// ---------------------------------------------------------------------------------------
// Instantiations: parameter overrides, port connections, gate primitives
// ---------------------------------------------------------------------------------------

@(test)
test_sv_instances :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module top;",
		"  logic [7:0] a, b, y;",
		"  sub #(.W(8), .MODE(2), .T(logic [7:0])) u0 (",
		"    .a(a[7:0]),",
		"    .b(),",
		"    .y(y)",
		"  );",
		"  sub #(8, logic [3:0]) u1 (a, b, y);",
		"  sub u2 [3:0] (.a(a));",
		"  sub u3 (.x(a)), u4 (.y(b));",
		"  sub u5 (.*);",
		"  sub u6 (.*, .y(b), .a(a[3:0]));",
		"  and #5 g0 (y[0], a[0], b[0]);",
		"  buf (strong0, strong1) g1 (y[1], a[1]);",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	instances := make([dynamic]^main.SVInstance, context.temp_allocator)
	for item in module.items {
		#partial switch v in item {
		case ^main.SVInstance: append(&instances, v)
		}
	}
	testing.expect_value(t, len(instances), 9)

	u0 := instances[0]
	testing.expect_value(t, u0.cell_name, "sub")
	testing.expect_value(t, u0.name, "u0")
	testing.expect_value(t, u0.is_gate, false)
	testing.expect_value(t, len(u0.param_overrides), 3)
	testing.expect_value(t, u0.param_overrides[0].name, "W")
	testing.expect(t, u0.param_overrides[0].type_value == nil, "W is a value parameter")
	testing.expect(t, u0.param_overrides[2].type_value != nil, "T should be a type argument")
	testing.expect_value(t, len(u0.port_conns), 3)
	testing.expect_value(t, u0.port_conns[0].name, "a")
	testing.expect(t, u0.port_conns[0].value != nil, "port value missing")
	testing.expect_value(t, u0.port_conns[1].name, "b")
	testing.expect(t, u0.port_conns[1].value == nil, "empty connection should have no value")

	u1 := instances[1]
	testing.expect_value(t, len(u1.param_overrides), 2)
	testing.expect_value(t, u1.param_overrides[0].name, "") // ordered
	testing.expect(t, u1.param_overrides[1].type_value != nil, "ordered type argument missing")
	testing.expect_value(t, len(u1.port_conns), 3)
	testing.expect_value(t, u1.port_conns[0].name, "") // ordered

	u2 := instances[2]
	testing.expect_value(t, len(u2.unpacked_dims), 1)

	u3 := instances[3]
	u4 := instances[4]
	testing.expect_value(t, u4.name, "u4")
	testing.expect_value(t, len(u4.port_conns), 1)

	u5 := instances[5]
	testing.expect_value(t, u5.wildcard_ports, true)
	testing.expect_value(t, len(u5.port_conns), 0)

	u6 := instances[6]
	testing.expect_value(t, u6.wildcard_ports, true)
	testing.expect_value(t, len(u6.port_conns), 2)
	testing.expect_value(t, u6.port_conns[0].name, "y")

	g0 := instances[7]
	testing.expect_value(t, g0.is_gate, true)
	testing.expect_value(t, g0.name, "g0")

	g1 := instances[8]
	testing.expect_value(t, g1.is_gate, true)
}

// ---------------------------------------------------------------------------------------
// Generate constructs: region, for, if/else, case, implicit generate
// ---------------------------------------------------------------------------------------

@(test)
test_sv_generate :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module gen #(parameter N = 4);",
		"  genvar i;",
		"  generate",
		"    for (i = 0; i < N; i = i + 1) begin : outer",
		"      if (i % 2 == 0) begin : even",
		"        wire w_even;",
		"        begin : inner wire w_inner; end",
		"      end else begin : odd",
		"        wire w_odd;",
		"      end",
		"    end",
		"    case (N)",
		"      2, 4: begin : c_even wire c0; end",
		"      default: begin : c_default wire c1; end",
		"    endcase",
		"  endgenerate",
		"  for (genvar j = 0; j < 2; j++) begin : implicit_loop wire z; end",
		"  if (N > 2) begin : top_if wire q; end else begin : top_else wire q2; end",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	#partial switch region_item in module.items[1] { // module.items[0] is `genvar i`
	case ^main.SVGenRegion:
		testing.expect_value(t, len(region_item.items), 2)

		#partial switch loop_item in region_item.items[0] {
		case ^main.SVGenLoop:
			testing.expect_value(t, loop_item.var, "i")
			testing.expect(t, loop_item.body != nil, "generate loop body missing")
			if loop_item.body != nil {
				testing.expect_value(t, loop_item.body.label, "outer")
				testing.expect_value(t, len(loop_item.body.items), 1)
				#partial switch if_item in loop_item.body.items[0] {
				case ^main.SVGenIf:
					testing.expect(t, if_item.then_blk != nil && if_item.then_blk.label == "even", "then label")
					testing.expect(t, if_item.else_blk != nil && if_item.else_blk.label == "odd", "else label")
					if if_item.then_blk != nil && len(if_item.then_blk.items) == 2 {
						#partial switch inner_item in if_item.then_blk.items[1] {
						case ^main.SVGenRegion:
							testing.expect_value(t, inner_item.label, "inner")
						}
					} else {
						testing.expectf(t, false, "expected a nested begin block inside the generate if")
					}
				}
			}
		}

		#partial switch case_item in region_item.items[1] {
		case ^main.SVGenCase:
			testing.expect_value(t, len(case_item.items), 2)
			testing.expect_value(t, len(case_item.items[0].exprs), 2)
			testing.expect_value(t, case_item.items[1].is_default, true)
			testing.expect(t, case_item.items[0].body != nil && case_item.items[0].body.label == "c_even", "case block label")
		}
	case:
		testing.expectf(t, false, "expected a generate region, got %v", region_item)
	}

	#partial switch implicit_item in module.items[2] {
	case ^main.SVGenLoop:
		testing.expect_value(t, implicit_item.var, "j")
		testing.expect(t, implicit_item.body != nil && implicit_item.body.label == "implicit_loop", "implicit loop label")
	case:
		testing.expectf(t, false, "expected an implicit generate loop, got %v", implicit_item)
	}

	#partial switch top_if_item in module.items[3] {
	case ^main.SVGenIf:
		testing.expect(t, top_if_item.then_blk != nil && top_if_item.then_blk.label == "top_if", "top if label")
		testing.expect(t, top_if_item.else_blk != nil && top_if_item.else_blk.label == "top_else", "top else label")
	case:
		testing.expectf(t, false, "expected a top-level generate if, got %v", top_if_item)
	}
}

// ---------------------------------------------------------------------------------------
// Procedural code: processes, timing controls, statements, loops, assertions
// ---------------------------------------------------------------------------------------

@(test)
test_sv_procedural :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module proc;",
		"  logic clk, rst_n, en;",
		"  logic [7:0] a, b, y;",
		"  logic [1:0] sel;",
		"  logic [7:0] mem [0:3];",
		"  int i, j;",
		"  always_ff @(posedge clk or negedge rst_n) begin : seq",
		"    if (!rst_n) y <= '0;",
		"    else if (en) y <= a + b;",
		"    else y <= y;",
		"  end",
		"  always_comb begin",
		"    unique case (sel)",
		"      2'd0: y = a;",
		"      2'd1, 2'd2: y = b;",
		"      default: y = 8'h0;",
		"    endcase",
		"  end",
		"  always @(*) begin",
		"    priority casez (a[1:0])",
		"      2'b0?: y = 1;",
		"      2'b10: y = 2;",
		"      default y = 0;",
		"    endcase",
		"  end",
		"  always @ (posedge clk) begin",
		"    case (sel) inside",
		"      [0:1]: y = 1;",
		"      default: y = 0;",
		"    endcase",
		"    for (int k = 0, m = 1; k < 4; k++, m = m + 1) begin",
		"      if (k == 2) continue;",
		"      if (k == 3) break;",
		"      y = k;",
		"    end",
		"    while (i > 0) i = i - 1;",
		"    do i = i + 1; while (i < 4);",
		"    repeat (2) i++;",
		"    foreach (mem[idx]) i = idx;",
		"    #5 i = 0;",
		"    @(posedge clk) i = 1;",
		"    i += 2;",
		"    i <<= 1;",
		"    \\if = i;",
		"    void'(f(i));",
		"    assert (i >= 0) else $error(\"neg\");",
		"    assume (i < 8);",
		"    cover (i == 0);",
		"  end",
		"  initial begin : init_block",
		"    import pkg::*;",
		"    automatic logic [11:0] addr;",
		"    forever i = 0;",
		"    empty_statement;",
		"    pkg::do_thing;",
		"    pkg::check(i);",
		"    dummy.push_back(i);",
		"    i = dummy.pop_front();",
		"  end",
		"  final $display(\"done\");",
		"  always_latch if (en) y <= a;",
		"  always @* y = a;",
		"  always @(posedge clk iff en) y = a;",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	seq := sv_proc(t, module, .ALWAYS_FF)
	testing.expect(t, seq != nil, "always_ff missing")
	if seq != nil {
		testing.expect_value(t, len(seq.events), 2)
		testing.expect_value(t, seq.events[0].edge, main.SVEdgeKind.POSEDGE)
		testing.expect_value(t, seq.events[1].edge, main.SVEdgeKind.NEGEDGE)
		block := sv_block(t, seq.body)
		if block != nil {
			testing.expect_value(t, block.label, "seq")
			testing.expect_value(t, len(block.stmts), 1)
			if_stmt, is_if := block.stmts[0].(^main.SVIf)
			testing.expect(t, is_if, "expected if statement")
			if is_if {
				testing.expect(t, if_stmt.then_body != nil, "if then body")
				testing.expect(t, if_stmt.else_body != nil, "if else body")
				else_if, else_is_if := if_stmt.else_body^.(^main.SVIf)
				testing.expect(t, else_is_if, "expected else-if")
				if else_is_if {
					assign, is_assign := else_if.then_body^.(^main.SVAssignStmt)
					testing.expect(t, is_assign && assign.nonblocking, "nonblocking assignment missing")
				}
			}
		}
	}

	comb := sv_proc(t, module, .ALWAYS_COMB)
	testing.expect(t, comb != nil, "always_comb missing")
	if comb != nil {
		block := sv_block(t, comb.body)
		if block != nil {
			case_stmt, is_case := block.stmts[0].(^main.SVCase)
			testing.expect(t, is_case, "expected case statement")
			if is_case {
				testing.expect_value(t, case_stmt.kind, main.SVCaseKind.CASE)
				testing.expect_value(t, case_stmt.qualifier, main.SVQualifier.UNIQUE)
				testing.expect_value(t, len(case_stmt.items), 3)
				testing.expect_value(t, len(case_stmt.items[1].exprs), 2)
				testing.expect_value(t, case_stmt.items[2].is_default, true)
			}
		}
	}

	always := sv_proc(t, module, .ALWAYS)
	testing.expect(t, always != nil, "always missing")
	if always != nil {
		testing.expect(t, always.any_event || (len(always.events) > 0 && always.events[0].edge == main.SVEdgeKind.POSEDGE), "always sensitivity")
	}

	// find the second `always` (the one with @(*), then casez, then the big block)
	found_casez := false
	found_inside_case := false
	found_for := false
	found_while := false
	found_do_while := false
	found_repeat := false
	found_foreach := false
	found_delay_stmt := false
	found_event_stmt := false
	found_compound_add := false
	found_compound_shl := false
	found_void_call := false
	found_assert := false
	found_assume := false
	found_cover := false
	found_break := false
	found_continue := false

	for item in module.items {
		proc_node, is_proc := item.(^main.SVProc)
		if !is_proc || proc_node.kind != .ALWAYS { continue }
		block, is_block := proc_node.body.(^main.SVBlock)
		if !is_block { continue }
		for stmt in block.stmts {
			#partial switch s in stmt {
			case ^main.SVCase:
				if s.kind == .CASEZ {
					found_casez = true
					testing.expect_value(t, s.qualifier, main.SVQualifier.PRIORITY)
				}
				if s.is_inside {
					found_inside_case = true
					testing.expect_value(t, len(s.items[0].ranges), 1)
				}
			case ^main.SVFor:
				found_for = true
				testing.expect_value(t, len(s.var_decls), 1)
				testing.expect_value(t, len(s.steps), 2)
				if s.body != nil {
					#partial switch body_block in s.body^ {
					case ^main.SVBlock:
						for inner in body_block.stmts {
							#partial switch js in inner {
							case ^main.SVIf:
								if js.then_body != nil {
									#partial switch jump in js.then_body^ {
									case ^main.SVJump:
										if jump.kind == .CONTINUE { found_continue = true }
										if jump.kind == .BREAK { found_break = true }
									}
								}
							}
						}
					}
				}
			case ^main.SVWhile:
				if s.do_while { found_do_while = true } else { found_while = true }
			case ^main.SVRepeat:
				found_repeat = true
			case ^main.SVForeach:
				found_foreach = true
				testing.expect_value(t, len(s.loop_vars), 1)
				testing.expect_value(t, s.loop_vars[0], "idx")
			case ^main.SVTimingStmt:
				if s.timing.is_delay { found_delay_stmt = true } else { found_event_stmt = true }
			case ^main.SVAssignStmt:
				if s.op == .ADD_EQ { found_compound_add = true }
				if s.op == .SHL_EQ { found_compound_shl = true }
			case ^main.SVCall:
				testing.expect_value(t, s.name, "f")
				found_void_call = true
			case ^main.SVAssert:
				if s.kind == .ASSERT { found_assert = true }
				if s.kind == .ASSUME { found_assume = true }
				if s.kind == .COVER { found_cover = true }
			case ^main.SVIf:
				if s.then_body != nil {
					#partial switch js in s.then_body^ {
					case ^main.SVJump:
						if js.kind == .CONTINUE { found_continue = true }
						if js.kind == .BREAK { found_break = true }
					}
				}
			}
		}
	}

	testing.expect(t, found_casez, "casez statement missing")
	testing.expect(t, found_inside_case, "case inside statement missing")
	testing.expect(t, found_for, "for loop missing")
	testing.expect(t, found_while, "while loop missing")
	testing.expect(t, found_do_while, "do-while loop missing")
	testing.expect(t, found_repeat, "repeat loop missing")
	testing.expect(t, found_foreach, "foreach loop missing")
	testing.expect(t, found_delay_stmt, "#delay statement missing")
	testing.expect(t, found_event_stmt, "@event statement missing")
	testing.expect(t, found_compound_add, "+= assignment missing")
	testing.expect(t, found_compound_shl, "<<= assignment missing")
	testing.expect(t, found_void_call, "void'(call) missing")
	testing.expect(t, found_assert, "assert statement missing")
	testing.expect(t, found_assume, "assume statement missing")
	testing.expect(t, found_cover, "cover statement missing")
	testing.expect(t, found_break, "break statement missing")
	testing.expect(t, found_continue, "continue statement missing")

	initial := sv_proc(t, module, .INITIAL)
	testing.expect(t, initial != nil, "initial missing")
	if initial != nil {
		block := sv_block(t, initial.body)
		if block != nil {
			testing.expect_value(t, block.label, "init_block")
			testing.expect_value(t, len(block.imports), 1)
			testing.expect_value(t, block.imports[0].package_name, "pkg")
			testing.expect_value(t, len(block.decls), 1)
			testing.expect_value(t, len(block.stmts), 6)
			_, is_forever := block.stmts[0].(^main.SVForever)
			testing.expect(t, is_forever, "forever statement missing")
			bare_call, is_bare_call := block.stmts[1].(^main.SVCall)
			testing.expect(t, is_bare_call && bare_call.name == "empty_statement", "parenthesis-less task call missing")
			scoped_call, is_scoped_call := block.stmts[2].(^main.SVCall)
			testing.expect(t, is_scoped_call && scoped_call.name == "pkg::do_thing", "scoped task call missing")
			scoped_arg_call, is_scoped_arg_call := block.stmts[3].(^main.SVCall)
			testing.expect(t, is_scoped_arg_call && scoped_arg_call.name == "pkg::check", "scoped call with arguments missing")
			method_call, is_method_call := block.stmts[4].(^main.SVCall)
			testing.expect(t, is_method_call && method_call.name == "dummy.push_back", "method call missing")
			method_assign, is_method_assign := block.stmts[5].(^main.SVAssignStmt)
			testing.expect(t, is_method_assign, "method call assignment missing")
			if is_method_assign {
				pop_call, is_pop := method_assign.rhs.(^main.SVCall)
				testing.expect(t, is_pop && pop_call.name == "dummy.pop_front", "method call on assignment RHS missing")
			}
		}
	}

	final := sv_proc(t, module, .FINAL)
	testing.expect(t, final != nil, "final block missing")

	latch := sv_proc(t, module, .ALWAYS_LATCH)
	testing.expect(t, latch != nil, "always_latch missing")

	// the bare `always @*` process and the event `iff` guard
	found_any_event := false
	found_event_iff := false
	for item in module.items {
		proc_node, is_proc := item.(^main.SVProc)
		if !is_proc || proc_node.kind != .ALWAYS { continue }
		if proc_node.any_event { found_any_event = true }
		for event in proc_node.events {
			if event.iff != nil { found_event_iff = true }
		}
	}
	testing.expect(t, found_any_event, "always @* missing")
	testing.expect(t, found_event_iff, "event iff guard missing")
}

// ---------------------------------------------------------------------------------------
// Subroutines and packages
// ---------------------------------------------------------------------------------------

@(test)
test_sv_subroutines_and_packages :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"import pkg0::*;",
		"typedef logic [3:0] top_t;",
		"parameter int TOPP = 3;",
		"function integer top_f(input integer v);",
		"  top_f = v;",
		"endfunction",
		"package pkg0;",
		"  localparam int P = 4;",
		"  typedef enum { E0, E1 } e_t;",
		"  import pkg1::*;",
		"  function automatic int f(input int x);",
		"    f = x + 1;",
		"    return f;",
		"  endfunction",
		"  task automatic t(input int x);",
		"    int y;",
		"    y = x;",
		"  endtask",
		"endpackage",
		"module subs;",
		"  function automatic [7:0] add_one(input [7:0] x, input logic en = 1'b1);",
		"    typedef logic [7:0] local_t;",
		"    local_t tmp;",
		"    tmp = x + 8'd1;",
		"    add_one = tmp;",
		"  endfunction",
		"  function void no_value(input int x);",
		"  endfunction",
		"  function integer legacy;",
		"    input integer v;",
		"    begin",
		"      legacy = v;",
		"    end",
		"  endfunction",
		"  task automatic clear(input int n);",
		"    import pkg1::*;",
		"    for (int k = 0; k < n; k++) begin",
		"    end",
		"  endtask",
		"endmodule",
	)
	sv_test_parse(&ctx, source)

	testing.expect_value(t, len(ctx.ast.imports), 1)
	testing.expect_value(t, ctx.ast.imports[0].package_name, "pkg0")
	testing.expect_value(t, ctx.ast.imports[0].name, "*")
	testing.expect_value(t, len(ctx.ast.packages), 1)
	testing.expect_value(t, len(ctx.ast.items), 3) // top_t, TOPP, top_f

	pkg := ctx.ast.package_hash_map["pkg0"]
	testing.expect(t, pkg != nil, "package not found")
	if pkg != nil {
		testing.expect_value(t, len(pkg.imports), 1)
		testing.expect_value(t, pkg.imports[0].package_name, "pkg1")
		testing.expect_value(t, len(pkg.items), 4) // param, typedef, function, task
	}

	subs := sv_module(t, &ctx, "subs")
	subs_functions := make([dynamic]^main.SVSubroutine, context.temp_allocator)
	for item in subs.items {
		#partial switch v in item {
		case ^main.SVSubroutine: append(&subs_functions, v)
		}
	}
	testing.expect_value(t, len(subs_functions), 4)

	add_one := subs_functions[0]
	testing.expect_value(t, add_one.name, "add_one")
	testing.expect_value(t, add_one.is_automatic, true)
	testing.expect_value(t, len(add_one.ports), 2)
	testing.expect(t, add_one.ports[1].default_value != nil, "tf port default missing")
	testing.expect_value(t, len(add_one.body.decls), 2) // local typedef + variable

	no_value := subs_functions[1]
	testing.expect_value(t, no_value.return_data.var_type, main.SVVarType.VOID)

	legacy := subs_functions[2]
	testing.expect_value(t, legacy.is_automatic, false)
	testing.expect_value(t, len(legacy.ports), 1) // legacy tf port declaration

	clear := subs_functions[3]
	testing.expect_value(t, clear.is_task, true)
	testing.expect_value(t, len(clear.body.stmts), 1) // for loop
	testing.expect_value(t, len(clear.body.imports), 1)
	testing.expect_value(t, clear.body.imports[0].package_name, "pkg1")
}

// ---------------------------------------------------------------------------------------
// Interfaces, modports and interface ports
// ---------------------------------------------------------------------------------------

@(test)
test_sv_interfaces :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"package types_pkg;",
		"  typedef logic [7:0] data_t;",
		"endpackage",
		"interface bus_if import types_pkg::*; #(parameter W = 8) (input logic clk);",
		"  logic [W-1:0] data;",
		"  logic valid;",
		"  modport master (output data, output valid, input clk);",
		"  modport slave (input data, input valid, input clk);",
		"  clocking cb @(posedge clk);",
		"  endclocking",
		"endinterface",
		"module uses (bus_if.master m, bus_if.slave s);",
		"  bus_if #(.W(8)) u_if ();",
		"  bus_if u_plain ();",
		"endmodule",
		"module generic_if (interface d);",
		"endmodule",
	)
	sv_test_parse(&ctx, source)

	iface := ctx.ast.interface_hash_map["bus_if"]
	testing.expect(t, iface != nil, "interface not found")
	if iface != nil {
		testing.expect_value(t, iface.name, "bus_if")
		testing.expect_value(t, len(iface.params), 1)
		testing.expect_value(t, len(iface.ports), 1)
		testing.expect_value(t, len(iface.imports), 1)
		testing.expect_value(t, len(iface.modports), 2)
		testing.expect_value(t, iface.modports[0].name, "master")
		testing.expect_value(t, len(iface.modports[0].ports), 3)
		testing.expect_value(t, iface.modports[0].ports[0].dir, main.SVPortDir.OUTPUT)
	}

	uses := sv_module(t, &ctx, "uses")
	testing.expect_value(t, len(uses.ports), 2)
	master := sv_find_port(t, uses, "m")
	testing.expect_value(t, master.iface_name, "bus_if")
	testing.expect_value(t, master.modport, "master")

	instances := make([dynamic]^main.SVInstance, context.temp_allocator)
	for item in uses.items {
		#partial switch v in item {
		case ^main.SVInstance: append(&instances, v)
		}
	}
	testing.expect_value(t, len(instances), 2)
	testing.expect_value(t, instances[0].cell_name, "bus_if")
	testing.expect_value(t, instances[1].cell_name, "bus_if")

	generic := sv_module(t, &ctx, "generic_if")
	testing.expect_value(t, len(generic.ports), 1)
	testing.expect_value(t, generic.ports[0].iface_name, "interface")
	testing.expect_value(t, generic.ports[0].name, "d")
}

// ---------------------------------------------------------------------------------------
// Macros and compiler directives
// ---------------------------------------------------------------------------------------

@(test)
test_sv_macros_and_directives :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	ctx.ast.defines["FEATURE"] = main.SVDefine{}

	source := sv_src(
		"`define WIDTH 8",
		"`define MAX(a, b) ((a) > (b) ? (a) : (b))",
		"`define GREET(name) `\"hello name`\"",
		"`define JOIN(a, b) a``b",
		"`define LINE_NO `__LINE__",
		"`define FILE_NO `__FILE__",
		"`define WITH_DEFAULT(a, b = 4) ((a) + (b))",
		"`define MULTI(a) \\",
		"  ((a) + \\",
		"   1)",
		"`define CL(a) ((a) + // continued comment \\",
		"   1)",
		"`define CB(a) ((a) /* block comment */ + 1)",
		"`define CS \"a // b\"",
		"`ifdef FEATURE",
		"  `define MODE 2",
		"`elsif OTHER",
		"  `define MODE 3",
		"`else",
		"  `define MODE 4",
		"`endif",
		"`ifndef NOT_DEFINED",
		"  `define GUARDED 1",
		"`endif",
		"`define SCRATCH 1",
		"`undef SCRATCH",
		"`ifdef SCRATCH",
		"  `define REMOVED 1",
		"`endif",
		"module macros;",
		"  localparam W = `WIDTH;",
		"  localparam M = `MAX(W, 4);",
		"  localparam S = `GREET(world);",
		"  localparam J = `JOIN(foo, bar);",
		"  localparam L = `LINE_NO;",
		"  localparam F = `FILE_NO;",
		"  localparam MODE = `MODE;",
		"  localparam M2 = `MULTI(3);",
		"  localparam M3 = `CL(2);",
		"  localparam M4 = `CB(2);",
		"  localparam M5 = `CS;",
		"  localparam D = `WITH_DEFAULT(1);",
		"  wire `JOIN(com, bined);",
		"endmodule",
		"`undefineall",
	)
	module := sv_single_module(t, &ctx, source)

	w := sv_param_expr(t, module, "W")
	testing.expect_value(t, sv_number(t, w^).value, u64(8))

	m := sv_param_expr(t, module, "M")
	sv_ternary(t, m^) // `MAX expands to a ternary

	s := sv_param_expr(t, module, "S")
	greeting, is_string := s^.(main.SVStringLit)
	testing.expect(t, is_string, "expected an expanded string literal")
	if is_string {
		testing.expect_value(t, string(greeting), "hello world")
	}

	j := sv_param_expr(t, module, "J")
	joined, is_ident := j^.(string)
	testing.expect(t, is_ident && joined == "foobar", "token pasting failed")

	line := sv_param_expr(t, module, "L")
	testing.expect(t, sv_number(t, line^).value > 0, "`__LINE__ should be numeric")

	file := sv_param_expr(t, module, "F")
	_, file_is_string := file^.(main.SVStringLit)
	testing.expect(t, file_is_string, "`__FILE__ should be a string literal")

	mode := sv_param_expr(t, module, "MODE")
	testing.expect_value(t, sv_number(t, mode^).value, u64(2))

	multi := sv_param_expr(t, module, "M2")
	sv_binary(t, multi^, .ADD) // continuation lines joined

	comment_line := sv_param_expr(t, module, "M3")
	sv_binary(t, comment_line^, .ADD) // `//` comment + continuation

	comment_block := sv_param_expr(t, module, "M4")
	sv_binary(t, comment_block^, .ADD) // block comment removed

	comment_string := sv_param_expr(t, module, "M5")
	if comment_string != nil {
		text, is_text := comment_string^.(main.SVStringLit)
		testing.expect(t, is_text && strings.contains(string(text), "//"), "comment markers inside strings must be preserved")
	}

	def := sv_param_expr(t, module, "D")
	sv_binary(t, def^, .ADD) // macro parameter default

	_, removed_defined := ctx.ast.defines["REMOVED"]
	testing.expect(t, !removed_defined, "`undef must remove the macro")

	wire_found := false
	for item in module.items {
		#partial switch v in item {
		case ^main.SVNetDecl:
			for declarator in v.declarators {
				if declarator.name == "combined" { wire_found = true }
			}
		}
	}
	testing.expect(t, wire_found, "token-pasted wire name not found")
	testing.expect_value(t, len(ctx.ast.defines), 0) // `undefineall
}

// ---------------------------------------------------------------------------------------
// `include resolution: relative paths, include directories, macro paths, body includes
// ---------------------------------------------------------------------------------------

@(test)
test_sv_include_resolution :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	tmp_root := "tests/sv_parser_tmp"
	_ = os.remove_all(tmp_root)
	ensure(os.make_directory_all(tmp_root) == nil)
	ensure(os.make_directory_all(fmt.tprintf("%s/sub", tmp_root)) == nil)
	ensure(os.make_directory_all(fmt.tprintf("%s/include_dir", tmp_root)) == nil)
	defer os.remove_all(tmp_root)

	main_path := fmt.tprintf("%s/main.sv", tmp_root)
	ensure(os.write_entire_file(main_path, sv_src(
		"`include \"defs.svh\"",
		"module included;",
		"`include \"items.svh\"",
		"endmodule",
	)) == nil)
	ensure(os.write_entire_file(fmt.tprintf("%s/defs.svh", tmp_root), sv_src(
		"`define CONFIG_FILE \"sub/extra.svh\"",
		"`include `CONFIG_FILE",
		"`include \"header.svh\"",
	)) == nil)
	ensure(os.write_entire_file(fmt.tprintf("%s/items.svh", tmp_root), sv_src(
		"wire from_include;",
	)) == nil)
	ensure(os.write_entire_file(fmt.tprintf("%s/sub/extra.svh", tmp_root), sv_src(
		"`define EXTRA_SEEN 1",
	)) == nil)
	ensure(os.write_entire_file(fmt.tprintf("%s/include_dir/header.svh", tmp_root), sv_src(
		"`define HEADER_SEEN 1",
	)) == nil)

	append(&ctx.ast.include_dirs, fmt.tprintf("%s/include_dir", tmp_root))
	main.system_verilog_parse_to_ast(main_path, &ctx.ast, ctx.alloc)

	module := sv_module(t, &ctx, "included")
	testing.expect(t, module != nil, "module from included file missing")

	found_wire := false
	for item in module.items {
		#partial switch v in item {
		case ^main.SVNetDecl:
			for declarator in v.declarators {
				if declarator.name == "from_include" { found_wire = true }
			}
		}
	}
	testing.expect(t, found_wire, "`include inside a module body failed")
	_, extra_seen := ctx.ast.defines["EXTRA_SEEN"]
	testing.expect(t, extra_seen, "macro-provided `include path failed")

	_, header_seen := ctx.ast.defines["HEADER_SEEN"]
	testing.expect(t, header_seen, "include_dir search failed")
}

// ---------------------------------------------------------------------------------------
// Net aliasing, defparam, explicit port expressions, skipped verification constructs
// ---------------------------------------------------------------------------------------

@(test)
test_sv_alias_defparam_explicit_ports :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module alias_defparam (a, .P(r[3:0]), {x, y});",
		"  input [7:0] a;",
		"  logic [7:0] r;",
		"  wire x, y;",
		"  wire [7:0] b;",
		"  wire c;",
		"  wire #(1, 2) delayed_net;",
		"  assign #(1, 2, 3) c = a[0];",
		"  alias a = b;",
		"  alias {a[3:0], b[7:4]} = c;",
		"  defparam u.par = 1, u.p2 = 2;",
		"endmodule",
		"module ansi_explicit (output .P1(r[3:0]), input .P2(s));",
		"  logic [7:0] r;",
		"  logic s;",
		"endmodule",
		"class top_class;",
		"  int x;",
		"endclass",
		"module skips (input logic a);",
		"  class local_class;",
		"  endclass",
		"  restrict property (@(posedge a) a);",
		"endmodule",
		"package skip_pkg;",
		"  covergroup cg;",
		"  endgroup",
		"endpackage",
	)
	sv_test_parse(&ctx, source)

	module := sv_module(t, &ctx, "alias_defparam")
	testing.expect_value(t, len(module.ports), 3)
	p_port := module.ports[1]
	testing.expect_value(t, p_port.name, "P")
	testing.expect(t, p_port.expr != nil, "explicit port expression missing")
	testing.expect_value(t, module.ports[2].name, "")
	testing.expect(t, module.ports[2].expr != nil, "concatenated port expression missing")

	alias_count := 0
	defparam_count := 0
	for item in module.items {
		#partial switch v in item {
		case ^main.SVAlias:
			alias_count += 1
			testing.expect_value(t, len(v.names), 2)
		case ^main.SVDefparam:
			defparam_count += 1
			testing.expect_value(t, len(v.pairs), 2)
			lhs := sv_select(t, v.pairs[0].lhs)
			if lhs != nil {
				testing.expect_value(t, len(lhs.parts), 1)
				testing.expect_value(t, lhs.parts[0].member, "par")
			}
		}
	}
	testing.expect_value(t, alias_count, 2)
	testing.expect_value(t, defparam_count, 1)

	explicit := sv_module(t, &ctx, "ansi_explicit")
	testing.expect_value(t, len(explicit.ports), 2)
	p1 := sv_find_port(t, explicit, "P1")
	testing.expect_value(t, p1.dir, main.SVPortDir.OUTPUT)
	testing.expect(t, p1.expr != nil, "ANSI explicit port expression missing")
	p2 := sv_find_port(t, explicit, "P2")
	testing.expect_value(t, p2.dir, main.SVPortDir.INPUT)
	testing.expect(t, p2.expr != nil, "ANSI explicit input port expression missing")

	testing.expect(t, sv_module(t, &ctx, "skips") != nil, "module with skipped constructs missing")
	testing.expect(t, ctx.ast.package_hash_map["skip_pkg"] != nil, "package with covergroup missing")
}

// ---------------------------------------------------------------------------------------
// Assertions and elaboration system tasks
// ---------------------------------------------------------------------------------------

@(test)
test_sv_assertions_and_elab_tasks :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module asserts (input logic clk, input logic rst_n, input logic a, input logic b);",
		"  always_ff @(posedge clk) begin",
		"    assert (a || !a) else $error(\"impossible\");",
		"    assert final (b);",
		"    assert #0 (a);",
		"  end",
		"  initial begin",
		"    assert (rst_n);",
		"  end",
		"  ap_label: assert property (@(posedge clk) disable iff (!rst_n) (a |-> b)) else $fatal(1, \"bad\");",
		"  assume property (@(posedge clk) a);",
		"  cover property (@(posedge clk) a ##1 b);",
		"  default disable iff (!rst_n);",
		"  if (1) $fatal(0, \"elaboration error\");",
		"  $warning(\"warn\");",
		"  sequence seq0; a ##1 b; endsequence",
		"  property prop0; a |-> b; endproperty",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	assertions := make([dynamic]^main.SVAssert, context.temp_allocator)
	calls := make([dynamic]^main.SVCall, context.temp_allocator)
	for item in module.items {
		#partial switch v in item {
		case ^main.SVAssert: append(&assertions, v)
		case ^main.SVCall: append(&calls, v)
		}
	}
	testing.expect_value(t, len(assertions), 3)
	testing.expect(t, assertions[0].is_property, "first module assertion should be a property")
	testing.expect_value(t, assertions[0].kind, main.SVAssertKind.ASSERT)
	testing.expect(t, len(assertions[0].property_text) > 0, "property text missing")
	testing.expect(t, assertions[0].else_body != nil, "assertion else action missing")
	testing.expect_value(t, assertions[1].kind, main.SVAssertKind.ASSUME)
	testing.expect_value(t, assertions[2].kind, main.SVAssertKind.COVER)

	testing.expect_value(t, len(calls), 1)
	testing.expect_value(t, calls[0].name, "$warning")

	// `if (1) $fatal(...)` is a generate-if containing an elaboration task
	found_elab_if := false
	for item in module.items {
		#partial switch v in item {
		case ^main.SVGenIf:
			found_elab_if = true
			if v.then_blk != nil && len(v.then_blk.items) == 1 {
				#partial switch inner in v.then_blk.items[0] {
				case ^main.SVCall: testing.expect_value(t, inner.name, "$fatal")
				}
			}
		}
	}
	testing.expect(t, found_elab_if, "generate-if with $fatal missing")

	// immediate assertions inside the clocked block
	ff := sv_proc(t, module, .ALWAYS_FF)
	if ff != nil {
		block := sv_block(t, ff.body)
		if block != nil {
			testing.expect_value(t, len(block.stmts), 3)
			first, ok := block.stmts[0].(^main.SVAssert)
			testing.expect(t, ok && !first.is_property, "immediate assert missing")
			if ok {
				testing.expect(t, first.else_body != nil, "immediate assert else body missing")
			}
			two, ok2 := block.stmts[1].(^main.SVAssert)
			testing.expect(t, ok2 && !two.is_property, "assert final missing")
			three, ok3 := block.stmts[2].(^main.SVAssert)
			testing.expect(t, ok3 && !three.is_property, "deferred assert #0 missing")
		}
	}
}

// ---------------------------------------------------------------------------------------
// A combined "real RTL" smoke test that touches many constructs at once
// ---------------------------------------------------------------------------------------

@(test)
test_sv_full_subset_smoke :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"`timescale 1ns/1ps",
		"`define WIDTH 8",
		"package smoke_pkg;",
		"  typedef enum logic [1:0] { IDLE, BUSY = 2, DONE } state_t;",
		"  typedef struct packed { logic [7:0] data; logic valid; } beat_t;",
		"  localparam int DEPTH = 16;",
		"endpackage",
		"module smoke #(",
		"  parameter int WIDTH = 8,",
		"  parameter type t = logic [WIDTH-1:0],",
		") (",
		"  input  wire              clk,",
		"  input  wire              rst_n,",
		"  input  wire [WIDTH-1:0]  a,",
		"  output logic [WIDTH-1:0] y",
		");",
		"  import smoke_pkg::*;",
		"  beat_t beat;",
		"  state_t state_q, state_d;",
		"  logic [WIDTH-1:0] mem [0:DEPTH-1];",
		"  always_ff @(posedge clk or negedge rst_n) begin : seq",
		"    if (!rst_n) begin",
		"      state_q <= IDLE;",
		"      y <= '0;",
		"    end else begin",
		"      state_q <= state_d;",
		"      y <= mem[a] + beat.data;",
		"    end",
		"  end",
		"  always_comb begin",
		"    state_d = state_q;",
		"    unique case (state_q)",
		"      IDLE: if (a[0]) state_d = BUSY;",
		"      BUSY: state_d = DONE;",
		"      default: state_d = IDLE;",
		"    endcase",
		"    for (state_t s = IDLE; s != DONE; s = IDLE) state_d = s;",
		"  end",
		"  generate",
		"    for (genvar g = 0; g < WIDTH; g++) begin : gen_bits",
		"      assign mem[g] = a[g] ? '1 : '0;",
		"    end",
		"  endgenerate",
		"  assign y = {};",
		"  sub #(.WIDTH(WIDTH)) u_sub (.a(a), .y());",
		"endmodule",
	)
	sv_test_parse(&ctx, source)
	module := sv_module(t, &ctx, "smoke")
	testing.expect(t, module != nil, "smoke module missing")
	if module != nil {
		testing.expect_value(t, len(module.params), 2)
		testing.expect_value(t, len(module.ports), 4)
	}
}

// ---------------------------------------------------------------------------------------
// Practical RTL leniency found in vendor/OpenROAD/HighTide corpora
// ---------------------------------------------------------------------------------------

@(test)
test_sv_practical_leniency :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"package p;",
		"  typedef logic [7:0] t;",
		"endpackage",
		"`define MODE 1",
		"`define SIG(name) name``__LINE__",
		"module lenient #(parameter int W = `ifdef MODE 1 `else 2 `endif) (",
		"  input  .A(a),",
		"  input  [7:0] b,",
		"  output [7:0] c,",
		");",
		"  logic [7:0] assoc [string];",
		"  p::t [1:0] arr;",
		"  wire #(1, 2) delayed;",
		"  assign #1 c = &b;",
		"  assign (strong0, strong1) c = b + (* keep *) 1;",
		"  localparam int A [1:0] = '{0: 1, default: 0};",
		"  localparam int R = '{p::N{0}};",
		"  sub u0 (",
		"    (* keep *) .a(a),",
		"    .b(b)",
		"  );",
		"  function integer legacy;",
		"    input [7:0] x, y;",
		"    begin",
		"      legacy = x + y;",
		"    end",
		"  endfunction",
		"  always_comb c = `SIG(sig);",
		"endmodule",
		"module nonansi (a, b,);",
		"endmodule",
		"module dimports (a[3:0], b);",
		"endmodule",
	)
	sv_test_parse(&ctx, source)

	module := sv_module(t, &ctx, "lenient")
	testing.expect_value(t, len(module.params), 1)
	testing.expect_value(t, len(module.ports), 3)

	assoc := sv_find_decl(t, module, "assoc")
	testing.expect_value(t, len(assoc.declarators[0].unpacked_dims), 1)

	arr := sv_find_decl(t, module, "arr")
	testing.expect_value(t, len(arr.data.packed_dims), 1)

	delayed := sv_find_decl(t, module, "delayed")
	testing.expect_value(t, delayed.net_type, main.SVNetType.WIRE)

	legacy: ^main.SVSubroutine
	for item in module.items {
		if sub, ok := item.(^main.SVSubroutine); ok && sub.name == "legacy" { legacy = sub }
	}
	testing.expect(t, legacy != nil, "legacy function missing")
	if legacy != nil {
		testing.expect_value(t, len(legacy.ports), 2)
	}

	instance: ^main.SVInstance
	for item in module.items {
		if inst, ok := item.(^main.SVInstance); ok { instance = inst }
	}
	testing.expect(t, instance != nil, "instance missing")
	if instance != nil {
		testing.expect_value(t, len(instance.port_conns), 2)
	}

	nonansi := sv_module(t, &ctx, "nonansi")
	testing.expect_value(t, len(nonansi.ports), 2)

	dimports := sv_module(t, &ctx, "dimports")
	dim_a := sv_find_port(t, dimports, "a")
	testing.expect_value(t, len(dim_a.unpacked_dims), 1)
}
