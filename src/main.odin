// Main entry-point
package main
import "core:fmt"
import "core:os"

main :: proc() {
	fmt.println("Femtolane!")
	args := os.args
	if len(args) <= 2 {
		fmt.println("TODO(rahul): no arg provided so we will run the gui for now")
		run_gui()
	} else {
		fmt.println("TODO(rahul): Handle args here")
	}
}
