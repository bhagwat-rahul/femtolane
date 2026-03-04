// For things like take user input, create files and dirs, etc

package femtolane_main

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:time"

/** Print a prompt, get yes/no user input and return a bool based on input, default false */
read_yes_no :: proc(prompt: string) -> (answer: bool = false) {
	reader: bufio.Reader; defer bufio.reader_destroy(&reader)
	bufio.reader_init(&reader, os.to_stream(os.stdin))
	for {
		fmt.println(prompt)
		user_input, _ := bufio.reader_read_string(&reader, byte('\n'))
		defer delete(user_input)
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
	if os.exists(filepath) {
		overwrite := read_yes_no("File exists, overwrite? (y/n):")
		if !overwrite {
			fmt.println("Cancelling file write"); return // TODO(rahul): Maybe don't do early returns
		}
	}

	directory, filename := slashpath.split(filepath)
	if (!os.exists(directory) && directory != "") {
		ensure(os.make_directory_all(directory) == nil, "Failed to create directory")
	}
	// TODO(rahul): If we later bufio into the file no need to do this tempfile/swap
	tmp := fmt.tprintf("%s.%d.tmp", filepath, time.Microsecond)
	ensure(os.write_entire_file(tmp, data[:]) == nil, "Temp file-write fail"); defer os.remove(tmp)
	ensure(os.rename(tmp, filepath) == nil, "Tempfile re-write fail")
}
