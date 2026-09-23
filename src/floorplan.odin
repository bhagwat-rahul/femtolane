package main

FloorplanConfig :: struct {
	height, width:             LefDistance,
	utilization, aspect_ratio: f64, // normalise as % from 0-1
}

Floorplan :: struct {
	height, width:                                   LefDistance,
	io_placement, macro_placment, stdcell_placement: LefDistance, // maybe lefcoord
}

PowerDomanConfig :: struct {}

create_power_domains :: proc(pdn_config: PowerDomanConfig) -> (power_domain_lef: string) {
	power_domain_lef = "lef floorplan string"
	return power_domain_lef
}

generate_floorplan :: proc(config: ^FloorplanConfig) -> (floorplan: Floorplan) {
	floorplan = {
		height = 0,
		width  = 0,
	}
	return floorplan
}

floorplanning_macro_placement :: proc(database: CoreDatabase) {
	// TODO(rahul): iterate over all instances in netlists, ones that have a macro lef class of block will be placed here, pads will be placed after, and core are just stdcell type stuff for during pnr (unless you can lef abstract a bunch of core into one lef blackbox)
	for instance in database.netlist_data.hypergraph.instances {  }
}
