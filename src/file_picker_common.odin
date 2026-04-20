package main
import "core:strings"

Picker_Mode :: enum {
	Open_File,
	Save_File,
	Open_Folder,
}

File_Type_Filter :: struct {
	description: string,
	extensions:  []string, // "png", "jpg", "json"
}

File_Picker_Request :: struct {
	mode:           Picker_Mode,
	title:          string,
	starting_path:  string,
	suggested_name: string,
	file_types:     []File_Type_Filter,
}

normalized_extension :: #force_inline proc(extension: string) -> string {
	if len(extension) > 0 && extension[0] == '.' { return extension[1:] }
	return extension
}

is_wildcard_extension :: #force_inline proc(extension: string) -> bool {
	normalized := normalized_extension(extension)
	return normalized == "*" || normalized == "*.*"
}

wildcard_for_extension :: #force_inline proc(extension: string, allocator := context.temp_allocator) -> string {
	ext := normalized_extension(extension)
	if len(ext) == 0 { return "" }
	if is_wildcard_extension(ext) { return "*" }
	return strings.concatenate({"*.", ext}, allocator) or_else ""
}
