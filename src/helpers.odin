// For things like take user input, create files and dirs, etc

package femtolane

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os/os2"
import "core:path/filepath"
import "core:path/slashpath"

/** Print a prompt, get yes/no user input and return a bool based on input */
read_yes_no :: proc(prompt: string) -> bool {
	reader: bufio.Reader
	bufio.reader_init(&reader, os2.to_stream(os2.stdin))
	defer bufio.reader_destroy(&reader)

	for {
		fmt.println(prompt)
		user_input, err := bufio.reader_read_string(&reader, cast(byte)'\n')
		switch user_input[0] {
		case 'y', 'Y':
			return true
		case 'n', 'N':
			return false
		case:
			fmt.println("Please enter y/n, Y/N, or yes/no.")
		}
	}
}

/** Create a file with intervening directories, ask to overwrite if exists,
	provide filepath and data in bytes to be stored */
create_file_and_dir :: proc(filepath: string, data: []byte) {
	directory, filename := slashpath.split(filepath)
	if os2.exists(filepath) {
		overwrite := read_yes_no("File exists, overwrite? (y/n):")
		if !overwrite {
			return
		}
	}
	if !os2.exists(directory) {
		error: os2.Error = os2.make_directory_all(directory)
		if error != nil {
			panic("Failed to create directory")
		}
	}
	// Handle overwriting currently panics
	file_written: os2.Error = os2.write_entire_file(filepath, data)
	if file_written != nil {
		panic("Failed to write file")
	}
}
