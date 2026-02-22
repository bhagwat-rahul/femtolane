package femtolane

import "core:fmt"
import "core:os"

/*
NOTE(rahul):We need to use different data layouts for parse/lex vs PnR.
For PnR, use a more computation friendly layout with id's & no strings/pointer chasing.
These structs still need to be a good starting ground to lower down into PnR db structs but be desiged for good parse/ast-building of netlist.
*/

AstNet :: struct {
	name:     string,
	pins:     [dynamic]AstPinRef,
	is_const: bool,
}

// Which cell_type and it's prop's
AstMaster :: struct {
	name:      string, // Cell type name in PDK
	pins:      []string, // valid pin names
	width_nm:  u32, // Width in nanometres
	height_nm: u32, // Height in nanometres
}

// One standard cell
AstInstance :: struct {
	name:    string, // unique instance ID in design
	master:  ^AstMaster, // which cell_type, eg. gf180mcu_fd_sc_mcu7t5v0__nand2_1
	pin_map: map[string]^AstNet, // which nets connect to it's pins eg. A → net1, B → net2, Y → net3
	is_io:   bool, // special instance anchored to boundary
}

AstPort :: struct {
	name: string,
	net:  ^AstNet,
}

AstPinRef :: struct {
	inst: ^AstInstance, // which instance
	pin:  string, // pin name on that instance
}


// Parse both types of wires and add into Ast_Net:-
// wire _105_;
// wire [31:0] _106_;
// TODO(rahul): This is just a starting point, eventually consolidate and don't have diff proc for wire vs other things
parse_wires_from_netlist :: proc(filepath: string) {
	netlist_data, netlist_read_err := os.read_entire_file_from_path(filepath, context.allocator)
	fmt.println(netlist_read_err)
	ensure(netlist_read_err == nil && netlist_data != nil, "Netlist read errored or empty data")
}

// NOTE(rahul): Compiler directives, netlist has compiler directives like src
// which let us know where a module comes from (what part of parent rtl, filename & line)
// We need to keep as much (all) of this/other info as we lower rtl for debug purposes.
// Store this either directly or in the form of relationships/graphs etc. Explore the design
// space to see what makes sense and look at other implementations.
