// Main entry-point
package main
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"

main :: proc() {

	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	defer free_all(context.temp_allocator)

	core_db_arena: virtual.Arena
	ensure(virtual.arena_init_growing(&core_db_arena) == nil, "Error init'ing lex_graph_arena")
	core_db_allocator := virtual.arena_allocator(&core_db_arena)
	defer virtual.arena_destroy(&core_db_arena)

	args := os.args
	rtl_filepath, liberty_filepath, lef_filepath, yosys_synthesis_tcl_filepath, top_module, techlef_filepath: string
	if len(args) > 1 && args[1] == "lexgraph" {
		rtl_filepath = args[2] if len(args) >= 3 else ""
		yosys_synthesis_tcl_filepath = args[3] if len(args) >= 4 else ""
		top_module = args[4] if len(args) >= 5 else ""
		liberty_filepath = args[5] if len(args) >= 6 else ""
		techlef_filepath = args[6] if len(args) >= 7 else ""
		lef_filepath = args[7] if len(args) >= 8 else ""
	}

	// Frontend synthesis RTL -> GL netlist
	gate_netlist_filepath := convert_rtl_to_gate_netlist(
		rtl_filepath = rtl_filepath,
		lib_file = liberty_filepath,
		top_module = top_module,
		yosys_tcl_script_filepath = yosys_synthesis_tcl_filepath,
	)

	database := CoreDatabase {
		lef_data     = lef_create_new_database(core_db_allocator),
		liberty_data = make([dynamic]LibertyLibrary, core_db_allocator),
	}

	// Read and construct LEF data
	lef_read_file_into_database(techlef_filepath, core_db_allocator, &database.lef_data)
	lef_read_file_into_database(lef_filepath, core_db_allocator, &database.lef_data)

	// Read and construct Liberty data
	liberty_library := liberty_read_file(liberty_filepath, core_db_allocator)
	append(&database.liberty_data, liberty_library)

	// Read gate level netlist and construct hypergraph
	lex_gate_level_netlist_and_create_hypergraph(
		gate_netlist_path = gate_netlist_filepath,
		lex_graph_arena_allocator = core_db_allocator,
	)
}
