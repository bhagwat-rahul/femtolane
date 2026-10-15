package main

// We should have the concept of multiple pdk's as an adk to model 3dIC and chiplets + MPGA type stuff.
// Multiple PDKs all in one package and how their physical characteristics interact with each other.

// for reference:- https://github.com/IHP-GmbH/IHP-Open-ADK
AssemblyDesignKit :: struct {
	name:       string,
	child_pdks: []string, // this should be array of pdk's
	// other interconnect, adapters etc. related metadata
}
