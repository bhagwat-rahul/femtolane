package main

import "core:fmt"
import "core:mem"
import "core:os"

// TODO(rahul): should i parse into struct and write it out? why not single pass parse into hypergraph? isnt gl netlist just a version of the hypergraph?
GateNetlist :: struct {}

rtl_parse_hdl_to_gate_netlist :: proc(hdl_filepath: string, allocator: mem.Allocator) {
	hdl_bytes, ok := os.read_entire_file_from_path(hdl_filepath, context.allocator)
	ensure(ok == nil, fmt.tprintf("Error %s reading file %s", ok, hdl_filepath))

	rtl_lexer := Lexer {
		src      = hdl_bytes,
		idx      = 0,
		newlines = 0,
		filepath = hdl_filepath,
	}

	for byte in rtl_lexer.src {
		switch byte {
		case: lexer_panic(&rtl_lexer, "Unkown identifier")
		}
	}
}
