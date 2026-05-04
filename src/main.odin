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

	lex_graph_arena: virtual.Arena
	ensure(virtual.arena_init_growing(&lex_graph_arena) == nil, "Error init'ing lex_graph_arena")
	lex_graph_arena_allocator := virtual.arena_allocator(&lex_graph_arena)
	defer virtual.arena_destroy(&lex_graph_arena)

	args := os.args
	gl_netlist_path := ""
	liberty_filepath := ""
	if len(args) > 1 && args[1] == "lexgraph" {
		gl_netlist_path = args[2] if len(args) >= 3 else ""
		liberty_filepath = args[3] if len(args) >= 4 else ""
	}
	lex_gate_level_netlist_and_create_hypergraph(
		liberty_filepath = liberty_filepath,
		gate_netlist_path = gl_netlist_path,
		lex_graph_arena_allocator = lex_graph_arena_allocator,
	)
}
