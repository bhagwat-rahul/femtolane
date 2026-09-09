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
	gate_netlist_filepath, liberty_filepath, lef_filepath: string
	if len(args) > 1 && args[1] == "lexgraph" {
		gate_netlist_filepath = args[2] if len(args) >= 3 else ""
		liberty_filepath = args[3] if len(args) >= 4 else ""
		lef_filepath = args[4] if len(args) >= 5 else ""
	}

	// Read and construct Lef Data
	lef_database := lef_create_new_database(core_db_allocator)
	lef_read_file_into_database(lef_filepath, core_db_allocator, &lef_database)

	// Read and construct Liberty Data
	// TODO(rahul): Liberty data pointer allocates inside hypergraph cells, make this on demand and controllable

	// Read gate level netlist and construct hypergraph
	lex_gate_level_netlist_and_create_hypergraph(
		liberty_filepath = liberty_filepath,
		lef_filepath = lef_filepath,
		gate_netlist_path = gate_netlist_filepath,
		lex_graph_arena_allocator = core_db_allocator,
	)
}
