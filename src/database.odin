package main

CoreDatabase :: struct {
	netlist_data: NetlistDatabase,
	lef_data:     LefDatabase,
	liberty_data: [dynamic]LibertyLibrary,
}

NetlistDatabase :: struct {
	filepath:   string,
	hypergraph: NetlistHyperGraph,
}

CoreCell :: struct {
	name:               string, // canonical cell name across lef, lib, netlist, etc.
	liberty_properties: LibertyCell,
	lef_properties:     LefMacro,
}
