package main

import "core:fmt"
import "core:os"

// uses yosys to convert RTL to gate netlist (synthesis), will use our own later, maybe with an option for single pass rtl->hypergraph using gl netlist as just a debug artifact?
convert_rtl_to_gate_netlist :: proc(synthesis_script: string) {
	yosys_proc: os.Process_Desc = {
		command = {"yosys", "-p", synthesis_script},
	}
	state, stdout, stderr, err := os.process_exec(yosys_proc, context.temp_allocator)
	fmt.println("STDOUT\n", string(stdout))
	ensure(err == nil, fmt.tprintln("SPAWN ERROR:", err))
	ensure(state.exit_code == 0, fmt.tprintfln("YOSYS FAILED:\n%s", stderr))
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
