package tests

import main "../src"
import "core:testing"

@(test)
run_program :: proc(_: ^testing.T) {
	main.main()
}
