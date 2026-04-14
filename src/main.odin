// Main entry-point
package main
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"

main :: proc() {
	args := os.args
	if len(args) <= 1 {
		fmt.println("TODO(rahul): no arg provided so we will run the gui for now")
		run_gui()
	} else {
		if args[1] == "lexgraph" {

			ensure(len(args) >= 3, "Please provide a path to a gate level verilog netlist")
			gl_netlist_path := args[2]
			lex_graph_arena: virtual.Arena
			ensure(virtual.arena_init_growing(&lex_graph_arena) == nil, "Error init'ing lex_graph_arena")
			lex_graph_arena_allocator := virtual.arena_allocator(&lex_graph_arena)
			defer virtual.arena_destroy(&lex_graph_arena)
			lex_gate_level_netlist_and_create_hypergraph(gl_netlist_path, lex_graph_arena_allocator)

		} else { fmt.println("TODO(rahul): Unsupported arg, this should show help menu") }
	}
}
