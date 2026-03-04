package tests

import fl_main "../src"
import fl_oas "../src/oasis"
import "core:os"
import "core:testing"

@(test)
test_file_creation :: proc(t: ^testing.T) {
	testfilepath :: ".artifacts/testfile.oas"
	fl_main.create_file_and_dir(testfilepath, fl_oas.OASIS_FILE_START)
	testing.expect(t, os.exists(testfilepath), "Testfile was not created!")
}
