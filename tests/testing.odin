package tests

import tinylane "../src"
import "core:testing"

@(test)
test_gds_file_creation :: proc(_: ^testing.T) {
	tinylane.main()
	tinylane.write_gds_file("artifacts/testfile.gds", {10})
}
