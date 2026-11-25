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
	directive := sv_scan_ident(l)
	switch directive {
	case "__FILE__": // expand to filename
	case "__LINE__": // expand to line in file
	case "begin_keywords", "end_keywords": // specify which version of verilog the module/construct following this supports, model as enum
	case "celldefine", "endcelldefine": // tag a module as cell module (resetall includes effects of endcelldefine and celldefine/endcelldefine maybe used independently)
	case "default_nettype": // what net created for implicit declarations (`default nettype_none/uwire, etc.)
	case "define", "undef", "undefineall": // define something & friends, unaffected by `resetall
	case "ifdef", "else", "elsif", "endif", "ifndef": // conditionally include something
	case "include": // insert entire contents of source file into another file during compilation
	case "line": // linenum
	case "unconnected_drive", "nounconnected_drive": // all unconnected ports between these directives pulled up or down instead of defaults
	case "pragma": // alters source, pragma expression syntax
	case "resetall": // all compiler dir's set to default vals
	case "timescale": // set timescale (timescale time_unit/time_precision eg `timescale 1ns / 1ps)
	case: lexer_panic(l, fmt.tprint("Unkown compiler directive", directive))
	}
}

sv_scan_ident :: proc(l: ^Lexer) -> (ident: string) {
	return ident
}

sv_lex_number_literal :: proc() {  }
