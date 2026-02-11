package tests

import tinylane "../src"
import "core:testing"

@(test)
test_oasis_file_creation :: proc(_: ^testing.T) {
	tinylane.main()
	tinylane.write_oasis_file("artifacts/testfile.oas", {})
}
