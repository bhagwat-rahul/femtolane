package femtolane

import "core:fmt"

// The program should currently take a verilog/system-verilog file (eventually a project) and return an OASIS file
main :: proc() {
	fmt.println("hellope, this is femtolane, an RTL to OASIS compiler!")
	infile_path, outfile_path: string = ".sample/project.v", ".artifacts/test.oas" // user provides
	create_file_and_dir(outfile_path, OASIS_FILE_START)
}

// List whatever inputs the program can take when user calls help
help :: proc() {

}
