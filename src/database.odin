package main

CoreDatabase :: struct {
	netlist_data : NetlistDatabase,
	lef_data     : LefDatabase,
	liberty_data : LibertyDatabase,
}

LibertyDatabase :: struct {
	library  : LibertyLibrary,
	cells    : [dynamic]LibertyCell,
	pins     : [dynamic]LibertyPin,
	nodes    : [dynamic]LibertyNode,
}

NetlistDatabase :: struct {
	filepath   : string,
	hypergraph : NetlistHyperGraph,
}
