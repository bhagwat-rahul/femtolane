package femtolane

import "core:strings"

// This will likely support more things in the future like what command to run and flags rn just rtl-oas
Tool_Args :: struct {
	command:     Command,
	input_file:  string,
	output_file: string,
}

Command :: enum {
	help,
	flow,
}

Command_Info :: struct {
	command:     Command,
	name:        string,
	usage:       string,
	description: string,
	procedure:   proc(args: Tool_Args),
}

command_info: [Command]Command_Info = {
	.help = {
		command = .help,
		name = "help",
		usage = "tool help [command]",
		description = "Show general or command-specific help.",
		procedure = run_help_command,
	},
	.flow = {
		command = .flow,
		name = "flow",
		usage = "tool flow --input <rtl>.v --out <file>.oas",
		description = "Run full RTL → layout flow, provide verilog input to get oasis output.",
		procedure = run_flow_command,
	},
}

parse_args :: proc(argv: []string) -> Tool_Args {
	args: Tool_Args
	if len(argv) < 2 {
		args.command = .help
		return args
	}
	cmd := strings.to_lower(argv[1])
	switch cmd {
	case "help":
		args.command = .help
	case "flow":
		args.command = .flow
	case:
		args.command = .help
	}
	return args
}
