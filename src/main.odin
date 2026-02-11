package femtolane

import "core:fmt"

main :: proc() {
	fmt.println("hellope, this is femtolane, an RTL to OASIS compiler!")
	write_oasis_file("artifacts/testfile.oas", OASIS_FILE_START)
}
