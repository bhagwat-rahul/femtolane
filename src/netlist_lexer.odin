/*
# Femtolane Lexer
Fast, single-pass 'lexer' to convert verilog netlists into a hypergraph of nets representation.
We only care about the ASIC synthesizable gate level RTL version of verilog since this will process things after they have gone through a yosys style frontend.
This representation will then directly be used along with sdc timing constraints, etc. to do floorplan, place and route for a digital ASIC.
We want this internal graph representation to be fully GUI viewable and debuggable, so things map to their source files using attributes from the netlist.
This has to be performant, not just in runtime but in the way that we represent this graph since that is what will be read from millions++ of times for PnR.
*/

package main
