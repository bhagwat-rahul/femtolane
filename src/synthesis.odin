package main

import "core:fmt"
import "core:os"
import "core:path/slashpath"

// uses yosys to convert RTL to gate netlist (synthesis), will use our own later, maybe with an option for single pass rtl->hypergraph using gl netlist as just a debug artifact?
convert_rtl_to_gate_netlist :: proc(rtl_filepath: string, lib_file: string, top_module: string, yosys_tcl_script_filepath: string) -> (gate_netlist_filepath : string) {

	resolved_rtl_path := rtl_filepath
	if len(resolved_rtl_path) == 0 {
		fmt.println("Please select a liberty file")
		resolved_rtl_path = pick_path(File_Picker_Request{mode = .Open_File, title = "Select Gate-Level Netlist"})
	}
	ensure(len(resolved_rtl_path) > 0, "Program terminated as you did not select a liberty file")

	directory, filename := slashpath.split(resolved_rtl_path)
	// change '/path/adder.v' to '/path/.netlist.adder.v' (dotfile cz we gitignore those)
	gate_netlist_filepath = fmt.tprint(directory, "netlist", filename, sep = ".")
	yosys_proc: os.Process_Desc = {
		command = {"yosys", "-c", yosys_tcl_script_filepath},
		env     = {
			fmt.tprintf("INPUT_RTL_FILE=%v", resolved_rtl_path),
			fmt.tprintf("TOP_MODULE=%v", top_module),
			fmt.tprintf("LIB_FILE=%v", lib_file),
			fmt.tprintf("OUTPUT_NETLIST=%v", gate_netlist_filepath),
		},
	}
	state, stdout, stderr, err := os.process_exec(yosys_proc, context.temp_allocator)
	fmt.println("STDOUT\n", string(stdout))
	ensure(err == nil, fmt.tprintln("SPAWN ERROR:", err))
	ensure(state.exit_code == 0, fmt.tprintfln("YOSYS FAILED:\n%s", stderr))
	return gate_netlist_filepath
}


// Sample yosys_tcl_script; TODO(rahul): Maybe inline later?
/*
yosys -import

set input_rtl_file $::env(INPUT_RTL_FILE)
set top_module $::env(TOP_MODULE)
set lib_file $::env(LIB_FILE)
set output_netlist $::env(OUTPUT_NETLIST)

puts "Synthesizing $input_rtl_file with top $top_module; Using liberty $lib_file; Writing mapped netlist to $output_netlist"

read_liberty -lib $lib_file
read_verilog $input_rtl_file
hierarchy -check -top $top_module

# Lower behavioral RTL into Yosys' internal generic netlist.
synth -top $top_module

# Map sequential logic first, then map combinational logic into stdcells.
dfflibmap -liberty $lib_file
abc -liberty $lib_file

setundef -zero
clean -purge
check
stat -liberty $lib_file

write_verilog -noattr -noexpr -nodec $output_netlist
*/
