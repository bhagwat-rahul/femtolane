# Netlist Creation

This folder contains data needed to run/test this rtl (netlist) -> gds flow.
Every folder will have a verilog design and the top level folder will be used to synth these into a netlist.
Top level netlist_creator.odin orchestrates the creation of netlists from all designs.
Starting with simple single-file designs going to larger multi-file projects.
We will be using this for as long as we are using yosys for lowering rtl->netlist.
Once synthesis is built into the tool the orchestrator script can change to use our tool instead of yosys.
The emitted netlist can also be single-file / multi-file (folder)
Ideally we want to also create some metadata about what pdk we used, etc.
