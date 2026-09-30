package main

// read upf (unified power format files), to understand the different voltage/power domains on chip, this is pretty similar to sdc

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

UPFDatabase :: struct {
	src:            string, // path of the upf file this data came from
	power_domains:  [dynamic]PowerDomain,
	power_supplies: [dynamic]PowerSupply,
}

// upf_parse :: proc() {  }
