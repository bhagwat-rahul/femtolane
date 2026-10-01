package main

// read upf (unified power format files), to understand the different voltage/power domains on chip, this is pretty similar to sdc

UPFDatabase :: struct {
	src:            string, // path of the upf file this data came from
	power_domains:  [dynamic]PowerDomain,
	power_supplies: [dynamic]PowerSupply,
}

// upf_parse :: proc() {  }
