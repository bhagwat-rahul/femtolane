package main

import "core:mem"

// Commands that this tool can take / via gui or cli (some might just be thin wrappers around existing db funcs to keep api clean)

// TODO(rahul): add stuff to same hgr, or maintain a relationship
command_read_gate_netlist_to_hypergraph :: #force_inline proc(hdl_filepaths: []string, allocator: mem.Allocator) {
	for path in hdl_filepaths { lex_gate_level_netlist_and_create_hypergraph(path, allocator) }
}

command_read_liberty_into_db :: #force_inline proc(liberty_filepaths: []string, allocator: mem.Allocator) {
	for path in liberty_filepaths { liberty_read_file(path, allocator) }
}

command_write_netlist_hypergraph_to_json_file :: #force_inline proc(
	netlist_hypergraph: NetlistHyperGraph,
	outfilepath: string,
	allocator: mem.Allocator = context.allocator,
) {
	json_marshal_data_and_write_json_file(filepath = outfilepath, data = netlist_hypergraph, allocator = allocator)
}
