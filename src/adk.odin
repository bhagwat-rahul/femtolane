package main

// We should have the concept of multiple pdk's as an adk to model 3dIC and chiplets + MPGA type stuff.
// Multiple PDKs all in one package and how their physical characteristics interact with each other.

// for reference:- https://github.com/IHP-GmbH/IHP-Open-ADK
AssemblyDesignKit :: struct {
	name:        string,
	child_pdks:  []AssemblyDesignKitChildPdk, // this should be array of pdk's
	adk_ruleset: string, // definitely needs to be something else
	// other interconnect, adapters etc. related metadata
}

AssemblyDesignKitChildPdk :: struct {
	name, path: string,
	pdk_type:   AssemblyDesignKitPdkType,
}

AssemblyDesignKitPdkType :: enum {
	MAIN,
	INTERCONNECT,
	CHIPLET,
	INTERPOSER,
}
