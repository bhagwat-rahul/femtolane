package main

FloorplanConfig :: struct {
	height, width:             LefDistance,
	utilization, aspect_ratio: f64, // normalise as % from 0-1
}

Floorplan :: struct {
	height, width: LefDistance,
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
