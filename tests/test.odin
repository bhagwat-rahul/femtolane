package tests

import main "../src"
import "core:fmt"
import "core:os"
import "core:testing"
import nc "netlist_creation"

PDK_ROOT :: "/Users/rahulbhagwat/.ciel/ciel/sky130/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/sky130A"

// Tests the frontend yosys netlist creation flow that goes from behavioral RTL -> Gate Level Netlist
@(test)
test_netlist_creation :: proc(_: ^testing.T) {
	sky130a_liberty := fmt.tprint(PDK_ROOT, "/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ff_100C_1v65.lib")
	verilog_src := "adder/adder.v"
	top := "adder"
	nc.run_yosys(verilog_src, sky130a_liberty, top)
}

@(test)
test_pdk_loader :: proc(_: ^testing.T) {

	os.set_env("PDK_ROOT", PDK_ROOT)
	main.openpdk_load()
}

@(test)
test_lexGraph :: proc(_: ^testing.T) {
	main.lexGraphNetlist("tests/netlist_creation/adder/.adder.netlist.v")
}
