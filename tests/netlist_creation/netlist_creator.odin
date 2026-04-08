package netlist_creator

import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:strings"

run_yosys :: proc(
	filepath: string,
	lib_file: string,
	top_module: string,
	yosys_tcl_script_filepath: string,
) -> string {
	directory, filename := slashpath.split(filepath)
	outfile := fmt.tprintf("%s.%s.netlist.v", directory, strings.trim_suffix(filename, ".v")) // '/path/adder.v' becomes '/path/.adder.netlist.v'
	yosys_proc: os.Process_Desc = {
		command = {"yosys", "-c", yosys_tcl_script_filepath},
		env     = {
			fmt.tprintf("INPUT_RTL_FILE=%v", filepath),
			fmt.tprintf("TOP_MODULE=%v", top_module),
			fmt.tprintf("LIB_FILE=%v", lib_file),
			fmt.tprintf("OUTPUT_NETLIST=%v", outfile),
		},
	}
	state, stdout, stderr, err := os.process_exec(yosys_proc, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	fmt.println("STDOUT\n", string(stdout))
	ensure(err == nil, fmt.tprintln("SPAWN ERROR:", err))
	ensure(state.exit_code == 0, fmt.tprintfln("YOSYS FAILED:\n%s", stderr))
	return outfile
}

main :: proc() {
	SKY130A_PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A"
	SKY130B_PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130B"
	LIBFILE_CORNER_25C_1V80 := "/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib" // 25C and 1.8V corner libfile
	LEF_FILE :: "/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef"
	TLEF_FILE :: "/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef"
	sky130a_liberty := fmt.tprintf("%v%v", SKY130A_PDK_ROOT, LIBFILE_CORNER_25C_1V80)
	sky130a_lef := fmt.tprintf("%v%v", SKY130A_PDK_ROOT, LEF_FILE)
	sky130a_tlef := fmt.tprintf("%v%v", SKY130A_PDK_ROOT, TLEF_FILE)
	ensure(os.exists(sky130a_liberty), "liberty file not found")
	ensure(os.exists(sky130a_lef), "lef file not found")
	ensure(os.exists(sky130a_tlef), "tlef file not found")

	run_yosys(
		filepath = "adder/adder.v",
		lib_file = sky130a_liberty,
		top_module = "adder",
		yosys_tcl_script_filepath = "netlist_creator.tcl",
	)
}
