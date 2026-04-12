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

// IDs for fast lookup
CellID :: distinct u32
InstanceID :: distinct u32
InstancePortID :: distinct u32
CellPortID :: distinct u32
NetID :: distinct u32

Cell :: struct {
	id:             CellID, // for fast lookup
	name:           string, // human readable name from pdk, or module name if not from PDK
	pdk_provided:   bool, // was this provided by the pdk or the user, where is this from (not sure if this field is needed but keeping it for now)
	children_ports: [dynamic]^CellPort,
	resolved:       bool, // Do we know where this comes from? (or was this instantiated without being defined)
	metadata:       map[string]string, // pdk cell metadata; TODO(rahul):dk what this looks like fix type)
} // Metadata about a cell from the given pdk (stdcell lib, other ip, modules etc.)

CellHashMap :: map[string]^Cell // Hashmap of Cell Name -> Cell ID for O(1) lookups
InstanceHashMap :: map[string]^Instance // Hashmap of Instance Name -> Instance ID for O(1) lookups

Instance :: struct {
	name:        string, // human readable name for debug
	id:          InstanceID, // for fast lookup
	parent_cell: ^Cell, // what cell is this an instance of from stdcells/modules
	ports:       [dynamic]^InstancePort, // ports belonging to this instance
	source:      SourceLoc, // where in the GL netlist this comes from
} // Instances of cells in the actual design and their metadata

InstancePort :: struct {
	name:            string, // human readable name for debug
	id:              InstancePortID, // for fast lookup
	parent_instance: ^Instance, // what instance does this port belong to
	net:             ^Net, // What net does this belong to
} // A port is something on an instance that wires can connect to

CellPort :: struct {
	name:        string, // human readable name for debug
	id:          CellPortID, // for fast lookup
	parent_cell: ^Cell, // what cell does this port belong to
} // Define ports of a cell (also use this to check if an instance is connecting to defined legal ports)

SourceLoc :: struct {
	file_id:    u32,
	byte_start: u32,
	byte_end:   u32,
	line:       u32,
	column:     u32,
} // For a debuggable representation, we want people to be able to 'click in/out' all the way to/from oasis polygon <-> pos in hypergraph viz <-> source of GL/RTL netlist
// Attributes also play a role here, depending on how we do the frontend rtl -> gl later without yosys we may/may not need to store/write out attributes in some form.

NetType :: enum {
	INTERNAL, // wire
	MODULE_INPUT, // input
	MODULE_OUTPUT, // output
	MODULE_INOUT, // inout
}

Net :: struct {
	name:        string, // human readable name for debug
	id:          NetID, // for fast lookup
	connections: [dynamic]^InstancePort, // ports that this connects
	net_type:    NetType,
} // A net(wire) connects many-many ports (thereby connecting the parent instances of those ports)

GateLevelNetlistLexer :: struct {
	// source file and cursor index
	src:           []byte,
	curr_byte_idx: int, // 64 bit int on 64 bit system (not u32 to prevent casts everywhere when indexing)
	curr_cell:     ^Cell,
	curr_instance: ^Instance,
}

NetlistHyperGraph :: struct {
	cells:             [dynamic]^Cell,
	instances:         [dynamic]^Instance, // all instances in the netlist
	nets:              [dynamic]^Net, // connections between the instances of the netlist

	// Lookup table helper data
	cell_hash_map:     CellHashMap,
	instance_hash_map: InstanceHashMap,
}

WHITESPACE :: ' '
WHITESPACE_TAB :: '\t'
SLASH :: '/'
NEWLINE_CARRIAGE_RETURN :: '\r' // for windows platforms
NEWLINE :: '\n'
ESCAPE_SYMBOL :: '\\'
SEMICOLON :: ';'
COMMA :: ','
LPAREN :: '('
RPAREN :: ')'
L_SQUARE_BRACKET :: '['
R_SQUARE_BRACKET :: ']'
EQUAL :: '='
LESS_THAN :: '<'
GREATER_THAN :: '>'
COLON :: ':'
DOT :: '.'


IDENT_START, IDENT_CHAR: [256]bool

@(init) // init directive makes this run before main since we don't have compile time generation
init_ident_tables :: proc "contextless" () {
	// true for ident start and ident char (this can show up anywhere in ident)
	for c in 'a' ..= 'z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	for c in 'A' ..= 'Z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	IDENT_START['_'] = true; IDENT_CHAR['_'] = true

	// only true for ident char, cannot see this at the beginning of an ident
	for c in '0' ..= '9' { IDENT_CHAR[c] = true }
	IDENT_CHAR['$'] = true
}

is_ident_start :: #force_inline proc(b: byte) -> bool { return IDENT_START[b] }
is_ident_char :: #force_inline proc(b: byte) -> bool { return IDENT_CHAR[b] }

scan_ident :: #force_inline proc(l: ^GateLevelNetlistLexer) -> string {
	start := l.curr_byte_idx
	for is_ident_char(peek(l)) { advance(l) }
	end := l.curr_byte_idx
	return string(l.src[start:end])
}

// Main lexer function to single pass lex -> convert netlist to hypergraph,
// use slices instead of allocating a scratch buf and the byte_idx always goes ahead by the amount of bytes we just consumed to identify a token
// That is what makes this 'single pass' and O(n) where n = len(src_bytes)
// also use lookup-tables instead of branch heavy code for predictable memacc's
lex_gate_level_netlist_and_create_hypergraph :: proc(gate_netlist_path: string) {
	lexGraphArena: virtual.Arena
	ensure(virtual.arena_init_growing(&lexGraphArena) == nil)
	defer virtual.arena_destroy(&lexGraphArena)
	arena_alloc := virtual.arena_allocator(&lexGraphArena)
	data, err := os.read_entire_file_from_path(gate_netlist_path, arena_alloc)
	ensure(err == nil, fmt.tprintln("FileReadError:", err))
	l: GateLevelNetlistLexer = {
		src           = data,
		curr_byte_idx = 0,
		curr_cell     = nil,
		curr_instance = nil,
	} // gl netlist data, start from byte 0

	hgr := NetlistHyperGraph {
		instances         = make([dynamic]^Instance, arena_alloc),
		nets              = make([dynamic]^Net, arena_alloc),
		cells             = make([dynamic]^Cell, arena_alloc),

		// scratch data
		cell_hash_map     = make(CellHashMap, arena_alloc),
		instance_hash_map = make(InstanceHashMap, arena_alloc),
	}
	// NOTE(rahul): this loop never changes curr_byte_idx only handler functions do
	for l.curr_byte_idx < len(l.src) {
		idx := l.curr_byte_idx
		byte := peek(&l)

		switch byte {
		case SLASH: handleSingleAndMultiLineComments(&l)
		case NEWLINE, NEWLINE_CARRIAGE_RETURN, WHITESPACE, WHITESPACE_TAB: skipNewlinesAndWhiteSpaces(&l)
		case LPAREN: checkForAndHandleAttribute(&l) // the only lparen main loop should see is for attributes
		case ESCAPE_SYMBOL: handleEscapedIdent(&l)
		case: if is_ident_start(byte) { handleIdent(&l, &hgr, arena_alloc) } else {
					lexer_panic(&l, "Unhandled char")
				}
		}
	}
}

skipNewlinesAndWhiteSpaces :: #force_inline proc(l: ^GateLevelNetlistLexer) {
	for {
		c := peek(l)
		if c != NEWLINE && c != NEWLINE_CARRIAGE_RETURN && c != WHITESPACE && c != WHITESPACE_TAB { break }
		advance(l)
	}
}

handleEscapedIdent :: proc(l: ^GateLevelNetlistLexer) {  }

handleSingleAndMultiLineComments :: #force_inline proc(l: ^GateLevelNetlistLexer) {
	if (peek(l) == '/' && peek_next(l) == '/') {
		advance(l, 2)
		for peek(l) != '\n' && peek(l) != 0 { advance(l) }
		if peek(l) == '\n' { advance(l) }
	} else if (peek(l) == '/' && peek_next(l) == '*') {
		advance(l, 2)
		for !(peek(l) == '*' && peek_next(l) == '/') && peek(l) != 0 { advance(l) }
		advance(l, 2)
	} else { lexer_panic(l, "Error in comment skip") }
}

checkForAndHandleAttribute :: proc(l: ^GateLevelNetlistLexer) {
	if peek(l) == '(' && peek_next(l) == '*' {
		attribute_start_idx := l.curr_byte_idx // index of (*
		for !(peek(l) == '*' && peek_next(l) == ')') && peek(l) != 0 { advance(l) }
		advance(l, 2)
		attribute_end_idx := l.curr_byte_idx // index of *)
		emit_attribute := l.src[attribute_start_idx:attribute_end_idx] // TODO(rahul): map to source lines and handle attributes appropriately
	} else { lexer_panic(l, "Invalid attribute") }
}

handleIdent :: proc(l: ^GateLevelNetlistLexer, hgr: ^NetlistHyperGraph, arena_alloc: mem.Allocator) {

	KEYWORD_ASSIGN :: "assign"
	KEYWORD_MODULE :: "module"
	KEYWORD_ENDMODULE :: "endmodule"
	KEYWORD_INPUT :: "input"
	KEYWORD_OUTPUT :: "output"
	KEYWORD_INOUT :: "inout"
	KEYWORD_WIRE :: "wire"

	ident := scan_ident(l)

	switch ident {

	case KEYWORD_ASSIGN:
		fmt.println("assign statement")
		lhs := scan_ident(l)
		skipNewlinesAndWhiteSpaces(l)
		equals := peek(l)
		if (equals != EQUAL) { lexer_panic(l, "No = after LHS in assign statement") } else { advance(l) }
		rhs := scan_ident(l)
		skipNewlinesAndWhiteSpaces(l)

	case KEYWORD_MODULE:
		advance(l)
		skipNewlinesAndWhiteSpaces(l)
		module_name := scan_ident(l) // since we're in module header next scanned thing after module keyword is name of module and then module def
		fmt.println("Module name", module_name)
		skipNewlinesAndWhiteSpaces(l)
		if (peek(l) != LPAREN) { lexer_panic(l, fmt.tprint("Found", peek(l), "instead of", LPAREN)) } else { advance(l) }
		skipNewlinesAndWhiteSpaces(l)
		// handle ports of this module
		ports := 0
		for peek(l) != SEMICOLON {
			fmt.println("Port", ports, "=", scan_ident(l))
			skipNewlinesAndWhiteSpaces(l)
			if (peek(l) == ',') { advance(l) } else if (peek(l) == ')') { advance(l) } else { lexer_panic(l, "no comma here") }
			skipNewlinesAndWhiteSpaces(l)
			ports += 1
		}
		advance(l)
		skipNewlinesAndWhiteSpaces(l)

	case KEYWORD_ENDMODULE:
		fmt.println("end current module", l.curr_cell.name)
		l.curr_cell = nil
		advance(l)
		skipNewlinesAndWhiteSpaces(l)

	case KEYWORD_WIRE, KEYWORD_INPUT, KEYWORD_OUTPUT, KEYWORD_INOUT:
		ident_net_type: NetType
		switch ident {
		case KEYWORD_WIRE: ident_net_type = .INTERNAL
		case KEYWORD_INPUT: ident_net_type = .MODULE_INPUT
		case KEYWORD_OUTPUT: ident_net_type = .MODULE_OUTPUT
		case KEYWORD_INOUT: ident_net_type = .MODULE_INOUT
		}
		skipNewlinesAndWhiteSpaces(l)
		msb, lsb := 0, 0
		if peek(l) == L_SQUARE_BRACKET {
			msb, lsb = parse_bus(l)
			skipNewlinesAndWhiteSpaces(l)
		}
		net_loop: for {
			name := scan_ident(l)
			lo, hi := min(msb, lsb), max(msb, lsb)
			for i in lo ..= hi {
				net_name := name if (msb == 0 && lsb == 0) else fmt.tprintf("%s[%d]", name, i)
				create_net(
					hgr = hgr,
					arena_alloc = arena_alloc,
					net_val = Net{name = net_name, net_type = ident_net_type, connections = make([dynamic]^InstancePort, arena_alloc)},
				)
			}
			skipNewlinesAndWhiteSpaces(l)
			switch peek(l) {
			case COMMA:
				advance(l)
				skipNewlinesAndWhiteSpaces(l)
			case SEMICOLON:
				advance(l)
				skipNewlinesAndWhiteSpaces(l)
				break net_loop
			case: lexer_panic(l, fmt.tprint("Expected", COMMA, "or", SEMICOLON, "after wire declaration got", rune(peek(l))))
			}
		}

	case:
		// since this is nothing else it has to be an instantiation
		parent_cell_name := ident
		skipNewlinesAndWhiteSpaces(l)
		instance_name := scan_ident(l)
		parent_cell_ptr := hgr.cell_hash_map[parent_cell_name] // Try O(1) lookup
		cell_resolved := false // start off as unresolved by default
		if parent_cell_ptr == nil {
			cell_resolved = false
			parent_cell_ptr = create_cell(hgr = hgr, arena_alloc = arena_alloc, cell_val = Cell{name = parent_cell_name, resolved = cell_resolved})
		} else { cell_resolved = true }
		instance_val: Instance = {
			name        = instance_name,
			parent_cell = parent_cell_ptr,
		}
		// created_instance := create_instance(hgr = hgr, arena_alloc = arena_alloc, inst_val = instance_val)
		// fmt.println(created_instance.name, l.curr_byte_idx)
		skipNewlinesAndWhiteSpaces(l)
		if peek(l) != '(' && peek(l) != 0 { lexer_panic(l, "No brackets after instantiation") }
		instance_connections := 0
		for peek(l) != SEMICOLON {
			skipNewlinesAndWhiteSpaces(l)
			if (peek(l) == ',') { advance(l) } else if (peek(l) == ')') { advance(l) } else { lexer_panic(l, "No comma found") }
			skipNewlinesAndWhiteSpaces(l)
			instance_connections += 1
		}

	}
}

// Parse bus of form [1023:0], which indicates 1024 elements, return msb (1023) and lsb (0)
parse_bus :: proc(l: ^GateLevelNetlistLexer) -> (msb: int, lsb: int) {
	ensure(peek(l) == L_SQUARE_BRACKET, "parse_bus called with a non [ char")
	advance(l)
	for peek(l) != COLON && peek(l) != 0 {
		c := peek(l)
		msb = msb * 10 + int(c - '0')
		advance(l)
	}
	advance(l)
	for peek(l) != R_SQUARE_BRACKET && peek(l) != 0 {
		c := peek(l)
		lsb = lsb * 10 + int(c - '0')
		advance(l)
	}
	advance(l)
	return msb, lsb
}

create_instance :: proc(hgr: ^NetlistHyperGraph, arena_alloc: mem.Allocator, inst_val: Instance) -> ^Instance {
	ensure(inst_val.parent_cell != nil, fmt.tprint("No parent cell provided for instance", inst_val.name))
	inst := new(Instance, arena_alloc)
	inst^ = inst_val
	inst.id = InstanceID(len(hgr.instances))
	hgr.instance_hash_map[inst.name] = inst
	append(&hgr.instances, inst)
	return inst
}

create_cell :: proc(hgr: ^NetlistHyperGraph, arena_alloc: mem.Allocator, cell_val: Cell) -> ^Cell {
	cell := new(Cell, arena_alloc)
	cell^ = cell_val
	cell.id = CellID(len(hgr.cells))
	hgr.cell_hash_map[cell.name] = cell
	append(&hgr.cells, cell)
	return cell
}

create_instance_port :: proc(arena_alloc: mem.Allocator, instance_port_val: InstancePort) -> ^InstancePort {
	instance_port_parent_instance_ptr := instance_port_val.parent_instance
	ensure(instance_port_parent_instance_ptr != nil, "Trying to add a port to a nil instance")
	id := InstancePortID(len(instance_port_parent_instance_ptr.ports))
	instance_port := new(InstancePort, arena_alloc)
	instance_port^ = instance_port_val
	instance_port.id = id
	append(&instance_port_parent_instance_ptr.ports, instance_port)
	return instance_port
}

create_cell_port :: proc(parent_cell_ptr: ^Cell, arena_alloc: mem.Allocator, name: string) -> ^CellPort {
	id := CellPortID(len(parent_cell_ptr.children_ports))
	cell_port := new(CellPort, arena_alloc)
	cell_port^ = CellPort {
		name        = name,
		id          = id,
		parent_cell = parent_cell_ptr,
	}
	append(&parent_cell_ptr.children_ports, cell_port)
	return cell_port
}

create_net :: proc(hgr: ^NetlistHyperGraph, arena_alloc: mem.Allocator, net_val: Net) -> ^Net {
	net := new(Net, arena_alloc)
	net^ = net_val
	net.id = NetID(len(hgr.nets))
	append(&hgr.nets, net)
	return net
}

peek :: #force_inline proc(l: ^GateLevelNetlistLexer) -> byte { return l.src[l.curr_byte_idx] if l.curr_byte_idx < len(l.src) else 0 }

peek_next :: #force_inline proc(l: ^GateLevelNetlistLexer) -> byte { return l.src[l.curr_byte_idx + 1] if l.curr_byte_idx + 1 < len(l.src) else 0 }

advance :: #force_inline proc(l: ^GateLevelNetlistLexer, advance_by: int = 1) {
	if l.curr_byte_idx + advance_by > len(l.src) { lexer_panic(l, "Unexpected EOF") }
	l.curr_byte_idx += advance_by
}

// Write out an hgr file for debug purposes
flattenAndWriteHyperGraph :: proc(hgr: ^NetlistHyperGraph) {
	flatHgrData: []byte = {'t', 'e', 's', 't'}
	writeDataToFile("netlist_hypergraph.hgr", &flatHgrData)
}

lexer_panic :: #force_inline proc(l: ^GateLevelNetlistLexer, error_message: string) {
	error_message_with_details := fmt.tprint("Error:", error_message, "at byte", l.curr_byte_idx, "for char", rune(l.src[l.curr_byte_idx]))
	panic(error_message_with_details)
}
