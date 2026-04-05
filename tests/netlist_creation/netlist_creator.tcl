yosys -import

set input_rtl_file $::env(INPUT_RTL_FILE)
set top_module $::env(TOP_MODULE)
set lib_file $::env(LIB_FILE)
set output_netlist $::env(OUTPUT_NETLIST)

puts "Synthesizing $input_rtl_file with top $top_module; Using liberty $lib_file; Writing mapped netlist to $output_netlist"

read_liberty -lib $lib_file
read_verilog $input_rtl_file
hierarchy -check -top $top_module

# Lower behavioral RTL into Yosys' internal generic netlist.
synth -top $top_module

# Map sequential logic first, then map combinational logic into stdcells.
dfflibmap -liberty $lib_file
abc -liberty $lib_file

setundef -zero
clean -purge
check
stat -liberty $lib_file

write_verilog -noattr -noexpr -nodec $output_netlist
