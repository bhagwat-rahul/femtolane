package netlist_creator

import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:strings"

run_yosys :: proc(filepath: string, liberty_file: string) {
	// TODO(rahul): use the ys script instead of raw yosys cmd
	YosysScriptFile :: "netlist_creator.ys"
	synth_script, _ := os.read_entire_file_from_path(YosysScriptFile, context.allocator)
	directory, filename := slashpath.split(filepath)
	outfile := fmt.tprintf("%s.%s.netlist.v", directory, strings.trim_suffix(filename, ".v"))
	yosys_proc: os.Process_Desc = {
		working_dir = "",
		command     = {"yosys", "-p", string(synth_script)},
		env         = {
			"liberty_filename=/Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib",
		},
	}
	state, stdout, stderr, err := os.process_exec(yosys_proc, context.allocator)
	fmt.println("EXIT:", state)
	fmt.println("YOSYS STDOUT:\n", string(stdout))
	fmt.println("YOSYS STDERR:\n", string(stderr))
	if err != nil {
		fmt.println("SPAWN ERROR:", err)
	}
}

main :: proc() {
	// From args/user input, get pdk_path (or path to relevant files), using this, gen dotfile netlists
	liberty_file :: "/Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib"
	run_yosys("adder/adder.v", liberty_file)
}
