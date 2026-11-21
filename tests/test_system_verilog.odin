/*
Regression tests for the SystemVerilog frontend in src/system_verilog.odin.

The parser is single pass and builds a flat, ID-based AST; these tests pin down the AST
shape through the `sv_*` view helpers for every construct in the ASIC synthesizable
subset (IEEE 1800-2023 grammar, Annex A), plus the inline preprocessing (macros,
conditionals, includes). Each test uses an in-memory source string (no external files)
except the `include tests, which use a temporary directory under tests/.
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
sv_single_module :: proc(t: ^testing.T, ctx: ^SVTestContext, source: string) -> main.SVModule {
	sv_test_parse(ctx, source)
	testing.expectf(t, len(ctx.ast.modules) == 1, "expected 1 module, got %d", len(ctx.ast.modules))
	if len(ctx.ast.modules) != 1 { return {} }
	return ctx.ast.modules[0]
}

sv_module :: proc(t: ^testing.T, ctx: ^SVTestContext, name: string) -> main.SVModule {
	index, found := ctx.ast.module_hash_map[name]
	testing.expectf(t, found, "module %q not found", name)
	if !found { return {} }
	return main.sv_module(&ctx.ast, index)
}

sv_kind :: proc(ctx: ^SVTestContext, id: u32) -> main.SVNodeKind {
	return main.sv_node(&ctx.ast, id).kind
}

sv_items :: proc(ctx: ^SVTestContext, module: main.SVModule) -> []u32 {
	return main.sv_module_items(&ctx.ast, module)
}

sv_ports :: proc(ctx: ^SVTestContext, module: main.SVModule) -> []u32 {
	return main.sv_module_ports(&ctx.ast, module)
}

sv_params :: proc(ctx: ^SVTestContext, module: main.SVModule) -> []u32 {
	return main.sv_module_params(&ctx.ast, module)
}

sv_find_port_id :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, name: string) -> u32 {
	for id in sv_ports(ctx, module) {
		port := sv_port(&ctx.ast, id)
		if port.name == name { return id }
	}
	testing.expectf(t, false, "port %q not found in %s", name, module.name)
	return main.SV_NONE
}

sv_find_port :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, name: string) -> SVPortView {
	return sv_port(&ctx.ast, sv_find_port_id(t, ctx, module, name))
}

sv_port_data :: proc(ctx: ^SVTestContext, port: SVPortView) -> SVDataTypeView {
	return sv_data_type(&ctx.ast, port.data)
}

sv_assign_rhs :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, lhs: string) -> (rhs: u32, found: bool) {
	for item in sv_items(ctx, module) {
		if sv_kind(ctx, item) != .Item_ContAssign { continue }
		for pair_id in main.sv_children(&ctx.ast, main.sv_node(&ctx.ast, item).span) {
			pair := sv_assign_pair(&ctx.ast, pair_id)
			if name, is_name := sv_expr_ident(&ctx.ast, pair.lhs); is_name && name == lhs {
				return pair.rhs, true
			}
		}
	}
	testing.expectf(t, false, "continuous assign to %q not found", lhs)
	return main.SV_NONE, false
}

SVBin :: struct {
	lhs, rhs: u32,
}

sv_binary :: proc(t: ^testing.T, ctx: ^SVTestContext, expr: u32, op: main.SVBinOp) -> (result: SVBin, ok: bool) {
	actual, lhs, rhs, good := sv_expr_binary(&ctx.ast, expr)
	testing.expect(t, good, "expected a binary expression")
	if !good { return {}, false }
	testing.expect_value(t, actual, op)
	return SVBin{lhs = lhs, rhs = rhs}, true
}

sv_ternary :: proc(t: ^testing.T, ctx: ^SVTestContext, expr: u32) -> (then_expr, else_expr: u32, ok: bool) {
	_, then_expr, else_expr, ok = sv_expr_ternary(&ctx.ast, expr)
	testing.expect(t, ok, "expected a ternary expression")
	return
}

sv_select :: proc(t: ^testing.T, ctx: ^SVTestContext, expr: u32) -> (base: u32, parts: []u32, ok: bool) {
	base, parts, ok = sv_expr_select(&ctx.ast, expr)
	testing.expect(t, ok, "expected a select expression")
	return
}

sv_number :: proc(t: ^testing.T, ctx: ^SVTestContext, expr: u32) -> main.SVNumber {
	number, ok := view_number(&ctx.ast, expr)
	testing.expect(t, ok, "expected a numeric literal")
	return number
}

sv_find_decl :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, name: string) -> (id: u32, view: SVNetDeclView) {
	for item in sv_items(ctx, module) {
		if sv_kind(ctx, item) != .Item_NetDecl { continue }
		decl, ok := sv_item_net_decl(&ctx.ast, item)
		if !ok { continue }
		for declarator_id in decl.declarators {
			if sv_declarator(&ctx.ast, declarator_id).name == name { return item, decl }
		}
	}
	testing.expectf(t, false, "declaration %q not found", name)
	return main.SV_NONE, {}
}

sv_find_typedef :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, name: string) -> (id: u32, view: SVTypeDeclView) {
	for item in sv_items(ctx, module) {
		if sv_kind(ctx, item) != .Item_TypeDecl { continue }
		decl, ok := sv_item_type_decl(&ctx.ast, item)
		if ok && decl.name == name { return item, decl }
	}
	testing.expectf(t, false, "typedef %q not found", name)
	return main.SV_NONE, {}
}

sv_param_expr :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, name: string) -> (value: u32, found: bool) {
	for item in sv_items(ctx, module) {
		if sv_kind(ctx, item) != .Item_ParamDecl { continue }
		decl, ok := sv_item_param_decl(&ctx.ast, item)
		if !ok { continue }
		for assignment_id in decl.assignments {
			assignment := sv_param_assign(&ctx.ast, assignment_id)
			if assignment.name == name && assignment.value != main.SV_NONE { return assignment.value, true }
		}
	}
	for item in sv_params(ctx, module) {
		decl, ok := sv_item_param_decl(&ctx.ast, item)
		if !ok { continue }
		for assignment_id in decl.assignments {
			assignment := sv_param_assign(&ctx.ast, assignment_id)
			if assignment.name == name && assignment.value != main.SV_NONE { return assignment.value, true }
		}
	}
	testing.expectf(t, false, "param %q not found", name)
	return main.SV_NONE, false
}

sv_param_number :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, name: string) -> main.SVNumber {
	value, found := sv_param_expr(t, ctx, module, name)
	if !found { return {} }
	return sv_number(t, ctx, value)
}

sv_proc :: proc(t: ^testing.T, ctx: ^SVTestContext, module: main.SVModule, kind: main.SVProcKind) -> (id: u32, view: SVProcView) {
	for item in sv_items(ctx, module) {
		if sv_kind(ctx, item) != .Item_Proc { continue }
		proc_view, ok := sv_item_proc(&ctx.ast, item)
		if ok && proc_view.kind == kind { return item, proc_view }
	}
	testing.expectf(t, false, "process kind %v not found in %s", kind, module.name)
	return main.SV_NONE, {}
}

sv_block :: proc(t: ^testing.T, ctx: ^SVTestContext, stmt: u32) -> (view: SVBlockView, ok: bool) {
	view, ok = sv_stmt_block(&ctx.ast, stmt)
	testing.expect(t, ok, "expected a begin/end block")
	return
}

sv_if :: proc(t: ^testing.T, ctx: ^SVTestContext, stmt: u32) -> (view: SVIfView, ok: bool) {
	view, ok = sv_stmt_if(&ctx.ast, stmt)
	testing.expect(t, ok, "expected an if statement")
	return
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

	hex := sv_param_number(t, &ctx, module, "HEX")
	testing.expect_value(t, hex.width, u32(8))
	testing.expect_value(t, hex.base, main.SVNumberBase.HEX)
	testing.expect_value(t, hex.value, u64(0xFF))
	testing.expect_value(t, hex.is_signed, false)

	bin := sv_param_number(t, &ctx, module, "BIN")
	testing.expect_value(t, bin.base, main.SVNumberBase.BIN)
	testing.expect_value(t, bin.value, u64(10))

	oct := sv_param_number(t, &ctx, module, "OCT")
	testing.expect_value(t, oct.base, main.SVNumberBase.OCT)
	testing.expect_value(t, oct.value, u64(7))

	uhex := sv_param_number(t, &ctx, module, "UHEX")
	testing.expect_value(t, uhex.width, u32(0))
	testing.expect_value(t, uhex.base, main.SVNumberBase.HEX)
	testing.expect(t, uhex.has_x_z, "x digit should set has_x_z")

	udec := sv_param_number(t, &ctx, module, "UDEC")
	testing.expect_value(t, udec.is_signed, true)
	testing.expect_value(t, udec.value, u64(10))

	zero := sv_param_number(t, &ctx, module, "ZERO")
	testing.expect_value(t, zero.is_unbased, true)
	testing.expect_value(t, zero.value, u64(0))

	one := sv_param_number(t, &ctx, module, "ONE")
	testing.expect_value(t, one.is_unbased, true)
	testing.expect_value(t, one.value, u64(1))

	xbit := sv_param_number(t, &ctx, module, "XBIT")
	testing.expect(t, xbit.has_x_z, "unbased 'x should set has_x_z")

	dec := sv_param_number(t, &ctx, module, "DEC")
	testing.expect_value(t, dec.value, u64(12345))

	real := sv_param_number(t, &ctx, module, "REAL")
	testing.expect_value(t, real.is_real, true)
	testing.expect(t, real.real_value == f64(3.5), "real literal value")

	exp := sv_param_number(t, &ctx, module, "EXP")
	testing.expect_value(t, exp.is_real, true)
	testing.expect(t, exp.real_value == f64(1000.0), "exponent literal value")

	tim := sv_param_number(t, &ctx, module, "TIME")
	testing.expect_value(t, tim.time_unit, main.SVTimeUnit.PS)
	testing.expect_value(t, tim.value, u64(300))

	space := sv_param_number(t, &ctx, module, "SPACE")
	testing.expect_value(t, space.value, u64(0))

	tq, found := sv_param_expr(t, &ctx, module, "TQ")
	if found {
		triple, is_triple := sv_expr_string(&ctx.ast, tq)
		testing.expect(t, is_triple, "expected a triple-quoted string literal")
		if is_triple {
			testing.expect(t, strings.contains(triple, "\"world\""), "triple-quoted string content")
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
	ansi_params := sv_params(&ctx, ansi)
	testing.expect_value(t, len(ansi_params), 4)
	last_param, _ := sv_item_param_decl(&ctx.ast, ansi_params[3])
	testing.expect_value(t, last_param.is_type, true)
	last_assign := sv_param_assign(&ctx.ast, last_param.assignments[0])
	testing.expect_value(t, last_assign.name, "T")
	testing.expect(t, last_assign.type_value != main.SV_NONE, "type parameter default missing")
	if last_assign.type_value != main.SV_NONE {
		default_type := sv_data_type(&ctx.ast, last_assign.type_value)
		testing.expect_value(t, default_type.var_type, main.SVVarType.LOGIC)
		testing.expect_value(t, len(default_type.packed_dims), 1)
	}

	testing.expect_value(t, len(sv_ports(&ctx, ansi)), 8)
	clk := sv_find_port(t, &ctx, ansi, "clk")
	testing.expect_value(t, clk.dir, main.SVPortDir.INPUT)
	testing.expect_value(t, clk.net_type, main.SVNetType.WIRE)

	a := sv_find_port(t, &ctx, ansi, "a")
	testing.expect_value(t, a.dir, main.SVPortDir.INPUT)
	testing.expect_value(t, len(sv_port_data(&ctx, a).packed_dims), 1)

	b := sv_find_port(t, &ctx, ansi, "b")
	testing.expect_value(t, len(sv_port_data(&ctx, b).packed_dims), 1) // inherited from `a`

	q := sv_find_port(t, &ctx, ansi, "q")
	testing.expect_value(t, q.dir, main.SVPortDir.OUTPUT)
	testing.expect_value(t, sv_port_data(&ctx, q).var_type, main.SVVarType.REG)

	v := sv_find_port(t, &ctx, ansi, "v")
	testing.expect_value(t, sv_port_data(&ctx, v).var_type, main.SVVarType.LOGIC)
	testing.expect(t, v.default_value != main.SV_NONE, "ANSI port default missing")

	io := sv_find_port(t, &ctx, ansi, "io")
	testing.expect_value(t, io.dir, main.SVPortDir.INOUT)

	mem := sv_find_port(t, &ctx, ansi, "mem")
	testing.expect_value(t, len(mem.unpacked_dims), 1)
	testing.expect_value(t, sv_range(&ctx.ast, mem.unpacked_dims[0]).is_size, false) // [0:3] range

	bus := sv_find_port(t, &ctx, ansi, "bus")
	testing.expect_value(t, bus.iface_name, "my_if")
	testing.expect_value(t, bus.modport, "slave")

	nonansi := sv_module(t, &ctx, "nonansi")
	testing.expect_value(t, nonansi.is_ansi, false)
	nonansi_q := sv_find_port(t, &ctx, nonansi, "q")
	testing.expect_value(t, nonansi_q.dir, main.SVPortDir.OUTPUT)

	wild := sv_module(t, &ctx, "wild")
	testing.expect_value(t, wild.wildcard_ports, true)
	testing.expect_value(t, len(sv_ports(&ctx, wild)), 2)

	typed := sv_module(t, &ctx, "typed_params")
	typed_params := sv_params(&ctx, typed)
	testing.expect_value(t, len(typed_params), 3) // `int N, M` groups two assignments
	first, _ := sv_item_param_decl(&ctx.ast, typed_params[0])
	testing.expect_value(t, len(first.assignments), 2)
	second, _ := sv_item_param_decl(&ctx.ast, typed_params[1])
	testing.expect_value(t, second.is_type, true)
	third, _ := sv_item_param_decl(&ctx.ast, typed_params[2])
	testing.expect_value(t, sv_data_type(&ctx.ast, third.data).type_name, "T")
	third_assign := sv_param_assign(&ctx.ast, third.assignments[0])
	testing.expect_value(t, third_assign.name, "x")
	testing.expect(t, third_assign.value != main.SV_NONE, "typed value parameter default missing")
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

	_, w1 := sv_find_decl(t, &ctx, module, "w1")
	testing.expect_value(t, w1.net_type, main.SVNetType.WIRE)
	w1_data := sv_data_type(&ctx.ast, w1.data)
	testing.expect_value(t, w1_data.is_signed, true)
	testing.expect_value(t, len(w1_data.packed_dims), 1)
	w1_d0 := sv_declarator(&ctx.ast, w1.declarators[0])
	w1_d1 := sv_declarator(&ctx.ast, w1.declarators[1])
	testing.expect(t, w1_d0.init != main.SV_NONE, "net initialization missing")
	testing.expect(t, w1_d1.init != main.SV_NONE, "second declarator init missing")

	_, packed2d := sv_find_decl(t, &ctx, module, "packed2d")
	testing.expect_value(t, len(sv_data_type(&ctx.ast, packed2d.data).packed_dims), 2)

	_, imp := sv_find_decl(t, &ctx, module, "imp0")
	testing.expect_value(t, sv_data_type(&ctx.ast, imp.data).is_signed, true)

	_, arr := sv_find_decl(t, &ctx, module, "arr0")
	testing.expect_value(t, len(sv_declarator(&ctx.ast, arr.declarators[0]).unpacked_dims), 1)

	_, byte_t := sv_find_typedef(t, &ctx, module, "byte_t")
	byte_t_data := sv_data_type(&ctx.ast, byte_t.data)
	testing.expect_value(t, byte_t_data.var_type, main.SVVarType.LOGIC)
	testing.expect_value(t, len(byte_t_data.packed_dims), 1)

	_, state_t := sv_find_typedef(t, &ctx, module, "state_t")
	state_data := sv_data_type(&ctx.ast, state_t.data)
	testing.expect(t, state_data.spec != main.SV_NONE, "enum spec missing")
	if state_data.spec != main.SV_NONE {
		spec := sv_type_spec(&ctx.ast, state_data.spec)
		testing.expect_value(t, spec.kind, main.SVTypeSpecKind.ENUM)
		testing.expect_value(t, len(spec.enum_names), 3)
		testing.expect_value(t, sv_enum_name(&ctx.ast, spec.enum_names[0]).name, "IDLE")
		testing.expect(t, sv_enum_name(&ctx.ast, spec.enum_names[1]).value != main.SV_NONE, "enum value missing")
	}

	_, s_t := sv_find_typedef(t, &ctx, module, "s_t")
	s_data := sv_data_type(&ctx.ast, s_t.data)
	testing.expect(t, s_data.spec != main.SV_NONE, "struct spec missing")
	if s_data.spec != main.SV_NONE {
		spec := sv_type_spec(&ctx.ast, s_data.spec)
		testing.expect_value(t, spec.kind, main.SVTypeSpecKind.STRUCT)
		testing.expect_value(t, spec.is_packed, true)
		testing.expect_value(t, len(spec.members), 2)
		member := sv_struct_member(&ctx.ast, spec.members[1])
		testing.expect_value(t, sv_declarator(&ctx.ast, member.declarators[0]).name, "b")
	}

	_, u_t := sv_find_typedef(t, &ctx, module, "u_t")
	u_data := sv_data_type(&ctx.ast, u_t.data)
	testing.expect(t, u_data.spec != main.SV_NONE, "union spec missing")
	if u_data.spec != main.SV_NONE {
		testing.expect_value(t, sv_type_spec(&ctx.ast, u_data.spec).kind, main.SVTypeSpecKind.UNION)
	}

	_, word_t := sv_find_typedef(t, &ctx, module, "word_t")
	testing.expect_value(t, len(word_t.unpacked_dims), 1)
	testing.expect_value(t, sv_data_type(&ctx.ast, word_t.data).type_name, "byte_t")

	_, x0 := sv_find_decl(t, &ctx, module, "x0")
	testing.expect_value(t, sv_data_type(&ctx.ast, x0.data).type_name, "byte_t")

	_, o0 := sv_find_decl(t, &ctx, module, "o0")
	o0_data := sv_data_type(&ctx.ast, o0.data)
	testing.expect_value(t, o0_data.type_scope, "pkg")
	testing.expect_value(t, o0_data.type_name, "other_t")

	_, e0 := sv_find_decl(t, &ctx, module, "e0")
	testing.expect(t, sv_data_type(&ctx.ast, e0.data).spec != main.SV_NONE, "inline enum declaration missing")

	_, s3 := sv_find_decl(t, &ctx, module, "s3")
	s3_data := sv_data_type(&ctx.ast, s3.data)
	testing.expect(t, s3_data.spec != main.SV_NONE, "inline struct declaration missing")
	if s3_data.spec != main.SV_NONE {
		spec := sv_type_spec(&ctx.ast, s3_data.spec)
		member := sv_struct_member(&ctx.ast, spec.members[0])
		testing.expect_value(t, sv_data_type(&ctx.ast, member.data).type_name, "ext_t")
		testing.expect_value(t, sv_declarator(&ctx.ast, member.declarators[0]).name, "e")
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

	p0, _ := sv_assign_rhs(t, &ctx, module, "p0")
	add, add_ok := sv_binary(t, &ctx, p0, .ADD)
	if add_ok {
		_, mul_ok := sv_binary(t, &ctx, add.rhs, .MUL)
		testing.expect(t, mul_ok, "multiplication should bind tighter than addition")
	}

	p1, _ := sv_assign_rhs(t, &ctx, module, "p1")
	mul, mul_ok := sv_binary(t, &ctx, p1, .MUL)
	if mul_ok {
		_, _ = sv_binary(t, &ctx, mul.lhs, .ADD)
	}

	p2, _ := sv_assign_rhs(t, &ctx, module, "p2")
	or_node, or_ok := sv_binary(t, &ctx, p2, .BIT_OR)
	if or_ok {
		xor_node, xor_ok := sv_binary(t, &ctx, or_node.rhs, .BIT_XOR)
		if xor_ok {
			_, _ = sv_binary(t, &ctx, xor_node.lhs, .BIT_AND)
		}
	}

	p3, _ := sv_assign_rhs(t, &ctx, module, "p3")
	log_and, and_ok := sv_binary(t, &ctx, p3, .LOG_AND)
	if and_ok {
		_, _ = sv_binary(t, &ctx, log_and.lhs, .EQ)
		_, _ = sv_binary(t, &ctx, log_and.rhs, .NE)
	}

	p4, _ := sv_assign_rhs(t, &ctx, module, "p4")
	bit_or, bit_or_ok := sv_binary(t, &ctx, p4, .BIT_OR)
	if bit_or_ok {
		left, left_ok := sv_binary(t, &ctx, bit_or.lhs, .BIT_AND)
		if left_ok {
			op, _, unary_ok := sv_expr_unary(&ctx.ast, left.lhs)
			testing.expect(t, unary_ok && op == .BIT_NOT, "expected ~a")
		}
		op, _, unary_ok := sv_expr_unary(&ctx.ast, bit_or.rhs)
		testing.expect(t, unary_ok && op == .RED_XOR, "expected ^c")
	}

	p5, _ := sv_assign_rhs(t, &ctx, module, "p5")
	shl, shl_ok := sv_binary(t, &ctx, p5, .SHL)
	if shl_ok {
		_, _ = sv_binary(t, &ctx, shl.rhs, .ADD) // a << (2 + 1)
	}

	p6, _ := sv_assign_rhs(t, &ctx, module, "p6")
	pow, pow_ok := sv_binary(t, &ctx, p6, .POW)
	if pow_ok {
		_, _, is_unary := sv_expr_unary(&ctx.ast, pow.lhs)
		testing.expect(t, is_unary, "unary minus binds tighter than **")
	}

	p7, _ := sv_assign_rhs(t, &ctx, module, "p7")
	_, ternary_rhs, ternary_ok := sv_ternary(t, &ctx, p7)
	if ternary_ok {
		_, _, _, is_ternary := sv_expr_ternary(&ctx.ast, ternary_rhs)
		testing.expect(t, is_ternary, "ternary should be right associative")
	}

	cast0, _ := sv_assign_rhs(t, &ctx, module, "cast0")
	cast_node, is_cast := sv_expr_cast(&ctx.ast, cast0)
	testing.expect(t, is_cast, "expected a cast")
	if is_cast {
		testing.expect_value(t, cast_node.kind, main.SVCastKind.SIGNING)
		testing.expect_value(t, cast_node.target, "signed")
	}

	cast1, _ := sv_assign_rhs(t, &ctx, module, "cast1")
	size_cast, is_size := sv_expr_cast(&ctx.ast, cast1)
	testing.expect(t, is_size, "expected a size cast")
	if is_size {
		testing.expect_value(t, size_cast.kind, main.SVCastKind.SIZE)
	}

	cast4, _ := sv_assign_rhs(t, &ctx, module, "cast4")
	scoped_cast, is_scoped := sv_expr_cast(&ctx.ast, cast4)
	testing.expect(t, is_scoped, "expected a scoped type cast")
	if is_scoped {
		testing.expect_value(t, scoped_cast.target, "pkg::t")
	}

	cast5, _ := sv_assign_rhs(t, &ctx, module, "cast5")
	call_cast, is_call_cast := sv_expr_cast(&ctx.ast, cast5)
	testing.expect(t, is_call_cast, "expected a constant call cast")
	if is_call_cast {
		testing.expectf(t, sv_kind(&ctx, call_cast.size) == main.SVNodeKind.Expr_Call, "size cast target should be the $clog2 call")
	}

	sys0, _ := sv_assign_rhs(t, &ctx, module, "sys0")
	sys_name, sys_is_system, _, sys_is_call := sv_expr_call(&ctx.ast, sys0)
	testing.expect(t, sys_is_call && sys_is_system && sys_name == "$unsigned", "system call missing")

	scoped_expr, _ := sv_assign_rhs(t, &ctx, module, "scoped")
	scope, scoped_name, is_name := sv_expr_scoped_name(&ctx.ast, scoped_expr)
	testing.expect(t, is_name, "expected a scoped name")
	if is_name {
		testing.expect_value(t, scope, "pkg")
		testing.expect_value(t, scoped_name, "CONST")
	}

	call_expr, _ := sv_assign_rhs(t, &ctx, module, "call")
	call_name, _, call_args, is_call := sv_expr_call(&ctx.ast, call_expr)
	testing.expect(t, is_call, "expected a scoped function call")
	if is_call {
		testing.expect_value(t, call_name, "pkg::func")
		testing.expect_value(t, len(call_args), 2)
		testing.expect_value(t, sv_call_arg(&ctx.ast, call_args[1]).name, "x")
	}

	inc0, _ := sv_assign_rhs(t, &ctx, module, "inc0")
	_, post_dec, post_prefix, is_post := sv_expr_incdec(&ctx.ast, inc0)
	testing.expect(t, is_post && !post_prefix && !post_dec, "postfix ++ missing")

	inc1, _ := sv_assign_rhs(t, &ctx, module, "inc1")
	_, pre_dec, pre_prefix, is_pre := sv_expr_incdec(&ctx.ast, inc1)
	testing.expect(t, is_pre && pre_prefix, "prefix ++ missing")
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

	bit, _ := sv_assign_rhs(t, &ctx, module, "s_bit")
	_, bit_parts, bit_ok := sv_select(t, &ctx, bit)
	if bit_ok {
		testing.expect_value(t, len(bit_parts), 1)
		testing.expect_value(t, sv_select_part(&ctx.ast, bit_parts[0]).kind, main.SVSelectKind.BIT)
	}

	part, _ := sv_assign_rhs(t, &ctx, module, "s_part")
	_, part_parts, part_ok := sv_select(t, &ctx, part)
	if part_ok {
		part_view := sv_select_part(&ctx.ast, part_parts[0])
		testing.expect_value(t, part_view.kind, main.SVSelectKind.PART)
		testing.expect_value(t, part_view.has_second, true)
	}

	plus, _ := sv_assign_rhs(t, &ctx, module, "s_plus")
	_, plus_parts, plus_ok := sv_select(t, &ctx, plus)
	if plus_ok {
		testing.expect_value(t, sv_select_part(&ctx.ast, plus_parts[0]).kind, main.SVSelectKind.INDEXED_PLUS)
	}

	minus, _ := sv_assign_rhs(t, &ctx, module, "s_minus")
	_, minus_parts, minus_ok := sv_select(t, &ctx, minus)
	if minus_ok {
		testing.expect_value(t, sv_select_part(&ctx.ast, minus_parts[0]).kind, main.SVSelectKind.INDEXED_MINUS)
	}

	chain, _ := sv_assign_rhs(t, &ctx, module, "s_chain")
	_, chain_parts, chain_ok := sv_select(t, &ctx, chain)
	if chain_ok {
		testing.expect_value(t, len(chain_parts), 2)
	}

	plain, _ := sv_assign_rhs(t, &ctx, module, "c_plain")
	plain_parts, plain_count, is_concat := sv_expr_concat(&ctx.ast, plain)
	testing.expect(t, is_concat, "expected concatenation")
	if is_concat {
		testing.expect_value(t, len(plain_parts), 3)
		testing.expect(t, plain_count == main.SV_NONE, "plain concat must not have a count")
	}

	rep, _ := sv_assign_rhs(t, &ctx, module, "c_rep")
	rep_parts, rep_count, is_rep := sv_expr_concat(&ctx.ast, rep)
	testing.expect(t, is_rep, "expected replication")
	if is_rep {
		testing.expect(t, rep_count != main.SV_NONE, "replication count missing")
		testing.expect_value(t, len(rep_parts), 2)
	}

	left, _ := sv_assign_rhs(t, &ctx, module, "c_left")
	left_dir, _, _, is_stream := sv_expr_stream(&ctx.ast, left)
	testing.expect(t, is_stream, "expected streaming concatenation")
	if is_stream {
		testing.expect_value(t, left_dir, main.SVStreamDir.LEFT)
	}

	right, _ := sv_assign_rhs(t, &ctx, module, "c_right")
	right_dir, right_slice, _, is_stream_right := sv_expr_stream(&ctx.ast, right)
	testing.expect(t, is_stream_right, "expected streaming concatenation")
	if is_stream_right {
		testing.expect_value(t, right_dir, main.SVStreamDir.RIGHT)
		testing.expect(t, right_slice != main.SV_NONE, "stream slice size missing")
	}

	inside_expr, _ := sv_assign_rhs(t, &ctx, module, "in_expr")
	_, inside_ranges, is_inside := sv_expr_inside(&ctx.ast, inside_expr)
	testing.expect(t, is_inside, "expected inside expression")
	if is_inside {
		testing.expect_value(t, len(inside_ranges), 3)
		testing.expect_value(t, sv_inside_range(&ctx.ast, inside_ranges[1]).has_hi, true)
	}

	ap_pos, _ := sv_assign_rhs(t, &ctx, module, "ap_pos")
	pos_pattern, is_pattern := sv_expr_aggregate(&ctx.ast, ap_pos)
	testing.expect(t, is_pattern, "expected assignment pattern")
	if is_pattern {
		testing.expect_value(t, len(pos_pattern.entries), 3)
	}

	ap_key, _ := sv_assign_rhs(t, &ctx, module, "ap_key")
	key_pattern, is_key_pattern := sv_expr_aggregate(&ctx.ast, ap_key)
	testing.expect(t, is_key_pattern, "expected keyed assignment pattern")
	if is_key_pattern {
		testing.expect_value(t, len(key_pattern.entries), 3)
		testing.expect_value(t, sv_aggregate_entry(&ctx.ast, key_pattern.entries[0]).key, "default")
		testing.expect_value(t, sv_aggregate_entry(&ctx.ast, key_pattern.entries[1]).key, "foo")
		testing.expect_value(t, sv_aggregate_entry(&ctx.ast, key_pattern.entries[2]).key, "bar")
	}

	ap_rep, _ := sv_assign_rhs(t, &ctx, module, "ap_rep")
	rep_pattern, is_rep_pattern := sv_expr_aggregate(&ctx.ast, ap_rep)
	testing.expect(t, is_rep_pattern, "expected replicated assignment pattern")
	if is_rep_pattern {
		testing.expect(t, rep_pattern.count != main.SV_NONE, "pattern replication count missing")
	}

	ap_typed, _ := sv_assign_rhs(t, &ctx, module, "ap_typed")
	typed_pattern, is_typed_pattern := sv_expr_aggregate(&ctx.ast, ap_typed)
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

	instances := make([dynamic]u32, context.temp_allocator)
	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) == .Item_Instance { append(&instances, item) }
	}
	testing.expect_value(t, len(instances), 9)

	u0, _ := sv_item_instance(&ctx.ast, instances[0])
	testing.expect_value(t, u0.cell_name, "sub")
	testing.expect_value(t, u0.name, "u0")
	testing.expect_value(t, u0.is_gate, false)
	testing.expect_value(t, len(u0.param_overrides), 3)
	first_override := sv_param_override(&ctx.ast, u0.param_overrides[0])
	testing.expect_value(t, first_override.name, "W")
	testing.expect(t, first_override.type_value == main.SV_NONE, "W is a value parameter")
	testing.expect(t, sv_param_override(&ctx.ast, u0.param_overrides[2]).type_value != main.SV_NONE, "T should be a type argument")
	testing.expect_value(t, len(u0.port_conns), 3)
	conn0 := sv_port_conn(&ctx.ast, u0.port_conns[0])
	testing.expect_value(t, conn0.name, "a")
	testing.expect(t, conn0.value != main.SV_NONE, "port value missing")
	conn1 := sv_port_conn(&ctx.ast, u0.port_conns[1])
	testing.expect_value(t, conn1.name, "b")
	testing.expect(t, conn1.value == main.SV_NONE, "empty connection should have no value")

	u1, _ := sv_item_instance(&ctx.ast, instances[1])
	testing.expect_value(t, len(u1.param_overrides), 2)
	testing.expect_value(t, sv_param_override(&ctx.ast, u1.param_overrides[0]).name, "") // ordered
	testing.expect(t, sv_param_override(&ctx.ast, u1.param_overrides[1]).type_value != main.SV_NONE, "ordered type argument missing")
	testing.expect_value(t, len(u1.port_conns), 3)
	testing.expect_value(t, sv_port_conn(&ctx.ast, u1.port_conns[0]).name, "") // ordered

	u2, _ := sv_item_instance(&ctx.ast, instances[2])
	testing.expect_value(t, len(u2.unpacked_dims), 1)

	u3, _ := sv_item_instance(&ctx.ast, instances[3])
	u4, _ := sv_item_instance(&ctx.ast, instances[4])
	testing.expect_value(t, u4.name, "u4")
	testing.expect_value(t, len(u4.port_conns), 1)

	u5, _ := sv_item_instance(&ctx.ast, instances[5])
	testing.expect_value(t, u5.wildcard_ports, true)
	testing.expect_value(t, len(u5.port_conns), 0)

	u6, _ := sv_item_instance(&ctx.ast, instances[6])
	testing.expect_value(t, u6.wildcard_ports, true)
	testing.expect_value(t, len(u6.port_conns), 2)
	testing.expect_value(t, sv_port_conn(&ctx.ast, u6.port_conns[0]).name, "y")

	g0, _ := sv_item_instance(&ctx.ast, instances[7])
	testing.expect_value(t, g0.is_gate, true)
	testing.expect_value(t, g0.name, "g0")

	g1, _ := sv_item_instance(&ctx.ast, instances[8])
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
		"    casez (N)",
		"      2, 4: begin : c_even wire c0; end",
		"      default: begin : c_default wire c1; end",
		"    endcase",
		"  endgenerate",
		"  for (genvar j = 0; j < 2; j++) begin : implicit_loop wire z; end",
		"  if (N > 2) begin : top_if wire q; end else begin : top_else wire q2; end",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	items := sv_items(&ctx, module)
	region_item := items[1] // items[0] is `genvar i`
	testing.expect_value(t, sv_kind(&ctx, region_item), main.SVNodeKind.Item_GenRegion)
	if sv_kind(&ctx, region_item) == .Item_GenRegion {
		region, _ := sv_item_gen_region(&ctx.ast, region_item)
		testing.expect_value(t, len(region.items), 2)

		loop_item_id := region.items[0]
		testing.expect_value(t, sv_kind(&ctx, loop_item_id), main.SVNodeKind.Item_GenLoop)
		if sv_kind(&ctx, loop_item_id) == .Item_GenLoop {
			loop_item, _ := sv_item_gen_loop(&ctx.ast, loop_item_id)
			testing.expect_value(t, loop_item.var, "i")
			testing.expect(t, loop_item.body != main.SV_NONE, "generate loop body missing")
			if loop_item.body != main.SV_NONE {
				body, body_ok := sv_gen_block(&ctx.ast, loop_item.body)
				testing.expect(t, body_ok, "generate loop body should be a block")
				testing.expect_value(t, body.label, "outer")
				testing.expect_value(t, len(body.items), 1)
				if_item_id := body.items[0]
				testing.expect_value(t, sv_kind(&ctx, if_item_id), main.SVNodeKind.Item_GenIf)
				if sv_kind(&ctx, if_item_id) == .Item_GenIf {
					if_item, _ := sv_item_gen_if(&ctx.ast, if_item_id)
					then_blk, _ := sv_gen_block(&ctx.ast, if_item.then_blk)
					else_blk, _ := sv_gen_block(&ctx.ast, if_item.else_blk)
					testing.expect(t, if_item.then_blk != main.SV_NONE && then_blk.label == "even", "then label")
					testing.expect(t, if_item.else_blk != main.SV_NONE && else_blk.label == "odd", "else label")
					if if_item.then_blk != main.SV_NONE && len(then_blk.items) == 2 {
						inner_item := then_blk.items[1]
						testing.expect_value(t, sv_kind(&ctx, inner_item), main.SVNodeKind.Item_GenRegion)
						if sv_kind(&ctx, inner_item) == .Item_GenRegion {
							inner, _ := sv_item_gen_region(&ctx.ast, inner_item)
							testing.expect_value(t, inner.label, "inner")
						}
					} else {
						testing.expectf(t, false, "expected a nested begin block inside the generate if")
					}
				}
			}
		}

		case_item_id := region.items[1]
		testing.expect_value(t, sv_kind(&ctx, case_item_id), main.SVNodeKind.Item_GenCase)
		if sv_kind(&ctx, case_item_id) == .Item_GenCase {
			case_item, _ := sv_item_gen_case(&ctx.ast, case_item_id)
			testing.expect_value(t, case_item.kind, main.SVCaseKind.CASEZ)
			testing.expect_value(t, len(case_item.items), 2)
			first := sv_gen_case_item(&ctx.ast, case_item.items[0])
			second := sv_gen_case_item(&ctx.ast, case_item.items[1])
			testing.expect_value(t, len(first.exprs), 2)
			testing.expect_value(t, second.is_default, true)
			case_body, _ := sv_gen_block(&ctx.ast, first.body)
			testing.expect(t, first.body != main.SV_NONE && case_body.label == "c_even", "case block label")
		}
	} else {
		testing.expectf(t, false, "expected a generate region")
	}

	implicit_item_id := items[2]
	testing.expect_value(t, sv_kind(&ctx, implicit_item_id), main.SVNodeKind.Item_GenLoop)
	if sv_kind(&ctx, implicit_item_id) == .Item_GenLoop {
		implicit_item, _ := sv_item_gen_loop(&ctx.ast, implicit_item_id)
		testing.expect_value(t, implicit_item.var, "j")
		body, _ := sv_gen_block(&ctx.ast, implicit_item.body)
		testing.expect(t, implicit_item.body != main.SV_NONE && body.label == "implicit_loop", "implicit loop label")
	}

	top_if_item_id := items[3]
	testing.expect_value(t, sv_kind(&ctx, top_if_item_id), main.SVNodeKind.Item_GenIf)
	if sv_kind(&ctx, top_if_item_id) == .Item_GenIf {
		top_if_item, _ := sv_item_gen_if(&ctx.ast, top_if_item_id)
		then_blk, _ := sv_gen_block(&ctx.ast, top_if_item.then_blk)
		else_blk, _ := sv_gen_block(&ctx.ast, top_if_item.else_blk)
		testing.expect(t, top_if_item.then_blk != main.SV_NONE && then_blk.label == "top_if", "top if label")
		testing.expect(t, top_if_item.else_blk != main.SV_NONE && else_blk.label == "top_else", "top else label")
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

	seq_id, seq := sv_proc(t, &ctx, module, .ALWAYS_FF)
	testing.expect(t, seq_id != main.SV_NONE, "always_ff missing")
	if seq_id != main.SV_NONE {
		testing.expect_value(t, len(seq.events), 2)
		testing.expect_value(t, sv_event(&ctx.ast, seq.events[0]).edge, main.SVEdgeKind.POSEDGE)
		testing.expect_value(t, sv_event(&ctx.ast, seq.events[1]).edge, main.SVEdgeKind.NEGEDGE)
		block, block_ok := sv_block(t, &ctx, seq.body)
		if block_ok {
			testing.expect_value(t, block.label, "seq")
			testing.expect_value(t, len(block.stmts), 1)
			if_stmt_id := block.stmts[0]
			testing.expect_value(t, sv_kind(&ctx, if_stmt_id), main.SVNodeKind.Stmt_If)
			if_stmt, is_if := sv_stmt_if(&ctx.ast, if_stmt_id)
			testing.expect(t, is_if, "expected if statement")
			if is_if {
				testing.expect(t, if_stmt.then_body != main.SV_NONE, "if then body")
				testing.expect(t, if_stmt.else_body != main.SV_NONE, "if else body")
				testing.expect_value(t, sv_kind(&ctx, if_stmt.else_body), main.SVNodeKind.Stmt_If)
				if sv_kind(&ctx, if_stmt.else_body) == .Stmt_If {
					else_if, _ := sv_stmt_if(&ctx.ast, if_stmt.else_body)
					assign, is_assign := sv_stmt_assign(&ctx.ast, else_if.then_body)
					testing.expect(t, is_assign && assign.nonblocking, "nonblocking assignment missing")
				}
			}
		}
	}

	comb_id, comb := sv_proc(t, &ctx, module, .ALWAYS_COMB)
	testing.expect(t, comb_id != main.SV_NONE, "always_comb missing")
	if comb_id != main.SV_NONE {
		block, block_ok := sv_block(t, &ctx, comb.body)
		if block_ok {
			case_stmt_id := block.stmts[0]
			testing.expect_value(t, sv_kind(&ctx, case_stmt_id), main.SVNodeKind.Stmt_Case)
			case_stmt, is_case := sv_stmt_case(&ctx.ast, case_stmt_id)
			testing.expect(t, is_case, "expected case statement")
			if is_case {
				testing.expect_value(t, case_stmt.kind, main.SVCaseKind.CASE)
				testing.expect_value(t, case_stmt.qualifier, main.SVQualifier.UNIQUE)
				testing.expect_value(t, len(case_stmt.items), 3)
				second_item := sv_case_item(&ctx.ast, case_stmt.items[1])
				third_item := sv_case_item(&ctx.ast, case_stmt.items[2])
				testing.expect_value(t, len(second_item.exprs), 2)
				testing.expect_value(t, third_item.is_default, true)
			}
		}
	}

	always_id, always := sv_proc(t, &ctx, module, .ALWAYS)
	testing.expect(t, always_id != main.SV_NONE, "always missing")
	if always_id != main.SV_NONE {
		testing.expect(
			t,
			always.any_event || (len(always.events) > 0 && sv_event(&ctx.ast, always.events[0]).edge == main.SVEdgeKind.POSEDGE),
			"always sensitivity",
		)
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

	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) != .Item_Proc { continue }
		proc_node, is_proc := sv_item_proc(&ctx.ast, item)
		if !is_proc || proc_node.kind != .ALWAYS { continue }
		block, is_block := sv_stmt_block(&ctx.ast, proc_node.body)
		if !is_block { continue }
		for stmt in block.stmts {
			#partial switch sv_kind(&ctx, stmt) {
			case .Stmt_Case:
				s, _ := sv_stmt_case(&ctx.ast, stmt)
				if s.kind == .CASEZ {
					found_casez = true
					testing.expect_value(t, s.qualifier, main.SVQualifier.PRIORITY)
				}
				if s.is_inside {
					found_inside_case = true
					item0 := sv_case_item(&ctx.ast, s.items[0])
					testing.expect_value(t, len(item0.exprs), 1)
				}
			case .Stmt_For:
				s, _ := sv_stmt_for(&ctx.ast, stmt)
				found_for = true
				testing.expect_value(t, len(s.var_decls), 1)
				testing.expect_value(t, len(s.steps), 2)
				body_block, body_ok := sv_stmt_block(&ctx.ast, s.body)
				if body_ok {
					for inner in body_block.stmts {
						if sv_kind(&ctx, inner) != .Stmt_If { continue }
						js, _ := sv_stmt_if(&ctx.ast, inner)
						if js.then_body == main.SV_NONE { continue }
						if sv_kind(&ctx, js.then_body) != .Stmt_Jump { continue }
						jump, _ := sv_stmt_jump(&ctx.ast, js.then_body)
						if jump.kind == .CONTINUE { found_continue = true }
						if jump.kind == .BREAK { found_break = true }
					}
				}
			case .Stmt_While:
				s, _ := sv_stmt_while(&ctx.ast, stmt)
				if s.do_while { found_do_while = true } else { found_while = true }
			case .Stmt_Repeat: found_repeat = true
			case .Stmt_Foreach:
				s, _ := sv_stmt_foreach(&ctx.ast, stmt)
				found_foreach = true
				testing.expect_value(t, len(s.loop_vars), 1)
				testing.expect_value(t, s.loop_vars[0], "idx")
			case .Stmt_Timing:
				timing_id := main.sv_node(&ctx.ast, stmt).a
				timing := sv_timing_ctl(&ctx.ast, timing_id)
				if timing.is_delay { found_delay_stmt = true } else { found_event_stmt = true }
			case .Stmt_Assign:
				s, _ := sv_stmt_assign(&ctx.ast, stmt)
				if s.op == .ADD_EQ { found_compound_add = true }
				if s.op == .SHL_EQ { found_compound_shl = true }
			case .Expr_Call:
				name, _, _, _ := sv_expr_call(&ctx.ast, stmt)
				testing.expect_value(t, name, "f")
				found_void_call = true
			case .Stmt_Assert:
				s, _ := sv_stmt_assert(&ctx.ast, stmt)
				if s.kind == .ASSERT { found_assert = true }
				if s.kind == .ASSUME { found_assume = true }
				if s.kind == .COVER { found_cover = true }
			case .Stmt_If:
				s, _ := sv_stmt_if(&ctx.ast, stmt)
				if s.then_body != main.SV_NONE && sv_kind(&ctx, s.then_body) == .Stmt_Jump {
					js, _ := sv_stmt_jump(&ctx.ast, s.then_body)
					if js.kind == .CONTINUE { found_continue = true }
					if js.kind == .BREAK { found_break = true }
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

	initial_id, initial := sv_proc(t, &ctx, module, .INITIAL)
	testing.expect(t, initial_id != main.SV_NONE, "initial missing")
	if initial_id != main.SV_NONE {
		block, block_ok := sv_block(t, &ctx, initial.body)
		if block_ok {
			testing.expect_value(t, block.label, "init_block")
			testing.expect_value(t, len(block.imports), 1)
			testing.expect_value(t, sv_import(&ctx.ast, block.imports[0]).package_name, "pkg")
			testing.expect_value(t, len(block.decls), 1)
			testing.expect_value(t, len(block.stmts), 6)
			testing.expect_value(t, sv_kind(&ctx, block.stmts[0]), main.SVNodeKind.Stmt_Forever)
			bare_call_name, _, _, bare_is_call := sv_expr_call(&ctx.ast, block.stmts[1])
			testing.expect(t, bare_is_call && bare_call_name == "empty_statement", "parenthesis-less task call missing")
			scoped_call_name, _, _, scoped_is_call := sv_expr_call(&ctx.ast, block.stmts[2])
			testing.expect(t, scoped_is_call && scoped_call_name == "pkg::do_thing", "scoped task call missing")
			scoped_arg_name, _, _, scoped_arg_is_call := sv_expr_call(&ctx.ast, block.stmts[3])
			testing.expect(t, scoped_arg_is_call && scoped_arg_name == "pkg::check", "scoped call with arguments missing")
			method_name, _, _, method_is_call := sv_expr_call(&ctx.ast, block.stmts[4])
			testing.expect(t, method_is_call && method_name == "dummy.push_back", "method call missing")
			method_assign, is_method_assign := sv_stmt_assign(&ctx.ast, block.stmts[5])
			testing.expect(t, is_method_assign, "method call assignment missing")
			if is_method_assign {
				pop_name, _, _, is_pop := sv_expr_call(&ctx.ast, method_assign.rhs)
				testing.expect(t, is_pop && pop_name == "dummy.pop_front", "method call on assignment RHS missing")
			}
		}
	}

	final_id, _ := sv_proc(t, &ctx, module, .FINAL)
	testing.expect(t, final_id != main.SV_NONE, "final block missing")

	latch_id, _ := sv_proc(t, &ctx, module, .ALWAYS_LATCH)
	testing.expect(t, latch_id != main.SV_NONE, "always_latch missing")

	// the bare `always @*` process and the event `iff` guard
	found_any_event := false
	found_event_iff := false
	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) != .Item_Proc { continue }
		proc_node, is_proc := sv_item_proc(&ctx.ast, item)
		if !is_proc || proc_node.kind != .ALWAYS { continue }
		if proc_node.any_event { found_any_event = true }
		for event in proc_node.events {
			if sv_event(&ctx.ast, event).iff != main.SV_NONE { found_event_iff = true }
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

	unit_imports := main.sv_unit_imports(&ctx.ast)
	testing.expect_value(t, len(unit_imports), 1)
	testing.expect_value(t, sv_import(&ctx.ast, unit_imports[0]).package_name, "pkg0")
	testing.expect_value(t, sv_import(&ctx.ast, unit_imports[0]).name, "*")
	testing.expect_value(t, len(ctx.ast.packages), 1)
	testing.expect_value(t, len(main.sv_children(&ctx.ast, ctx.ast.items)), 3) // top_t, TOPP, top_f

	pkg_index, pkg_found := ctx.ast.package_hash_map["pkg0"]
	testing.expect(t, pkg_found, "package not found")
	if pkg_found {
		pkg := main.sv_package(&ctx.ast, pkg_index)
		pkg_imports := ctx.ast.imports[pkg.imports.start:pkg.imports.start + pkg.imports.len]
		testing.expect_value(t, len(pkg_imports), 1)
		testing.expect_value(t, sv_import(&ctx.ast, pkg_imports[0]).package_name, "pkg1")
		testing.expect_value(t, len(main.sv_children(&ctx.ast, pkg.items)), 4) // param, typedef, function, task
	}

	subs := sv_module(t, &ctx, "subs")
	subs_functions := make([dynamic]u32, context.temp_allocator)
	for item in sv_items(&ctx, subs) {
		if sv_kind(&ctx, item) == .Item_Subroutine { append(&subs_functions, item) }
	}
	testing.expect_value(t, len(subs_functions), 4)

	add_one, _ := sv_item_subroutine(&ctx.ast, subs_functions[0])
	testing.expect_value(t, add_one.name, "add_one")
	testing.expect_value(t, add_one.is_automatic, true)
	testing.expect_value(t, len(add_one.ports), 2)
	testing.expect(t, sv_tf_port(&ctx.ast, add_one.ports[1]).default_value != main.SV_NONE, "tf port default missing")
	add_body, _ := sv_stmt_block(&ctx.ast, add_one.body)
	testing.expect_value(t, len(add_body.decls), 2) // local typedef + variable

	no_value, _ := sv_item_subroutine(&ctx.ast, subs_functions[1])
	testing.expect_value(t, sv_data_type(&ctx.ast, no_value.return_data).var_type, main.SVVarType.VOID)

	legacy_sub, _ := sv_item_subroutine(&ctx.ast, subs_functions[2])
	testing.expect_value(t, legacy_sub.is_automatic, false)
	testing.expect_value(t, len(legacy_sub.ports), 1) // legacy tf port declaration

	clear, _ := sv_item_subroutine(&ctx.ast, subs_functions[3])
	testing.expect_value(t, clear.is_task, true)
	clear_body, _ := sv_stmt_block(&ctx.ast, clear.body)
	testing.expect_value(t, len(clear_body.stmts), 1) // for loop
	testing.expect_value(t, len(clear_body.imports), 1)
	testing.expect_value(t, sv_import(&ctx.ast, clear_body.imports[0]).package_name, "pkg1")
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
		"interface legacy_if (a, b);",
		"  input a;",
		"  output b;",
		"endinterface",
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

	iface_index, iface_found := ctx.ast.interface_hash_map["bus_if"]
	testing.expect(t, iface_found, "interface not found")
	if iface_found {
		iface := main.sv_interface(&ctx.ast, iface_index)
		testing.expect_value(t, iface.name, "bus_if")
		testing.expect_value(t, iface.params.len, 1)
		iface_ports := main.sv_interface_ports(&ctx.ast, iface)
		testing.expect_value(t, len(iface_ports), 1)
		iface_imports := ctx.ast.imports[iface.imports.start:iface.imports.start + iface.imports.len]
		testing.expect_value(t, len(iface_imports), 1)
		modports := main.sv_interface_modports(&ctx.ast, iface)
		testing.expect_value(t, len(modports), 2)
		master := sv_modport(&ctx.ast, modports[0])
		testing.expect_value(t, master.name, "master")
		testing.expect_value(t, len(master.ports), 3)
		testing.expect_value(t, sv_modport_port(&ctx.ast, master.ports[0]).dir, main.SVPortDir.OUTPUT)
	}

	legacy_index, legacy_found := ctx.ast.interface_hash_map["legacy_if"]
	testing.expect(t, legacy_found, "legacy interface not found")
	if legacy_found {
		legacy := main.sv_interface(&ctx.ast, legacy_index)
		legacy_ports := main.sv_interface_ports(&ctx.ast, legacy)
		testing.expect_value(t, len(legacy_ports), 2)
		testing.expect_value(t, sv_port(&ctx.ast, legacy_ports[0]).dir, main.SVPortDir.INPUT)
		testing.expect_value(t, sv_port(&ctx.ast, legacy_ports[1]).dir, main.SVPortDir.OUTPUT)
	}

	uses := sv_module(t, &ctx, "uses")
	testing.expect_value(t, len(sv_ports(&ctx, uses)), 2)
	master := sv_find_port(t, &ctx, uses, "m")
	testing.expect_value(t, master.iface_name, "bus_if")
	testing.expect_value(t, master.modport, "master")

	instances := make([dynamic]u32, context.temp_allocator)
	for item in sv_items(&ctx, uses) {
		if sv_kind(&ctx, item) == .Item_Instance { append(&instances, item) }
	}
	testing.expect_value(t, len(instances), 2)
	inst0, _ := sv_item_instance(&ctx.ast, instances[0])
	inst1, _ := sv_item_instance(&ctx.ast, instances[1])
	testing.expect_value(t, inst0.cell_name, "bus_if")
	testing.expect_value(t, inst1.cell_name, "bus_if")

	generic := sv_module(t, &ctx, "generic_if")
	generic_ports := sv_ports(&ctx, generic)
	testing.expect_value(t, len(generic_ports), 1)
	generic_port := sv_port(&ctx.ast, generic_ports[0])
	testing.expect_value(t, generic_port.iface_name, "interface")
	testing.expect_value(t, generic_port.name, "d")
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
		"`define __LINE__X 99",
		"`define PREFIXED `__LINE__X",
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
		"  localparam P = `PREFIXED;",
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

	w, _ := sv_param_expr(t, &ctx, module, "W")
	testing.expect_value(t, sv_number(t, &ctx, w).value, u64(8))

	m, _ := sv_param_expr(t, &ctx, module, "M")
	_, _, _ = sv_ternary(t, &ctx, m) // `MAX expands to a ternary

	s, _ := sv_param_expr(t, &ctx, module, "S")
	greeting, is_string := sv_expr_string(&ctx.ast, s)
	testing.expect(t, is_string, "expected an expanded string literal")
	if is_string {
		testing.expect_value(t, greeting, "hello world")
	}

	j, _ := sv_param_expr(t, &ctx, module, "J")
	joined, is_ident := sv_expr_ident(&ctx.ast, j)
	testing.expect(t, is_ident && joined == "foobar", "token pasting failed")

	line, _ := sv_param_expr(t, &ctx, module, "L")
	testing.expect(t, sv_number(t, &ctx, line).value > 0, "`__LINE__ should be numeric")

	prefixed, _ := sv_param_expr(t, &ctx, module, "P")
	testing.expect_value(t, sv_number(t, &ctx, prefixed).value, u64(99))

	file, _ := sv_param_expr(t, &ctx, module, "F")
	_, file_is_string := sv_expr_string(&ctx.ast, file)
	testing.expect(t, file_is_string, "`__FILE__ should be a string literal")

	mode, _ := sv_param_expr(t, &ctx, module, "MODE")
	testing.expect_value(t, sv_number(t, &ctx, mode).value, u64(2))

	multi, _ := sv_param_expr(t, &ctx, module, "M2")
	_, _ = sv_binary(t, &ctx, multi, .ADD) // continuation lines joined

	comment_line, _ := sv_param_expr(t, &ctx, module, "M3")
	_, _ = sv_binary(t, &ctx, comment_line, .ADD) // `//` comment + continuation

	comment_block, _ := sv_param_expr(t, &ctx, module, "M4")
	_, _ = sv_binary(t, &ctx, comment_block, .ADD) // block comment removed

	comment_string, comment_found := sv_param_expr(t, &ctx, module, "M5")
	if comment_found {
		text, is_text := sv_expr_string(&ctx.ast, comment_string)
		testing.expect(t, is_text && strings.contains(text, "//"), "comment markers inside strings must be preserved")
	}

	def, _ := sv_param_expr(t, &ctx, module, "D")
	_, _ = sv_binary(t, &ctx, def, .ADD) // macro parameter default

	_, removed_defined := ctx.ast.defines["REMOVED"]
	testing.expect(t, !removed_defined, "`undef must remove the macro")

	wire_found := false
	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) != .Item_NetDecl { continue }
		decl, _ := sv_item_net_decl(&ctx.ast, item)
		for declarator_id in decl.declarators {
			if sv_declarator(&ctx.ast, declarator_id).name == "combined" { wire_found = true }
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
	ensure(os.write_entire_file(main_path, sv_src("`include \"defs.svh\"", "module included;", "`include \"items.svh\"", "endmodule")) == nil)
	ensure(
		os.write_entire_file(
			fmt.tprintf("%s/defs.svh", tmp_root),
			sv_src("`define CONFIG_FILE \"sub/extra.svh\"", "`include `CONFIG_FILE", "`include \"header.svh\""),
		) ==
		nil,
	)
	ensure(os.write_entire_file(fmt.tprintf("%s/items.svh", tmp_root), sv_src("wire from_include;")) == nil)
	ensure(os.write_entire_file(fmt.tprintf("%s/sub/extra.svh", tmp_root), sv_src("`define EXTRA_SEEN 1")) == nil)
	ensure(os.write_entire_file(fmt.tprintf("%s/include_dir/header.svh", tmp_root), sv_src("`define HEADER_SEEN 1")) == nil)

	append(&ctx.ast.include_dirs, fmt.tprintf("%s/include_dir", tmp_root))
	main.system_verilog_parse_to_ast(main_path, &ctx.ast, ctx.alloc)

	module := sv_module(t, &ctx, "included")
	testing.expect(t, module.name == "included", "module from included file missing")

	found_wire := false
	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) != .Item_NetDecl { continue }
		decl, _ := sv_item_net_decl(&ctx.ast, item)
		for declarator_id in decl.declarators {
			if sv_declarator(&ctx.ast, declarator_id).name == "from_include" { found_wire = true }
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
	module_ports := sv_ports(&ctx, module)
	testing.expect_value(t, len(module_ports), 3)
	p_port := sv_port(&ctx.ast, module_ports[1])
	testing.expect_value(t, p_port.name, "P")
	testing.expect(t, p_port.expr != main.SV_NONE, "explicit port expression missing")
	last_port := sv_port(&ctx.ast, module_ports[2])
	testing.expect_value(t, last_port.name, "")
	testing.expect(t, last_port.expr != main.SV_NONE, "concatenated port expression missing")

	alias_count := 0
	defparam_count := 0
	for item in sv_items(&ctx, module) {
		#partial switch sv_kind(&ctx, item) {
		case .Item_Alias:
			alias_count += 1
			alias_names := main.sv_children(&ctx.ast, main.sv_node(&ctx.ast, item).span)
			testing.expect_value(t, len(alias_names), 2)
		case .Item_Defparam:
			defparam_count += 1
			pairs := main.sv_children(&ctx.ast, main.sv_node(&ctx.ast, item).span)
			testing.expect_value(t, len(pairs), 2)
			pair := sv_assign_pair(&ctx.ast, pairs[0])
			_, parts, ok := sv_select(t, &ctx, pair.lhs)
			if ok {
				testing.expect_value(t, len(parts), 1)
				testing.expect_value(t, sv_select_part(&ctx.ast, parts[0]).member, "par")
			}
		}
	}
	testing.expect_value(t, alias_count, 2)
	testing.expect_value(t, defparam_count, 1)

	explicit := sv_module(t, &ctx, "ansi_explicit")
	testing.expect_value(t, len(sv_ports(&ctx, explicit)), 2)
	p1 := sv_find_port(t, &ctx, explicit, "P1")
	testing.expect_value(t, p1.dir, main.SVPortDir.OUTPUT)
	testing.expect(t, p1.expr != main.SV_NONE, "ANSI explicit port expression missing")
	p2 := sv_find_port(t, &ctx, explicit, "P2")
	testing.expect_value(t, p2.dir, main.SVPortDir.INPUT)
	testing.expect(t, p2.expr != main.SV_NONE, "ANSI explicit input port expression missing")

	skips_index, skips_found := ctx.ast.module_hash_map["skips"]
	testing.expect(t, skips_found, "module with skipped constructs missing")
	_, skip_pkg_found := ctx.ast.package_hash_map["skip_pkg"]
	testing.expect(t, skip_pkg_found, "package with covergroup missing")
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

	assertions := make([dynamic]u32, context.temp_allocator)
	calls := make([dynamic]u32, context.temp_allocator)
	for item in sv_items(&ctx, module) {
		#partial switch sv_kind(&ctx, item) {
		case .Stmt_Assert: append(&assertions, item)
		case .Expr_Call: append(&calls, item)
		}
	}
	testing.expect_value(t, len(assertions), 3)
	first_assertion, _ := sv_stmt_assert(&ctx.ast, assertions[0])
	testing.expect(t, first_assertion.is_property, "first module assertion should be a property")
	testing.expect_value(t, first_assertion.kind, main.SVAssertKind.ASSERT)
	testing.expect(t, len(first_assertion.property_text) > 0, "property text missing")
	testing.expect(t, first_assertion.else_body != main.SV_NONE, "assertion else action missing")
	second_assertion, _ := sv_stmt_assert(&ctx.ast, assertions[1])
	testing.expect_value(t, second_assertion.kind, main.SVAssertKind.ASSUME)
	third_assertion, _ := sv_stmt_assert(&ctx.ast, assertions[2])
	testing.expect_value(t, third_assertion.kind, main.SVAssertKind.COVER)

	testing.expect_value(t, len(calls), 1)
	warning_name, _, _, _ := sv_expr_call(&ctx.ast, calls[0])
	testing.expect_value(t, warning_name, "$warning")

	// `if (1) $fatal(...)` is a generate-if containing an elaboration task
	found_elab_if := false
	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) != .Item_GenIf { continue }
		found_elab_if = true
		gen_if, _ := sv_item_gen_if(&ctx.ast, item)
		then_blk, then_ok := sv_gen_block(&ctx.ast, gen_if.then_blk)
		if then_ok && len(then_blk.items) == 1 {
			fatal_name, _, _, fatal_is_call := sv_expr_call(&ctx.ast, then_blk.items[0])
			if fatal_is_call { testing.expect_value(t, fatal_name, "$fatal") }
		}
	}
	testing.expect(t, found_elab_if, "generate-if with $fatal missing")

	// immediate assertions inside the clocked block
	ff_id, ff := sv_proc(t, &ctx, module, .ALWAYS_FF)
	if ff_id != main.SV_NONE {
		block, block_ok := sv_block(t, &ctx, ff.body)
		if block_ok {
			testing.expect_value(t, len(block.stmts), 3)
			first, ok := sv_stmt_assert(&ctx.ast, block.stmts[0])
			testing.expect(t, ok && !first.is_property, "immediate assert missing")
			if ok {
				testing.expect(t, first.else_body != main.SV_NONE, "immediate assert else body missing")
			}
			two, ok2 := sv_stmt_assert(&ctx.ast, block.stmts[1])
			testing.expect(t, ok2 && !two.is_property, "assert final missing")
			three, ok3 := sv_stmt_assert(&ctx.ast, block.stmts[2])
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
	testing.expect(t, module.name == "smoke", "smoke module missing")
	if module.name == "smoke" {
		testing.expect_value(t, len(sv_params(&ctx, module)), 2)
		testing.expect_value(t, len(sv_ports(&ctx, module)), 4)
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
	testing.expect_value(t, len(sv_params(&ctx, module)), 1)
	testing.expect_value(t, len(sv_ports(&ctx, module)), 3)

	_, assoc := sv_find_decl(t, &ctx, module, "assoc")
	testing.expect_value(t, len(sv_declarator(&ctx.ast, assoc.declarators[0]).unpacked_dims), 1)

	_, arr := sv_find_decl(t, &ctx, module, "arr")
	testing.expect_value(t, len(sv_data_type(&ctx.ast, arr.data).packed_dims), 1)

	_, delayed := sv_find_decl(t, &ctx, module, "delayed")
	testing.expect_value(t, delayed.net_type, main.SVNetType.WIRE)

	legacy_id := u32(main.SV_NONE)
	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) != .Item_Subroutine { continue }
		sub, _ := sv_item_subroutine(&ctx.ast, item)
		if sub.name == "legacy" { legacy_id = item }
	}
	testing.expect(t, legacy_id != main.SV_NONE, "legacy function missing")
	if legacy_id != main.SV_NONE {
		legacy, _ := sv_item_subroutine(&ctx.ast, legacy_id)
		testing.expect_value(t, len(legacy.ports), 2)
	}

	instance_id := u32(main.SV_NONE)
	for item in sv_items(&ctx, module) {
		if sv_kind(&ctx, item) == .Item_Instance { instance_id = item }
	}
	testing.expect(t, instance_id != main.SV_NONE, "instance missing")
	if instance_id != main.SV_NONE {
		instance, _ := sv_item_instance(&ctx.ast, instance_id)
		testing.expect_value(t, len(instance.port_conns), 2)
	}

	nonansi := sv_module(t, &ctx, "nonansi")
	testing.expect_value(t, len(sv_ports(&ctx, nonansi)), 2)

	dimports := sv_module(t, &ctx, "dimports")
	dim_a := sv_find_port(t, &ctx, dimports, "a")
	testing.expect_value(t, len(dim_a.unpacked_dims), 1)
}

@(test)
test_sv_comments_and_attributes :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"// top comment",
		"/* block",
		"   comment */",
		"(* keep /* inner */ = \"true\" *) module trivia (",
		"  (* mark_debug = \"true\" *) input logic a,",
		"  output logic b",
		");",
		"  // declaration comment",
		"  (* dont_touch = \"yes\" *) wire w;",
		"  assign b = a; // trailing comment",
		"  always @(*) begin",
		"    // after atstar",
		"    b = a;",
		"  end",
		"endmodule",
	)
	sv_test_parse(&ctx, source, "sv_trivia.sv")

	module := sv_module(t, &ctx, "trivia")
	testing.expect_value(t, len(sv_ports(&ctx, module)), 2)

	testing.expect_value(t, len(ctx.ast.comments), 6)
	testing.expect_value(t, ctx.ast.comments[0].text, "// top comment")
	testing.expect(t, ctx.ast.comments[1].is_block, "second comment should be a block comment")
	testing.expect(t, strings.contains(ctx.ast.comments[1].text, "block"), "block comment text")
	testing.expect(t, strings.contains(ctx.ast.comments[2].text, "inner"), "attribute body comment text")
	testing.expect(t, strings.contains(ctx.ast.comments[4].text, "trailing"), "trailing comment text")
	testing.expect(t, strings.contains(ctx.ast.comments[5].text, "atstar"), "comment after @(*) text")
	testing.expect_value(t, ctx.ast.comments[0].path, "sv_trivia.sv")
	testing.expect(t, ctx.ast.comments[0].line > 0, "comment line number")

	testing.expect_value(t, len(ctx.ast.attributes), 3)
	testing.expect_value(t, ctx.ast.attributes[0].text, "(* keep /* inner */ = \"true\" *)")
	testing.expect(t, strings.contains(ctx.ast.attributes[1].text, "mark_debug"), "port attribute text")
	testing.expect(t, strings.contains(ctx.ast.attributes[2].text, "dont_touch"), "declaration attribute text")
	testing.expect_value(t, ctx.ast.attributes[0].path, "sv_trivia.sv")
	testing.expect(t, ctx.ast.attributes[0].owner_line >= ctx.ast.attributes[0].line, "attribute owner line")
}

@(test)
test_sv_parser_asic_subset_syntax :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"typedef enum fwd_e;",
		"typedef struct fwd_s;",
		"typedef union fwd_u;",
		"typedef fwd_t;",
		"typedef enum { FWD_A, FWD_B } fwd_e;",
		"typedef struct packed unsigned { bit [3:0] lo; bit [3:0] hi; } fwd_s;",
		"typedef union { logic a; logic b; } fwd_u;",
		"typedef int fwd_t;",
		"module top(input clk, output reg [7:0] q);",
		"  tri1 scalared [7:0] bus;",
		"  tri vectored [7:0] data;",
		"  initial begin",
		"    q = 8'd0;",
		"    q <<<= 1;",
		"    q >>>= 1;",
		"  end",
		"endmodule",
	)
	sv_test_parse(&ctx, source)
	testing.expect_value(t, len(ctx.ast.modules), 1)
	testing.expect(t, ctx.ast.type_names["fwd_s"], "forward struct typedef")
	testing.expect(t, ctx.ast.type_names["fwd_u"], "forward union typedef")
	testing.expect(t, ctx.ast.type_names["fwd_e"], "forward enum typedef")
	testing.expect(t, ctx.ast.type_names["fwd_t"], "bare forward typedef")

	forward_count := 0
	for item in main.sv_children(&ctx.ast, ctx.ast.items) {
		if sv_kind(&ctx, item) != .Item_TypeDecl { continue }
		decl, _ := sv_item_type_decl(&ctx.ast, item)
		if decl.is_forward { forward_count += 1 }
	}
	testing.expect_value(t, forward_count, 4)
}

// ---------------------------------------------------------------------------------------
// Flat store: nodes crossing the fixed-size chunk boundary stay addressable
// ---------------------------------------------------------------------------------------

@(test)
test_sv_flat_chunk_boundaries :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "module many;\n")
	for i in 0 ..< 2500 {
		fmt.sbprintf(&b, "  wire w%d;\n", i)
	}
	strings.write_string(&b, "  assign tail = w2499;\nendmodule\n")
	sv_test_parse(&ctx, strings.to_string(b))

	testing.expectf(t, int(ctx.ast.node_count) > main.SV_CHUNK_SIZE, "expected more than %d nodes, got %d", main.SV_CHUNK_SIZE, ctx.ast.node_count)

	module := sv_module(t, &ctx, "many")
	_, last_decl := sv_find_decl(t, &ctx, module, "w2499")
	testing.expect_value(t, last_decl.net_type, main.SVNetType.WIRE)
	testing.expect_value(t, sv_declarator(&ctx.ast, last_decl.declarators[0]).name, "w2499")

	rhs, found := sv_assign_rhs(t, &ctx, module, "tail")
	testing.expect(t, found, "continuous assign across the chunk boundary missing")
	if found {
		name, is_ident := sv_expr_ident(&ctx.ast, rhs)
		testing.expect(t, is_ident && name == "w2499", "identifier payload across the chunk boundary")
	}
}

// Long child lists spill out of the parser's per-depth inline slots. The
// overflow must be reset when that depth is reused, otherwise the next list at
// the same depth reads stale entries from the previous one.
@(test)
test_sv_list_scratch_reuse :: proc(t: ^testing.T) {
	ctx: SVTestContext
	sv_test_begin(&ctx)
	defer virtual.arena_destroy(&ctx.arena)

	source := sv_src(
		"module m;",
		"  logic [7:0] a, y0, y1;",
		"  assign y0 = {a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[0]};",
		"  assign y1 = {a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[0], a[1]};",
		"endmodule",
	)
	module := sv_single_module(t, &ctx, source)

	cases := [?]struct {
		name: string,
		bit:  u32,
	}{{"y0", 0}, {"y1", 1}}
	for c in cases {
		rhs, ok := sv_assign_rhs(t, &ctx, module, c.name)
		if !ok { continue }
		parts, count, concat_ok := sv_expr_concat(&ctx.ast, rhs)
		testing.expectf(t, concat_ok, "%s: expected a concatenation", c.name)
		if !concat_ok { continue }
		testing.expectf(t, len(parts) == 9, "%s: expected 9 part ids, got %d", c.name, len(parts))
		if len(parts) != 9 { continue }
		// The ninth entry is the first one in the overflow buffer; a stale
		// overflow would surface an entry from the previous concatenation here.
		_, select_parts, select_ok := sv_select(t, &ctx, parts[8])
		testing.expectf(t, select_ok && len(select_parts) == 1, "%s: ninth part should be a bit select", c.name)
		if select_ok && len(select_parts) == 1 {
			part := sv_select_part(&ctx.ast, select_parts[0])
			testing.expect_value(t, part.kind, main.SVSelectKind.BIT)
			num := sv_number(t, &ctx, part.first)
			testing.expectf(t, num.value == u64(c.bit), "%s: expected bit %d", c.name, c.bit)
		}
	}
}
