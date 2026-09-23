package main

import "core:fmt"
import "core:mem/virtual"
import "core:path/filepath"
import "core:path/slashpath"
import "core:strings"

/*
 Classic automated flow, just so i dont have to do manual stuff between every test.
 What we want to do is, given folder(s) spit out gds (assuming prerequisites are in folder)
 So load in lib and lef files in the right order. (tlef first, then lef, etc.), use everything available from pdk to resolve cells, etc.
*/
run_flow :: proc(directory_paths: []string, top_name: string) -> (gds_filepath: string = "") {
	// get all lef / def, lib, verilog files from all directory paths recursively
	gds_filepath = "TODO(rahul): run flow and return gds/oas"
	all_filepaths, tlef_filepaths, lef_filepaths, def_filepaths, lib_filepaths, rtl_filepaths: [dynamic]string
	for path in directory_paths {
		walker := filepath.walker_create(path)
		for file in filepath.walker_walk(&walker) {
			if file.type == .Regular {
				filepath_copy, err := strings.clone(file.fullpath, context.temp_allocator)
				ensure(err == nil)
				append(&all_filepaths, filepath_copy)
			}
		}
		_, err := filepath.walker_error(&walker)
		ensure(err == nil)
		filepath.walker_destroy(&walker)
	}
	for file in all_filepaths {
		extension := slashpath.ext(file)
		switch extension {
		case ".TLEF", ".tlef": append(&tlef_filepaths, file)
		case ".LEF", ".lef": append(&lef_filepaths, file)
		case ".DEF", ".def": append(&def_filepaths, file)
		case ".LIB", ".lib": append(&lib_filepaths, file)
		case ".v", ".V", ".sv", ".SV": append(&rtl_filepaths, file)
		case: fmt.println("Ignoring unsupported file extension:", file)
		}
	}

	flow_arena: virtual.Arena
	ensure(virtual.arena_init_growing(&flow_arena) == nil, "Error init'ing flow arena")
	flow_allocator := virtual.arena_allocator(&flow_arena)
	defer virtual.arena_destroy(&flow_arena)

	lef_database := lef_create_new_database(flow_allocator)
	for tlef in tlef_filepaths { lef_read_file_into_database(tlef, flow_allocator, &lef_database) }
	for lef in lef_filepaths { lef_read_file_into_database(lef, flow_allocator, &lef_database) }

	// Add lib data


	// synthesize


	// lexgraph all verilog files


	return gds_filepath
}
