package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"

json_read_file_and_return_json_value :: proc(filepath: string, allocator: mem.Allocator = context.allocator) -> json.Value {
	data, file_read_err := os.read_entire_file(filepath, allocator)
	ensure(file_read_err == nil, fmt.tprint(file_read_err))
	defer delete(data)

	json_value, json_parse_err := json.parse_bytes(data = data, allocator = allocator)
	ensure(json_parse_err == nil, fmt.tprint(json_parse_err))
	return json_value
}

json_marshal_data_and_write_json_file :: proc(
	filepath: string,
	data: any, // can't be a struct with typed pointers
	marshal_options: json.Marshal_Options = {pretty = true, use_enum_names = true},
	allocator: mem.Allocator = context.allocator,
) {
	json_data, marshal_err := json.marshal(v = data, opt = marshal_options, allocator = allocator)
	ensure(marshal_err == nil, fmt.tprint(marshal_err))

	write_err := os.write_entire_file_from_bytes(filepath, json_data)
	ensure(write_err == nil, fmt.tprint(write_err))
}

// main :: proc() {
// 	FILEPATH :: "/Users/rahulbhagwat/Documents/git/zerotoasic/coursework/librelane-ci-designs/inverter/runs/RUN_2026-10-05_00-30-57/01-yosys-synthesis/inverter.nl.v.json"
// 	json_value := json_parse_file_and_return_json_value(FILEPATH)
// 	root := json_value.(json.Object)
// 	modules := root["modules"].(json.Object)
// 	selected_module: json.Object = modules["sky130_ef_io__analog_esd_pad"].(json.Object)
// 	fmt.println(selected_module)
// 	// TODO(rahul): select right module
// }
