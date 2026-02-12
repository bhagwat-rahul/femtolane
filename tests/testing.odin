package tests

import femtolane "../src"
import "core:testing"

@(test)
test_oasis_file_creation :: proc(_: ^testing.T) {
	femtolane.main()
	femtolane.create_file_and_dir(".artifacts/testfile.oas", femtolane.OASIS_FILE_START)
}
