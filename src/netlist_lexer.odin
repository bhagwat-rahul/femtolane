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

// TODO(rahul): Learn more about hypergraphs and look at some gate level netlists before attempting this to find best fit
BlockId :: distinct u32

Block :: struct {
	blockId:    BlockId, // to dedupe and fast compare
	name:       string, // readable name
	attributes: map[string]int, // Where did this block come from in orig source for debug
}

Lexer :: struct {
	source:        []byte,
	curr_byte_idx: u32, // u32 works upto a ~4GB source file
}

// Main lexer function to single pass lex -> convert netlist to hypergraph,
// use slices instead of allocating a scratch buf and the byte_idx always goes ahead by the amount of bytes we just consumed to identify a token
// That is what makes this 'single pass' and O(n) where n = len(src_bytes)
// also use lookup-tables instead of branch heavy code for predictable memacc's
lexGraphNetlist :: proc(gate_netlist_path: string) {
	data, err := os.read_entire_file_from_path(gate_netlist_path, context.allocator)
	ensure(err == nil, fmt.tprintf("FileReadError: %v", err))
	defer delete(data) // TODO(rahul): idk yet if this delete is needed i need to learn more about allocations

	lexer: Lexer = {
		source        = data, // gl netlist file contents
		curr_byte_idx = 0, // start from byte 1
	}

	for int(lexer.curr_byte_idx); int(lexer.curr_byte_idx) < len(lexer.source); {

		i := lexer.curr_byte_idx

		switch lexer.source[i] {
		case:
			fmt.println("Unhandled char")
		}

	}

}

handle_attribute :: proc(l: ^Lexer) {
}

handle_ident :: proc(l: ^Lexer) {

}

/*
TODO(rahul): Generic cells are fine during lex->hypergraph so we don't want to panic now, but can't have any during PnR
so we can work on the lexer step for now until the GL netlist creator is sorted with yosys.
returns true if cell type is not tech-mapped and generic like $and (panic when true since useless to do PnR otherwise)
*/
checkGenericCell :: #force_inline proc(cell: string) -> bool {
	return len(cell) > 0 && cell[0] == '$'
}
