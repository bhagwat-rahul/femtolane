package tests

import fl_main "../src"
import fl_oas "../src/oasis"
import "core:os"
import "core:testing"
import netlist_creator "netlist_creation"

@(test)
test_file_creation :: proc(t: ^testing.T) {
	testfilepath :: ".artifacts/testfile.oas"
	fl_main.create_file_and_dir(testfilepath, fl_oas.OASIS_FILE_START)
	testing.expect(t, os.exists(testfilepath), "Testfile was not created!")
}

// @(test)
// test_frontend_netlist_creator :: proc(t: ^testing.T) {
// 	testfilepath :: ".artifacts/testfile.oas"
// 	// TODO(rahul): for file in files in netlist_creation dir, make netlist for all dirs
// 	netlist_creator.run_yosys("input_rtl_filepath", "liberty_filepath")
// 	outfilepath := ""
// 	testing.expect(t, os.exists(outfilepath), "Testfile was not created!")
// }
