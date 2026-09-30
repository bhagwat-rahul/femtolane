package main

// do the things instructed by the upf file, create power domains, supplies, etc

pdn_create_power_domains :: proc(pdn_config: PowerDomanConfig) -> (power_domain_lef: string) {
	power_domain_lef = "lef floorplan string"
	return power_domain_lef
}
