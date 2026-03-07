package tests

import main "../src"
import "core:testing"

@test
run_program :: proc (^testing.T)
{
	main.main()
}
