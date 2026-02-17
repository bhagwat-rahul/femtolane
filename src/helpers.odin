// For things like take user input, create files and dirs, etc

package femtolane

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:path/slashpath"
import "core:time"

/** Print a prompt, get yes/no user input and return a bool based on input */
read_yes_no :: proc(prompt: string) -> bool {
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(os.stdin))
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
	if os.exists(filepath) {
		overwrite := read_yes_no("File exists, overwrite? (y/n):")
		if !overwrite {
			fmt.println("Cancelling file write")
			return // TODO(rahul): Don't want to use early returns
		}
	}

	directory, filename := slashpath.split(filepath)
	if (!os.exists(directory) && directory != "") {
		if os.make_directory_all(directory) != nil {
			panic("Failed to create directory")
		}
	}
	// TODO(rahul): If we later bufio into the file no need to do this tempfile/swap
	temp := fmt.tprintf("%s.%d.tmp", filepath, time.Microsecond)
	if os.write_entire_file(temp, data[:]) != nil {
		panic("Temp write failed during explicit overwrite")
	}
	if os.rename(temp, filepath) != nil {
		os.remove(temp)
		panic("Rename failed after explicit overwrite")
	}
	os.remove(temp)
}
