package tests

import main "../src"
import "core:os"
import "core:testing"

// @(test)
// run_program :: proc(_: ^testing.T) {
// 	main.main()
// }

@(test)
test_pdk_loader :: proc(_: ^testing.T) {
	pdk_root := "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A"
	os.set_env("PDK_ROOT", pdk_root)
	main.openpdk_load()
}
