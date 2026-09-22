package tests

import main "../src"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A"
LIBERTY_FILEPATH :: "/Users/rahulbhagwat/Documents/git/work/tinyeda/femtolane/.references/test-data/gt2n/lib/tt/gt2_6t_w13_lvt_tt_0p7v25c.lib"
TECHLEF_FILEPATH :: "/Users/rahulbhagwat/Documents/git/work/tinyeda/femtolane/.references/test-data/gt2n/techlib/gt2_tech.lef"
LEF_FILEPATH :: "/Users/rahulbhagwat/Documents/git/work/tinyeda/femtolane/.references/test-data/gt2n/lef/tt/gt2_6t_w31_lvt.lef"

// Create and return a growing arena allocator for use within tests
test_create_arena_allocator :: #force_inline proc(arena: ^virtual.Arena) -> mem.Allocator {
	ensure(virtual.arena_init_growing(arena) == nil)
	return virtual.arena_allocator(arena)
}

// Tests the frontend yosys netlist creation flow that goes from behavioral RTL -> Gate Level Netlist
@(test)
test_netlist_creation :: proc(_: ^testing.T) {
	netlist_creation_arena: virtual.Arena
	netlist_creation_allocator := test_create_arena_allocator(&netlist_creation_arena)
	defer virtual.arena_destroy(&netlist_creation_arena)
	sky130a_liberty := fmt.tprint(PDK_ROOT, "/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ff_100C_1v65.lib", sep = "")
	verilog_src := "netlist_creation/adder/adder.v"
	top := "adder"
	yosys_tcl_script_filepath := "" // TODO(rahul): fix
	outfile := main.convert_rtl_to_gate_netlist(
		rtl_filepath = verilog_src,
		lib_file = sky130a_liberty,
		top_module = top,
		yosys_tcl_script_filepath = yosys_tcl_script_filepath,
	)
	outfile_src, read_err := os.read_entire_file_from_path(outfile, netlist_creation_allocator)
	assert(read_err == nil, fmt.tprintln("file read error", read_err))
	lines, _ := strings.split_lines(string(outfile_src), netlist_creation_allocator)
	for line in lines {
		fields := strings.fields(line, netlist_creation_allocator)
		if len(fields) < 2 { continue }
		cell := fields[0]
		ensure(cell[0] != '$', fmt.tprintln("Non tech-mapped cell %s", cell)) // if first char is $ then unmapped
	}
}

@(test)
test_pdk_loader :: proc(_: ^testing.T) {
	os.set_env("PDK_ROOT", PDK_ROOT)
	main.openpdk_load()
}

@(test)
test_lexGraph :: proc(_: ^testing.T) {
	lex_graph_arena: virtual.Arena
	lex_graph_allocator := test_create_arena_allocator(&lex_graph_arena)
	defer virtual.arena_destroy(&lex_graph_arena)
	netlist_paths := make([dynamic]string, lex_graph_allocator)
	NETLISTS_DIR :: "/Users/rahulbhagwat/Documents/git/work/tinyeda/femtolane/tests/netlist_creation/"

	design_dirs, design_dir_read_err := os.read_all_directory_by_path(NETLISTS_DIR, lex_graph_allocator)
	ensure(design_dir_read_err == nil, fmt.tprint(design_dir_read_err))

	for dir in design_dirs {
		if dir.type != .Directory { break }
		files, err := os.read_all_directory_by_path(dir.fullpath, lex_graph_allocator)
		ensure(err == nil, fmt.tprint(err))
		for file in files { if strings.ends_with(file.name, ".netlist.v") { append(&netlist_paths, file.fullpath) } }
	}

	for netlist_path in netlist_paths {
		main.lex_gate_level_netlist_and_create_hypergraph(
			gate_netlist_path = netlist_path,
			lef_filepath = LEF_FILEPATH,
			liberty_filepath = LIBERTY_FILEPATH,
			lex_graph_arena_allocator = lex_graph_allocator,
		)
	}
}

@(test)
test_liberty_cell_creation :: proc(_: ^testing.T) {
	LIBERTY_DIR :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A/libs.ref/sky130_fd_sc_hd/lib/"
	liberty_cell_creation_arena: virtual.Arena
	liberty_cell_creation_allocator := test_create_arena_allocator(&liberty_cell_creation_arena)
	defer virtual.arena_destroy(&liberty_cell_creation_arena)
	files, _ := os.read_all_directory_by_path(LIBERTY_DIR, liberty_cell_creation_allocator)
	hgr := main.NetlistHyperGraph {
		instances         = make([dynamic]^main.Instance, liberty_cell_creation_allocator),
		nets              = make([dynamic]^main.Net, liberty_cell_creation_allocator),
		cells             = make([dynamic]^main.Cell, liberty_cell_creation_allocator),
		cell_hash_map     = make(main.CellHashMap, liberty_cell_creation_allocator),
		instance_hash_map = make(main.InstanceHashMap, liberty_cell_creation_allocator),
		net_hash_map      = make(main.NetHashMap, liberty_cell_creation_allocator),
	}
	for file in files {
		main.parse_liberty_create_cells_pins(liberty_filepath = file.fullpath, hgr = &hgr, alloc = liberty_cell_creation_allocator)
		fmt.println(file.name, "done")
		fmt.println(len(hgr.cells))
	}
}

@(test)
test_lef_parse :: proc(_: ^testing.T) {
	lef_parse_arena: virtual.Arena
	lef_parse_allocator := test_create_arena_allocator(&lef_parse_arena)
	defer virtual.arena_destroy(&lef_parse_arena)
	lef_database := main.lef_create_new_database(lef_parse_allocator)
	main.lef_read_file_into_database(TECHLEF_FILEPATH, lef_parse_allocator, &lef_database)
	main.lef_read_file_into_database(LEF_FILEPATH, lef_parse_allocator, &lef_database)
}
