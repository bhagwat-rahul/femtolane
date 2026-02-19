<!--General notes about things i learn, discover and decide as i build this.
This is an informal doc only meant for myself as a scratchpad during development.
Some of these ideas will make their way into the project, some things will be documented
in the README.
-->

We want to build an rtl → oasis flow.
Usually the way these work is, we load tech.LEF and stdcell LEF files
which are the physical rules and cell geometry needed for doing place and route on the chip.
There are tons of LEFs in a PDK, and the tcl script that scripts
the entire rtl-oas flow orchestrates which std_cell library (.lib)
and LEF to use, and we may also decide what timing corner we want to use (slow, typical, fast)
for synthesis / STA.
Then we turn the RTL into a gate-level netlist using the Liberty (.lib) timing/logic models.
The .lib models tell us what logical functions a stdcell implements and its characteristics.
It is then our job to lower the RTL into technology-independent logic primitives
(AND, OR, XOR, MUX, etc.), and map that logic graph to available stdcells
by instantiating cells that implement those functions in the netlist.
Then do simulation / STA (optionally), then place and route the netlist using the LEF geometry,
producing a DEF (placed + routed layout database), and finally stream out OASIS.
Don't have to streamout def from in-memory db, can streamout to oasis directly,
def will be needed for interoperability with other tools for sta, etc.
Currently we will only do:
Verilog → gate-level netlist → placed+routed DEF → OASIS
No sim/STA. For sim/STA use external tools for now.
We want our tool to have a central interface that Tcl scripts, Python scripts and the GUI can use.
In the GUI we can configure the same things easily like we would in a script,
and it can also write out that config in the form of a script
(should be able to load script into GUI and vice versa (Python/Tcl)).
Tool should be SIMD by default, first pass CPU parallel then make GPU parallel.

Discoveries:-

1. The system-verilog -> netlist step will take months to implement.
i.e the subset of it used in asic's directly (not testbench or fpga constructs)
2. Can do 2005 verilog in a few weeks. However the rtl->netlist lowering is a negligible part
of the runtime of rtl -> oas, takes seconds/minutes vs hours/days for PnR.
3. Pnr uses heuristic algos like maze routing w A*, etc. to route over a large search space.
Is an NP hard optimization problem so finding the best soln is exponentially hard, we can use heuristics
to speed up and get a good enough soln. Good enough as in within 10-20% optimal (based on limited
heuristics benchmarks). Eg. Finding best for 50 cells takes minutes, 100 (hours-days) 200 (years),
1000s (longer than universe), typical asic SoC has 100s of millions. We can run full for 50-100,
and compare with our heuristics -> if good use same heuristics on full block.
Implementing a synthesizable SystemVerilog → netlist frontend sufficient for real ASIC RTL (excluding simulation-only constructs) is a months-long effort due to elaboration, typing, and process scheduling semantics.

Decision:-

1. Don't spend too much time atm doing things like rtl->netlist->ir & ir(db)/def->oas
just use libs for all of this for now. Focus on accelerating the main step, PnR.
Once that is done, we want to make sure we have great infra to be able to onboard new PDKs quickly
and be able to go from PDK access -> people being able to use it for rtl->oas, < 1 week.
To be able to do that we need to define a clean interface step (can look like an IR or something else)
for our pnr tool so we can adapt to opendb, etc. or our own parsers and oasis writers down the road.
