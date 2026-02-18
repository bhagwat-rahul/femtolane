package tests

import femtolane "../src"
import "core:os"
import "core:testing"

@(test)
test_file_creation :: proc(t: ^testing.T) {
	testfilepath :: ".artifacts/testfile.oas"
	femtolane.create_file_and_dir(testfilepath, femtolane.OASIS_FILE_START)
	testing.expect(t, os.exists(testfilepath), "Testfile was not created!")
}
