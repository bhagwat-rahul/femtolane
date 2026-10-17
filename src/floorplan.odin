package main

FloorplanConfig :: struct {
	total_height, total_width:      LefDistance,
	core_utilization, aspect_ratio: f64, // normalise as % from 0-1
}

Floorplan :: struct {
	total_height, total_width, core_height, core_width: LefDistance,
	io_placement, macro_placment, stdcell_placement:    LefDistance, // maybe lefcoord
}

generate_floorplan :: proc(config: ^FloorplanConfig) -> (floorplan: Floorplan) {
	floorplan = {
		total_height = 0,
		total_width  = 0,
	}
	total_area := config.total_height * config.total_width
	utilization := clamp(config.core_utilization, 0.0, 1.0)
	core_placement_area := f64(total_area) * utilization
	return floorplan
}

floorplanning_macro_placement :: proc(database: CoreDatabase) {
	// TODO(rahul): iterate over all instances in netlists, ones that have a macro lef class of block will be placed here, pads will be placed after, and core are just stdcell type stuff for during pnr (unless you can lef abstract a bunch of core into one lef blackbox)
	for instance in database.netlist_data.hypergraph.instances {  }
}
