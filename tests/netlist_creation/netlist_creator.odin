package netlist_creator

import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:strings"

run_yosys :: proc(filepath: string, lib_files: string, top_module: string) {
	YosysScriptFile :: "netlist_creator.tcl"
	directory, filename := slashpath.split(filepath)
	outfile := fmt.tprintf("%s.%s.netlist.v", directory, strings.trim_suffix(filename, ".v"))
	yosys_proc: os.Process_Desc = {
		command = {"yosys", "-c", YosysScriptFile},
		env     = {
			fmt.tprintf("INPUT_RTL_FILE=%s", filepath),
			fmt.tprintf("TOP_MODULE=%s", top_module),
			fmt.tprintf("LIB_FILES=%s", lib_files),
			fmt.tprintf("OUTPUT_NETLIST=%s", outfile),
		},
	}
	state, stdout, stderr, err := os.process_exec(yosys_proc, context.allocator)
	fmt.println("STDOUT\n", string(stdout))
	ensure(err == nil, fmt.tprintf("SPAWN ERROR:%s", err))
	ensure(state.exit_code == 0, fmt.tprintf("YOSYS FAILED:\n%s", string(stderr)))
}

main :: proc() {
	SKY130A_PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A"
	SKY130B_PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130B"
	sky130a_liberty := fmt.tprintf(
		"%v/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib",
		SKY130A_PDK_ROOT,
	) // Typical corner at 25C and 1.8V
	sky130a_lef := fmt.tprintf(
		"%v/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef",
		SKY130A_PDK_ROOT,
	)
	sky130a_tlef := fmt.tprintf(
		"%v/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef",
		SKY130A_PDK_ROOT,
	)
	ensure(os.exists(sky130a_liberty), "liberty file not found")
	ensure(os.exists(sky130a_lef), "lef file not found")
	ensure(os.exists(sky130a_tlef), "tlef file not found")

	run_yosys("adder/adder.v", sky130a_liberty, "adder")
}
