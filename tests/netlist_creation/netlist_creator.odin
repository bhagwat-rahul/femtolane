package netlist_creator

import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:strings"

run_yosys :: proc(filepath: string, liberty_file: string) {
	// TODO(rahul): use the ys script instead of raw yosys cmd
	YosysScriptFile :: "netlist_creator.ys"
	synth_script, _ := os.read_entire_file_from_path(YosysScriptFile, os.heap_allocator())
	strings.replace_all(string(synth_script), "{{liberty_filename}}", liberty_file)
	directory, filename := slashpath.split(filepath)
	outfile := fmt.tprintf("%s.%s.netlist.v", directory, strings.trim_suffix(filename, ".v"))
	yosys_cmd := fmt.tprintf(
		`
		read_liberty -lib -ignore_miss_dir -setattr blackbox %s;
		read_verilog %s;
		hierarchy -check -top top;
		proc; opt; fsm; opt;memory; opt; techmap;
		dfflibmap -liberty %s;
		abc       -liberty %s;
		setundef -zero;
		hilomap \
		-hicell gf180mcu_fd_sc_mcu7t5v0__tieh  Y \
		-locell gf180mcu_fd_sc_mcu7t5v0__tiel  Y;
		clean;
		write_verilog -noattr -noexpr %s
		`,
		liberty_file,
		filepath,
		liberty_file,
		liberty_file,
		outfile,
	)
	yosys_proc: os.Process_Desc = {
		working_dir = "",
		command     = {"yosys", "-p", yosys_cmd},
		env         = nil,
	}
	state, stdout, stderr, err := os.process_exec(yosys_proc, os.heap_allocator())
	if err != nil {fmt.println("yosys spawn failed, Error:", err)}
}

main :: proc() {
	// From args/user input, get pdk_path (or path to relevant files), using this, gen dotfile netlists
	liberty_file :: "/Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib"
	run_yosys("gcd/gcd.v", liberty_file)
}
