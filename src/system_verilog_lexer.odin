package main

import "core:fmt"
import "core:mem"
import "core:os"

SystemVerilogDatabase :: struct {
	current_module: ^SVModule,
	modules:        [dynamic]SVModule,
	timescale:      SVTimeScales,
}

SVTimeScales :: enum {}

SVModule :: struct {
	name:       string,
	interfaces: [dynamic]SVInterface,
}

SVInterface :: struct {}

system_verilog_lexer :: proc(filepath: string, allocator: mem.Allocator) {
	data, err := os.read_entire_file_from_path(filepath, allocator)
	ensure(err == nil, fmt.tprint("Error reading system verilog file", err))

	l := Lexer {
		filepath = filepath,
		src      = data,
		idx      = 0,
		newlines = 0,
	}

	// TODO(rahul): init sv ident tables to handle backticks and comment symbols appropriately
	for l.idx < len(l.src) {
		lexer_skip_newlines_and_whitespaces(&l)
		ident := sv_scan_ident(&l)
		switch ident {
		case "`": sv_scan_compiler_directive(&l)
		case "/": sv_handle_comments(&l)
		case "module": // begin module
		case "endmodule": // end current module
		case: lexer_panic(&l, fmt.tprint("Unknown ident", ident))
		}
	}

}

// handle single and multiline comments / some of these may be attributions so don't just skip
// TODO(rahul): attributions show source -> final form mapping, handle correctly
sv_handle_comments :: #force_inline proc(l: ^Lexer) {
	lexer_skip_newlines_and_whitespaces(l)
	single_line_comment: if lexer_peek(l) == SLASH && lexer_peek(l, 1) == SLASH {
		for { if lexer_peek(l) == NEWLINE { break } else { lexer_advance(l) } }
	}
	multi_line_comment: if lexer_peek(l) == SLASH && lexer_peek(l, 1) == ASTERISK {
		for { if lexer_peek(l) == ASTERISK && lexer_peek(l, 1) == SLASH { lexer_advance(l, 2); break } else { lexer_advance(l) } }
	}
	lexer_skip_newlines_and_whitespaces(l)
}

sv_scan_compiler_directive :: proc(l: ^Lexer) {
	ident := sv_scan_ident(l)
	switch ident {
	case "__FILE__":
	case "__LINE__":
	case "begin_keywords":
	case "celldefine":
	case "default_nettype":
	case "define": // define something
	case "else":
	case "elsif":
	case "end_keywords":
	case "endcelldefine":
	case "endif":
	case "ifdef":
	case "ifndef":
	case "include":
	case "line":
	case "nounconnected_drive":
	case "pragma":
	case "resetall":
	case "timescale": // set timescale
	case "unconnected_drive":
	case "undef":
	case "undefineall":
	case "case":
	}
}

sv_scan_ident :: proc(l: ^Lexer) -> (ident: string) {
	return ident
}

sv_lex_number_literal :: proc() {  }
