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
import "core:os"
import "core:simd"

// TODO(rahul): Learn more about hypergraphs and look at some gate level netlists before attempting this to find best fit

// What cell is this from the stdcell lib / pdk for debug purposes
Cell :: struct {
	name: string,
}

// Instances of cells in the actual design and their metadata
Instance :: struct {
	name:        string,
	id:          u32,
	parent_cell: ^Cell,
}

PortType :: enum {
	INPUT,
	OUTPUT,
	INOUT,
}

Port :: struct {
	parent_instance: ^Instance,
	name:            string,
	id:              u32,
	type:            PortType,
}

// A net/wire is something that connects multiple instances of cells/instances (many-many)
WireNet :: struct {
	netId:       u32,
	connections: []^Port,
}

Keyword :: enum {
	IDENT,
	INPUT,
	OUTPUT,
	WIRE,
	ASSIGN,
	MODULE,
	ENDMODULE,
}

Lexer :: struct {
	source:        []byte,
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
	hgr: NetlistHyperGraph = {}
	data, err := os.read_entire_file_from_path(gate_netlist_path, context.allocator)
	ensure(err == nil, fmt.tprintfln("FileReadError: %v", err))
	defer delete(data) // TODO(rahul): idk yet if this delete is needed i need to learn more about allocations
	lexer: Lexer = {data, 0} // gl netlist data, start from byte 0

	for int(lexer.curr_byte_idx); int(lexer.curr_byte_idx) < len(lexer.source); {
		i := lexer.curr_byte_idx
		next := i + 1

		switch lexer.source[i] {
		case '/': lexer.curr_byte_idx += skip_comment(&lexer)
		case '(': if (next < len(lexer.source) && lexer.source[next] == '*') { handle_attribute(&lexer) }
		case: panic(fmt.tprintfln("Unhandled char: %r", lexer.source[i]))
		}
	}
	flattenAndWriteHyperGraph(&hgr)
}

handle_attribute :: proc(l: ^Lexer) {  }

handle_ident :: proc(l: ^Lexer) {  }

@(require_results)
skip_comment :: proc(l: ^Lexer) -> int {
	src, curr, next := l.source, l.curr_byte_idx, l.curr_byte_idx + 1
	delim: byte = (src[next] == '/' ? '\n' : '*') // single-line vs multi-line comment
	curr += 2
	delim_lane: #simd[16]u8 = {
		0 ..< 16 = delim,
	}
	for curr < len(src) - 16 {
		src_lane: #simd[16]u8 = simd.from_slice(simd.u8x16, src[curr:curr + 16])
		jmp := simd.count_trailing_zeros(simd.lanes_eq(src_lane, delim_lane))
	}
	return curr
}

keyword_lookup :: proc(s: string) -> Keyword {
	switch s {
	case "input": return .INPUT
	case "output": return .OUTPUT
	case "wire": return .WIRE
	case "assign": return .ASSIGN
	case "module": return .MODULE
	case "endmodule": return .ENDMODULE
	case: return .IDENT
	}
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
