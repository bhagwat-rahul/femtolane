package tests

import main "../src"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "netlist_creation"

PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A"

// Tests the frontend yosys netlist creation flow that goes from behavioral RTL -> Gate Level Netlist
@(test)
test_netlist_creation :: proc(_: ^testing.T) {
	netlist_creation_test_arena: virtual.Arena
	ensure(virtual.arena_init_growing(&netlist_creation_test_arena) == nil)
	defer virtual.arena_destroy(&netlist_creation_test_arena)
	arena_allocator := virtual.arena_allocator(&netlist_creation_test_arena)
	sky130a_liberty := fmt.tprint(
		PDK_ROOT,
		"/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ff_100C_1v65.lib",
		sep = "",
	)
	verilog_src := "netlist_creation/adder/adder.v"
	top := "adder"
	yosys_tcl_script_filepath := "netlist_creation/netlist_creator.tcl"
	outfile := netlist_creation.run_yosys(
		filepath = verilog_src,
		lib_file = sky130a_liberty,
		top_module = top,
		yosys_tcl_script_filepath = yosys_tcl_script_filepath,
	)
	outfile_src, read_err := os.read_entire_file_from_path(outfile, arena_allocator)
	assert(read_err == nil, fmt.tprintfln("file read error %v", read_err))
	lines, _ := strings.split_lines(string(outfile_src), arena_allocator)
	for line in lines {
		fields := strings.fields(line, arena_allocator)
		if len(fields) < 2 { continue }
		cell := fields[0]
		ensure(cell[0] != '$', fmt.tprintfln("Non tech-mapped cell %s", cell))
	}
}

@(test)
test_pdk_loader :: proc(_: ^testing.T) {

	os.set_env("PDK_ROOT", PDK_ROOT)
	main.openpdk_load()
}

@(test)
test_lexGraph :: proc(_: ^testing.T) {
	main.lexGraphNetlist("tests/netlist_creation/adder/.adder.netlist.v")
}
