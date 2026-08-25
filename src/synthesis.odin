package main

import "core:os"
import "core:fmt"

// convert rtl code to a gate level netlist, currently using yosys, we will do this ourselves soon
run_synthesis :: proc(rtl_filepaths: []string, liberty_file: string, top_module: string, timing_constraints_filepath: string, output_filepath: string = "") -> (output_gate_netlist_filepath: string) {
	output_gate_netlist_filepath = output_filepath if output_filepath != "" else fmt.tprint(top_module, ".gatenetlist.v")
	process_desc: os.Process_Desc = {
    command = {
        "yosys", "-p",
        fmt.tprintf(
            "read_liberty -lib %v; read_verilog %v; hierarchy -top %v; synth -top %v; dfflibmap -liberty %v; abc -liberty %v; write_verilog %v",
            liberty_file, rtl_filepaths[0], top_module, top_module, liberty_file, liberty_file, output_gate_netlist_filepath,
        ),
    },
    stdout = nil,
    stderr = nil,
	}
	synthesis_process, process_start_err := os.process_start(process_desc)
	ensure(process_start_err == nil, "Error spawning synthesis process")
	process_state, process_run_err := os.process_wait(synthesis_process)
	ensure(process_run_err == nil, "Error running synthesis process")
	if process_state.exit_code != 0 {
		panic("Error running synth") // TODO(rahul): not panic do something smarter here
	}
	return output_gate_netlist_filepath
}
