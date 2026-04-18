package tests

import main "../src"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "netlist_creation"

PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A"
LIBERTY_DIR :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"

// Tests the frontend yosys netlist creation flow that goes from behavioral RTL -> Gate Level Netlist
@(test)
test_netlist_creation :: proc(_: ^testing.T) {
	netlist_creation_test_arena: virtual.Arena
	ensure(virtual.arena_init_growing(&netlist_creation_test_arena) == nil)
	defer virtual.arena_destroy(&netlist_creation_test_arena)
	arena_allocator := virtual.arena_allocator(&netlist_creation_test_arena)
	sky130a_liberty := fmt.tprint(PDK_ROOT, "/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ff_100C_1v65.lib", sep = "")
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
	assert(read_err == nil, fmt.tprintln("file read error", read_err))
	lines, _ := strings.split_lines(string(outfile_src), arena_allocator)
	for line in lines {
		fields := strings.fields(line, arena_allocator)
		if len(fields) < 2 { continue }
		cell := fields[0]
		ensure(cell[0] != '$', fmt.tprintln("Non tech-mapped cell %s", cell))
	}
}

@(test)
test_pdk_loader :: proc(_: ^testing.T) {
	os.set_env("PDK_ROOT", PDK_ROOT)
	main.openpdk_load()
}

@(test)
test_lexGraph :: proc(_: ^testing.T) {
	// TODO(rahul): This test should NOT be this verbose, find better way to express, also fix mem leaks.
	netlist_paths: [dynamic]string
	NETLISTS_DIR :: "netlist_creation/" // relative path of where netlist folders are from test.odin

	design_dirs, design_dir_read_err := os.read_all_directory_by_path(NETLISTS_DIR, context.allocator)
	assert(design_dir_read_err == nil)

	for d in design_dirs {
		files, err := os.read_all_directory_by_path(d.fullpath, context.allocator)
		defer delete(files)
		for file in files {
			if strings.ends_with(file.name, ".netlist.v") {
				append(&netlist_paths, file.fullpath)
			}
		}
	}

	for n in netlist_paths {
		main.lex_gate_level_netlist_and_create_hypergraph(
			gate_netlist_path = n,
			liberty_filepath = LIBERTY_DIR,
			lex_graph_arena_allocator = context.allocator,
		)
	}

	defer delete(design_dirs)
	defer delete(netlist_paths)
}

@(test)
test_liberty_cell_creation :: proc(_: ^testing.T) {
	LIBERTY_DIR :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A/libs.ref/sky130_fd_sc_hd/lib/"
	lex_graph_arena: virtual.Arena
	ensure(virtual.arena_init_growing(&lex_graph_arena) == nil, "Error init'ing lex_graph_arena")
	lex_graph_arena_allocator := virtual.arena_allocator(&lex_graph_arena)
	defer virtual.arena_destroy(&lex_graph_arena)
	files, _ := os.read_all_directory_by_path(LIBERTY_DIR, lex_graph_arena_allocator)
	hgr := main.NetlistHyperGraph {
		instances         = make([dynamic]^main.Instance, lex_graph_arena_allocator),
		nets              = make([dynamic]^main.Net, lex_graph_arena_allocator),
		cells             = make([dynamic]^main.Cell, lex_graph_arena_allocator),
		cell_hash_map     = make(main.CellHashMap, lex_graph_arena_allocator),
		instance_hash_map = make(main.InstanceHashMap, lex_graph_arena_allocator),
		net_hash_map      = make(main.NetHashMap, lex_graph_arena_allocator),
	}
	for file in files {
		main.parse_liberty_create_cells_pins(liberty_filepath = file.fullpath, hgr = &hgr, alloc = lex_graph_arena_allocator)
		fmt.println(file.name, "done")
		fmt.println(len(hgr.cells))
	}
}
