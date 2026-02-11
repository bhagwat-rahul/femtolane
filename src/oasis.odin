package femtolane

import "core:fmt"
import "core:os/os2"
import "core:path/slashpath"

OASIS_FILE_START :: []byte {
	0x25,
	0x53,
	0x45,
	0x4D,
	0x49,
	0x2D,
	0x4F,
	0x41,
	0x53,
	0x49,
	0x53,
	0x0D,
	0x0A,
} // corresponds to string "%SEMI-OASIS\r\n" which all oasis files start with

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
