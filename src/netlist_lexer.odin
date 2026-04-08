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
import "core:mem/virtual"
import "core:os"

// TODO(rahul): Learn more about hypergraphs and look at some gate level netlists before attempting this to find best fit

// IDs for fast lookup
CellID :: distinct u32
InstanceID :: distinct u32
PortID :: distinct u32
NetID :: distinct u32

Cell :: struct {
	id:           CellID, // for fast lookup
	name:         string, // human readable name from pdk, or module name if not from PDK
	pdk_provided: bool, // was this provided by the pdk or the user, where is this from (not sure if this field is needed but keeping it for now)
	metadata:     map[string]string, // pdk cell metadata; TODO(rahul):dk what this looks like fix type)
} // Metadata about a cell from the given pdk (stdcell lib, other ip, modules etc.)

Instance :: struct {
	name:        string, // human readable name for debug
	id:          InstanceID, // for fast lookup
	parent_cell: ^Cell, // what cell is this an instance of from stdcells/modules
	ports:       []^Port, // ports belonging to this instance
	source:      SourceLoc, // where in the GL netlist this comes from
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
	net:    ^Net, // What net does this belong to
} // A port is something on an instance that wires can connect to

SourceLoc :: struct {
	file_id:    u32,
	byte_start: u32,
	byte_end:   u32,
	line:       u32,
	column:     u32,
} // For a debuggable representation, we want people to be able to 'click in/out' all the way to/from oasis polygon <-> pos in hypergraph viz <-> source of GL/RTL netlist
// Attributes also play a role here, depending on how we do the frontend rtl -> gl later without yosys we may/may not need to store/write out attributes in some form.

Net :: struct {
	name:             string, // human readable name for debug
	id:               NetID, // for fast lookup
	connections:      []^Port, // ports that this connects
	bus_len:          u32, // Is part of a bus like wire [7:0], if so len will be stored here, if not, then len 0
	bus_msb, bus_lsb: u32, // most and least significant bit if part of bus, if not then both will be 0
} // A net(wire) connects many-many ports (thereby connecting the parent instances of those ports)

Lexer :: struct {
	// source file and cursor index
	src:           []byte,
	curr_byte_idx: int, // 64 bit int on 64 bit system (not u32 to prevent casts everywhere when indexing)
	curr_cell:     ^Cell,
	curr_instance: ^Instance,
}

NetlistHyperGraph :: struct {
	cells:     []^Cell,
	instances: []^Instance, // all instances in the netlist
	nets:      []^Net, // connections between the instances of the netlist
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

@(init) // run this before main
init_ident_tables :: proc "contextless" () {
	// both true
	for c in 'a' ..= 'z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	for c in 'A' ..= 'Z' { IDENT_START[c] = true; IDENT_CHAR[c] = true }
	IDENT_START['_'] = true; IDENT_CHAR['_'] = true

	// start not true only char true
	for c in '0' ..= '9' { IDENT_CHAR[c] = true }
	IDENT_CHAR['$'] = true
}

is_ident_start :: #force_inline proc(b: byte) -> bool { return IDENT_START[b] }
is_ident_char :: #force_inline proc(b: byte) -> bool { return IDENT_CHAR[b] }

scan_ident :: #force_inline proc(l: ^Lexer) -> string {
	start := l.curr_byte_idx
	for l.curr_byte_idx < len(l.src) && is_ident_char(l.src[l.curr_byte_idx]) { l.curr_byte_idx += 1 }
	end := l.curr_byte_idx
	return string(l.src[start:end])
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
	data, err := os.read_entire_file_from_path(gate_netlist_path, arena_alloc)
	ensure(err == nil, fmt.tprintfln("FileReadError: %v", err))
	l: Lexer = {
		src           = data,
		curr_byte_idx = 0,
		curr_cell     = nil,
		curr_instance = nil,
	} // gl netlist data, start from byte 0

	hgr: NetlistHyperGraph = {
		instances = {},
		nets      = {},
		cells     = {},
	}
	// NOTE(rahul): this loop never changes curr_byte_idx only handler functions do
	for l.curr_byte_idx < len(l.src) {
		idx := l.curr_byte_idx
		byte := l.src[idx]

		switch byte {
		case SLASH: handleSingleAndMultiLineComments(&l)
		case NEWLINE, NEWLINE_CARRIAGE_RETURN, WHITESPACE, WHITESPACE_TAB: skipNewlinesAndWhiteSpaces(&l)
		case LPAREN: checkForAndHandleAttribute(&l) // the only lparen main loop should see is for attributes
		case ESCAPE_SYMBOL: handleEscapedIdent(&l)
		case:
			if is_ident_start(byte) { handleIdent(&l, &hgr) }
				else {panic(
						fmt.tprintfln("Unhandled char %r at position %d in file %s", byte, idx, gate_netlist_path),
					)}
		}
	}
}

skipNewlinesAndWhiteSpaces :: #force_inline proc(l: ^Lexer) {
	for {
		c := l.src[l.curr_byte_idx]
		if c != NEWLINE && c != NEWLINE_CARRIAGE_RETURN && c != WHITESPACE && c != WHITESPACE_TAB { break }
		l.curr_byte_idx += 1
	}
}

handleEscapedIdent :: proc(l: ^Lexer) {  }

handleSingleAndMultiLineComments :: #force_inline proc(l: ^Lexer) {
	if (l.src[l.curr_byte_idx] == '/' && l.src[l.curr_byte_idx + 1] == '/') {
		l.curr_byte_idx += 2
		for !(l.src[l.curr_byte_idx] == '\n') { l.curr_byte_idx += 1 }
		l.curr_byte_idx += 2
	} else if (l.src[l.curr_byte_idx] == '/' && l.src[l.curr_byte_idx + 1] == '*') {
		l.curr_byte_idx += 2
		for !(l.src[l.curr_byte_idx] == '*' && l.src[l.curr_byte_idx + 1] == '/') { l.curr_byte_idx += 1 }
		l.curr_byte_idx += 2
	} else { panic("Error in comment skip") }
}

checkForAndHandleAttribute :: proc(l: ^Lexer) {
	if l.src[l.curr_byte_idx] == '(' && l.src[l.curr_byte_idx + 1] == '*' {
		attribute_start_idx := l.curr_byte_idx // index of (*
		for l.src[l.curr_byte_idx] == '*' && l.src[l.curr_byte_idx + 1] == ')' { l.curr_byte_idx += 1 }
		l.curr_byte_idx += 2
		attribute_end_idx := l.curr_byte_idx // index of *)
		emit_attribute := l.src[attribute_start_idx:attribute_end_idx] // TODO(rahul): map to source lines and handle attributes appropriately
	} else { panic("Invalid attribute") }
}

handleIdent :: proc(l: ^Lexer, hgr: ^NetlistHyperGraph) {

	KEYWORD_ASSIGN :: "assign"
	KEYWORD_MODULE :: "module"
	KEYWORD_ENDMODULE :: "endmodule"
	KEYWORD_INPUT :: "input"
	KEYWORD_OUTPUT :: "output"
	KEYWORD_WIRE :: "wire"

	ident := scan_ident(l)

	switch ident {

	case KEYWORD_ASSIGN:
		fmt.println("assign statement")
		lhs := scan_ident(l)
		skipNewlinesAndWhiteSpaces(l)
		equals := l.src[l.curr_byte_idx]
		if (equals != EQUAL) { panic("No = after LHS in assign statement") } else { l.curr_byte_idx += 1 }
		rhs := scan_ident(l)
		skipNewlinesAndWhiteSpaces(l)

	case KEYWORD_MODULE:
		fmt.println("we're in a module")
		l.curr_byte_idx += 1
		skipNewlinesAndWhiteSpaces(l)
		module_name := scan_ident(l) // since we're in module header next scanned thing after module keyword is name of module and then module def
		fmt.println("Module name", module_name)
		skipNewlinesAndWhiteSpaces(l)
		lparen := l.src[l.curr_byte_idx]
		if (lparen !=
			   LPAREN) { panic(fmt.tprintf("No ( after module declaration found %r instead", l.src[l.curr_byte_idx])) } else { l.curr_byte_idx += 1 }
		skipNewlinesAndWhiteSpaces(l)
		// handle ports of this module
		ports := 0
		for l.src[l.curr_byte_idx] != SEMICOLON {
			fmt.println("Port", ports, "=", scan_ident(l))
			skipNewlinesAndWhiteSpaces(l)
			if (l.src[l.curr_byte_idx] ==
				   ',') { l.curr_byte_idx += 1 } else if (l.src[l.curr_byte_idx] == ')') { l.curr_byte_idx += 1 } else { panic("no comma here") }
			skipNewlinesAndWhiteSpaces(l)
			ports += 1
		}
		skipNewlinesAndWhiteSpaces(l)
		fmt.println("we are done with module")

	case KEYWORD_ENDMODULE:
		fmt.println("end current module", l.curr_cell.name)
		l.curr_cell = nil
		skipNewlinesAndWhiteSpaces(l)

	case KEYWORD_WIRE:

	case KEYWORD_INPUT:

	case KEYWORD_OUTPUT:

	case:
		fmt.println(
				"Since this keyword doesn't look like any of the other keywords it has to be a module instantiation or error?",
			)

	}
}

// Write out an hgr file for debug purposes
flattenAndWriteHyperGraph :: proc(hgr: ^NetlistHyperGraph) {
	flatHgrData: []byte = {'t', 'e', 's', 't'}
	writeDataToFile("netlist_hypergraph.hgr", &flatHgrData)
}
