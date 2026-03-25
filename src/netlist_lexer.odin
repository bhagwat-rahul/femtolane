/*
# Femtolane Lexer
Fast, single-pass 'lexer' to convert verilog netlists into a hypergraph of nets representation.
We only care about the ASIC synthesizable gate level RTL version of verilog since this will process things after they have gone through a yosys style frontend.
This representation will then directly be used along with sdc timing constraints, etc. to do floorplan, place and route for a digital ASIC.
We want this internal graph representation to be fully GUI viewable and debuggable, so things map to their source files using attributes from the netlist.
This has to be performant, not just in runtime but in the way that we represent this graph since that is what will be read from millions++ of times for PnR.
*/

package main
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"

// TODO(rahul): Learn more about hypergraphs and look at some gate level netlists before attempting this to find best fit

// IDs for fast lookup
CellID :: distinct u32
InstanceID :: distinct u32
PortID :: distinct u32
NetID :: distinct u32

Cell :: struct {
	id:       CellID, // for fast lookup
	name:     string, // human readable name from pdk
	metadata: map[string]string, // pdk cell metadata; TODO(rahul):dk what this looks like fix type)
} // Metadata about a cell from the given pdk (stdcell lib, other ip, etc.)

Instance :: struct {
	name:        string, // human readable name for debug
	id:          InstanceID, // for fast lookup
	parent_cell: ^Cell, // what cell is this an instance of from stdcells
	ports:       []^Port, // ports belonging to this instance
} // Instances of cells in the actual design and their metadata

PortType :: enum {
	INPUT,
	OUTPUT,
	INOUT,
} // Types of ports, input, output, or both

Port :: struct {
	name:   string, // human readable name for debug
	id:     PortID, // for fast lookup
	type:   PortType, // input, output or inout
	parent: ^Instance, // whom does this port belong to
} // A port is something on an instance that wires can connect to

Net :: struct {
	name:             ^string, // human readable name for debug
	id:               NetID, // for fast lookup
	connections:      []^Port, // ports that this connects
	bus_len:          u32, // Is part of a bus like wire [7:0], if so len will be stored here, if not, then len 0
	bus_msb, bus_lsb: u32, // most and least significant bit if part of bus, if not then both will be 0
} // A net(wire) connects many-many ports (thereby connecting the parent instances of those ports)

Netlist :: struct {
	instances: []^Instance, // all instances in the netlist
	nets:      []^Net, // connections between the instances of the netlist
} // Parent struct bringing ports,nets,wires together to represent an entire GL netlist

Lexer :: struct {
	src:           []byte,
	curr_byte_idx: int, // 64 bit int on 64 bit system (not u32 to prevent casts everywhere when indexing)
}

NetlistHyperGraph :: struct {
	// This should contain the final graph rep that will be used for processing
}

// Main lexer function to single pass lex -> convert netlist to hypergraph,
// use slices instead of allocating a scratch buf and the byte_idx always goes ahead by the amount of bytes we just consumed to identify a token
// That is what makes this 'single pass' and O(n) where n = len(src_bytes)
// also use lookup-tables instead of branch heavy code for predictable memacc's
lexGraphNetlist :: proc(gate_netlist_path: string) {
	lexGraphArena: virtual.Arena
	ensure(virtual.arena_init_growing(&lexGraphArena) == nil)
	defer virtual.arena_destroy(&lexGraphArena)
	arena_alloc := virtual.arena_allocator(&lexGraphArena)
	hgr: NetlistHyperGraph = {}
	data, err := os.read_entire_file_from_path(gate_netlist_path, arena_alloc)
	ensure(err == nil, fmt.tprintfln("FileReadError: %v", err))
	l: Lexer = {data, 0} // gl netlist data, start from byte 0

	flattenAndWriteHyperGraph(&hgr)
}

// Write out an hgr file for debug purposes
flattenAndWriteHyperGraph :: proc(hgr: ^NetlistHyperGraph) {
	flatHgrData: []byte = {'t', 'e', 's', 't'}
	writeDataToFile("netlist_hypergraph.hgr", &flatHgrData)
}

/*
TODO(rahul): Generic cells are fine during lex->hypergraph so we don't want to panic now, but can't have any during PnR
so we can work on the lexer step for now until the GL netlist creator is sorted with yosys.
returns true if cell type is not tech-mapped and generic like $and (panic when true since useless to do PnR otherwise)
*/
checkGenericCell :: #force_inline proc(cell: string) -> bool { return len(cell) > 0 && cell[0] == '$' }
