read_liberty -lib /Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib

read_verilog gcd.v

hierarchy -check -top gcd

proc
opt

fsm
opt

memory
opt

# BREAK enable/reset FFs into mux + plain FF
dffunmap

# bind VDD/VSS so FF signature matches liberty
hilomap -hicell gf180mcu_fd_sc_mcu7t5v0__tieh_1 Y \
        -locell gf180mcu_fd_sc_mcu7t5v0__tiel_1 Y

# NOW map FFs (before abc!)
dfflibmap -liberty /Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib

# map combinational logic
abc -liberty /Users/rahulbhagwat/Documents/git/explorations/gf180mcu-pdk/libraries/gf180mcu_fd_sc_mcu7t5v0/latest/liberty/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib

clean
opt

write_verilog gcd_mapped.v
