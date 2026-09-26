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

	final := run_flow(
		{
			"/Users/rahulbhagwat/Documents/git/personal/fromthetransistor-rahul/section-3/riscv/common/",
			"/Users/rahulbhagwat/Documents/git/personal/fromthetransistor-rahul/section-3/riscv/src/",
			"/Users/rahulbhagwat/Documents/git/work/tinyeda/femtolane/.references/test-data/gt2n",
		},
		"riscv",
	)
}
