package tests

import femtolane "../src"
import "core:testing"

@(test)
test_oasis_file_creation :: proc(_: ^testing.T) {
	femtolane.main()
	femtolane.write_oasis_file("artifacts/testfile.oas", {})
}
