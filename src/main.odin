package tinylane

import "core:fmt"
import "core:os/os2"
import "core:path/slashpath"

main :: proc() {
	fmt.println("hellope, this is tinylane, an RTL to OASIS compiler!")
	write_oasis_file("artifacts/testfile.oas", {}) // Write empty byte
}

write_oasis_file :: proc(filepath: string, data_to_be_written: []byte) {
	directory, filename := slashpath.split(filepath)
	error: os2.Error = os2.make_directory_all(directory)
	if error != nil {
		fmt.println("Failed to create directory:", directory, "Error:", error)
	}
	error = os2.write_entire_file_from_bytes(filepath, data_to_be_written)
	if error != nil {
		fmt.println("Failed to write oasis file:", filename, "Error:", error)
	}
}
