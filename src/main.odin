// Main entry-point
package main
import "core:fmt"
import "core:os"

main :: proc() {
	args := os.args
	if len(args) <= 2 {
		fmt.println("TODO(rahul): no arg provided so we will run the gui for now")
		run_gui()
	} else {
		if args[2] == "lexgraph" {
			gl_netlist_path := args[3] // Gate level netlist
			fmt.println("Converting netlist:-", gl_netlist_path, "to hypergraph")
			lexGraphNetlist(gl_netlist_path)
		} else {
			fmt.println("TODO(rahul): You entered an unsupported arg, this should show help menu")
		}
	}
}
