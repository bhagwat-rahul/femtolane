package main

import "core:fmt"
import "core:mem"
import "core:os"

SystemVerilogDatabase :: struct {
	current_module: ^SVModule,
	module:         [dynamic]SVModule,
}

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

	for l.idx < len(l.src) {
		ident := sv_scan_ident(&l)
		switch ident {
		case "`": // sv_compiler_directive
		case "//", "/*": // sv_comment (single and multiline)
		case "module": // begin module
		case "endmodule": // end current module
		case: lexer_panic(&l, fmt.tprint("Unknown ident", ident))
		}
	}

}

sv_scan_ident :: proc(l: ^Lexer) -> (ident: string) {
	return ident
}

sv_lex_number_literal :: proc() {  }
