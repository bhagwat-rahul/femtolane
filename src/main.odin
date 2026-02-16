package femtolane

import "core:fmt"
import "core:os"

// The program should currently take a verilog/system-verilog file (eventually a project) and return an OASIS file
main :: proc() {
	fmt.println(
		"hellope, this is femtolane, an RTL to OASIS compiler! For more info run 'femtolane help'",
	)
	args := parse_args(os.args)
	fmt.println(args)
	switch args.command {
	case .help:
		run_help_command(args)
	case .flow:
		run_flow_command(args)
	case:
		run_help_command(args)
	}
}

run_flow_command :: proc(args: Tool_Args) {
	infile_path, outfile_path: string = args.input_file, args.output_file
	create_file_and_dir(outfile_path, create_oasis_data())
}

run_help_command :: proc(args: Tool_Args) {
	cmd: Command = args.command
	fmt.println("Name:        ", command_info[cmd].name)
	fmt.println("Description: ", command_info[cmd].description)
	fmt.println("Usage:       ", command_info[cmd].usage)
}
