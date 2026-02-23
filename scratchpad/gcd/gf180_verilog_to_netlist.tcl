# TODO(rahul): Make script modular and run in tests via odin test runner
# Path to liberty file, and stdcells, etc. whatever else, should be parametrised.

read_verilog gcd.v

hierarchy -check -top gcd

proc
opt
fsm
opt
memory
opt

# preserve after lowering
setattr -set keep 1 [all_outputs]
setattr -set keep 1 [all_inputs]

dffunmap

hilomap -hicell gf180mcu_fd_sc_mcu7t5v0__tieh_1 Y \
        -locell gf180mcu_fd_sc_mcu7t5v0__tiel_1 Y

dfflibmap -liberty /Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib

abc -D 1 \
    -liberty /Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib

opt_clean
splitnets -ports
setundef -zero
clean

write_verilog -noexpr gcd_pnr.v
