package femtolane

import "core:fmt"

// The program should currently take a verilog/system-verilog file (eventually a project) and return an OASIS file
main :: proc() {
	fmt.println("hellope, this is femtolane, an RTL to OASIS compiler!")
	infile_path: string // user provides
	outfile_path: string // user provides
	write_oasis_file(outfile_path, OASIS_FILE_START)
}

// List whatever inputs the program can take when user calls help
help :: proc() {

}
