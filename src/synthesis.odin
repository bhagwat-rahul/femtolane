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

// TODO(rahul): yosys currently outputs some helpful libfile info in attributes like capacitance etc. we can extend this idea a lot by emitting such attributes and using them in the gui representation for engineers to more easily diagnose errors.

// TODO(rahul): a good way to think about yosys to IR conversion is in tinygrads graph -> UOps conversion. tinygrad has somewhat of a fixed IR (we won't cz stdcell pin functions can be kind of arbitrary [or can they?]), so we need to go about things differently but some ideas still apply.

/*
// start synthesis helper functions; for when we switch to our own flow from yosys

synthesis_evaluate_expression_to_cell :: proc(
	expression: string,
	/* TODO(rahul): maybe have a better type than string for matching expressions with pin functions, not sure how to do with cascading */
) -> (
	cell: LibertyCell,
) {
	return cell
}

// end synthesis helper functions
*/
