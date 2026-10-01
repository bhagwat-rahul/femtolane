package main

// do the things instructed by the upf file, create power domains, supplies, etc

PowerDomain :: struct {
	name:     string,
	voltage:  f64, // maybe normalise? probably not required though cz only some power domains
	elements: []Instance, // instances that belong to this power domain, this may not have to ref instance from gl netlist?
	supply:   ^PowerSupply, // what power supply this is associated with
}

PowerSupply :: struct {
	name:    string,
	voltage: f64,
}

// TODO(rahul): possibly dont need both upf db and pdn config struct, can collapse, evaluate later (maybe upf db can be a builder/staging struct?)
PowerDomanConfig :: struct {
	config_src_path: []string, // upf file(s) this config came from
	power_domains:   []PowerDomain,
}

pdn_create_power_domains :: proc(pdn_config: PowerDomanConfig) -> (power_domain_lef: string) {
	power_domain_lef = "lef floorplan string"
	return power_domain_lef
}
