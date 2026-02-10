package tinylane

import "core:fmt"
import "core:os/os2"
import "core:path/slashpath"

main :: proc() {
	fmt.println("hellope, this is tinylane, an RTL to GDS compiler!")
	// Just write an empty line rn
	write_gds_file("artifacts/testfile.gds", {0})
}

write_gds_file :: proc(filepath: string, data_to_be_written: []byte) {
	directory, filename := slashpath.split(filepath)
	error: os2.Error = os2.make_directory_all(directory)
	if error != nil {
		fmt.println("Failed to create directory:", directory, "Error:", error)
	}
	error = os2.write_entire_file_from_bytes(filepath, data_to_be_written)
	if error != nil {
		fmt.println("Failed to write GDS file:", filename, "Error:", error)
	}
}
