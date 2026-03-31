# femtolane

A performant, simple *physical design tool* to convert your RTL (Register-Transfer Level) design to an OASIS (Open Artwork System Interchange Standard) binary.

Will be written in Odin with no dependencies except odin stdlib, and possibly `vendor:raylib` for the ui.
Will be statically linked and shipped platform-native for frictionless use.

Meant to be a much faster and frictionless version of [OpenROAD](https://github.com/The-OpenROAD-Project/OpenROAD)

## How to run

- To build the project you will need the Odin compiler and stdlib.
- You can install it by following the instuctions on [Odin's Official Website](https://odin-lang.org/docs/install/)
- While the GUI is not functional yet, it uses raylib, you can install raylib [here](https://www.raylib.com/)
- Once Odin is installed build the program by doing `odin build src` from repo root.
- Then run the created binary with `./<binary_name> lexgraph tests/netlist_creation/adder/.adder.netlist.v`
- This will run the lex -> hypergraph creation step.
- This is not fully implemented so you might have to read the code or my notes in `notes.md` to understand what it is supposed to do.
