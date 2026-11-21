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

// Tests the frontend flow that goes from behavioral RTL -> Gate Level Netlist.
// TODO(rahul): restore the full flow test once the in-tree synthesizer replaces yosys;
// convert_rtl_to_gate_netlist now takes a complete yosys script.
@(test)
test_netlist_creation :: proc(_: ^testing.T) {
	synthesis_script := "" // TODO(rahul): pass the real yosys script path
	main.convert_rtl_to_gate_netlist(synthesis_script)
}

@(test)
test_pdk_loader :: proc(_: ^testing.T) {
	os.set_env("PDK_ROOT", PDK_ROOT)
	main.openpdk_load()
}

@(test)
test_liberty_cell_creation :: proc(_: ^testing.T) {
	liberty_cell_creation_arena: virtual.Arena
	liberty_cell_creation_allocator := test_create_arena_allocator(&liberty_cell_creation_arena)
	defer virtual.arena_destroy(&liberty_cell_creation_arena)
	libraries := make([dynamic]main.LibertyLibrary, liberty_cell_creation_allocator)
	library := main.liberty_read_file(
		LIBERTY_FILEPATH,
		liberty_cell_creation_allocator,
		process_corner = main.LibertyProcessCorner("tt"),
	)
	append(&libraries, library)

	assert(len(libraries) == 1)
	assert(libraries[0].name == "gt2_6t_w13_lvt_tt_0p7v25c")
	assert(libraries[0].pvt_corner.process_corner == "tt")
	assert(libraries[0].pvt_corner.temperature_celsius == 25)
	assert(libraries[0].pvt_corner.voltage_millivolts == 700)
	assert(len(libraries[0].cells) == 72)
	assert(libraries[0].cells[0].name == "gt2_6t_and2_x1_w13_lvt")
	assert(libraries[0].cells[0].area == 0.024192)
	assert(len(libraries[0].cells[0].pins) == 5)
	assert(libraries[0].cells[0].pins[4].name == "Y")
	assert(libraries[0].cells[0].pins[4].direction == "output")
	assert(libraries[0].cells[0].pins[4].function == "(A&B)")
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
