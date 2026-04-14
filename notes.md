# Notes

> General notes about things i learn, discover and decide as i build this.
This is an informal doc only meant for myself as a scratchpad during development.
Some of these ideas will make their way into the project, some things will be documented in the README.

## Aim:
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


## Discoveries:

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

## Decision:

1. Don't spend too much time atm doing things like rtl->netlist->ir & ir(db)/def->oas
just use libs for all of this for now. Focus on accelerating the main step, PnR.
Once that is done, we want to make sure we have great infra to be able to onboard new PDKs quickly
and be able to go from PDK access -> people being able to use it for rtl->oas, < 1 week.
To be able to do that we need to define a clean interface step (can look like an IR or something else)
for our pnr tool so we can adapt to opendb, etc. or our own parsers and oasis writers down the road.


## Discoveries during running yosys for getting an rtl-netlist:

yosys doesn't run it's own tcl interpreter.
we need to pass certain flags to convert things in rtl when things
don't directly map to stdcells.

## Misc.
Frontend RTL -> Netlist flow is called logic synthesis (Frontend (FE))
& Netlist -> GDS(OASIS) flow is called physical design (Place and Route, Backend (BE))

Language parsing is pretty much a solved problem using recursive descent/lookahead parsing, etc.
We don't want to build an entire AST and hence don't need to do recursive descent.
Don't want AST since we're not doing any verification, etc. of the lang.
We want to build a graph (hypergraph), for which a simple lexing step should suffice.
This hypergraph approach is way more performant and the correct approach for PnR use-cases.

### (from htamas presentation in TinyTapeout)
Synthesis (frontend rtl to gl netlist) does:

1. Parsing      : Read and convert to AST
2. Bit Blasting : Split everything into single bit units
3. Elaboration  : Convert always blocks into logic gates
4. Techmapping  : Convert logic gates to stdcells
5. Exporting    : Writing out (GL) gate level netlist

Then implementation stage does:

1. Floorplanning : Setup layout database (die area, pins, grids, PDN (Power Delivery Network))
2. Placement     : Assign stdcells to grid locations
3. Routing       : Draw physical wires between terminals connected in netlist
4. Patching      : Fix DRC violations by adding small pieces of metal
5. Streamout     : Export the internal database as a GDS/OASIS file along with a LEF file

## More notes from using yosys to do the frontend

Due to how different PDKs are shipped and the assumptions yosys/other tools make, significant tcl scripting maybe needed
Eg. The structure of gf180 isn't very yosys-abc friendly so it takes a ton of scripting for it to work
To fix this problem there is also [OpenPDK](https://github.com/RTimothyEdwards/open_pdks) by Tim Edwards which installs the PDKs in a format oss flows can use
Can be a good idea to look at OpenPDK and try to implement some kind of similar pdk parse and normalise layer, not sure how many hacks it will need to support open/closed pdks

## PDK standardisation

A PDK doesnt just contain files to be read, it also contains executable rule logic for drc checks, drc v lvs, and signoff on final oas/gds.
These rules are usually shipped as interpreted scripts to be run by proprietary synopsys/cadence programs etc.
So you could do PnR yourself for a lot of these but have to use prop software for signoff.
Since signoff and drc rules are encoded within the rule-deck and there's tons of them it's not practical to run own pnr and proprietaery signoff in a loop;
as your pnr tool will keep producing drc violations if it doesn't have all the info.
this is a good problem to think about and fix when it comes to proprietary pdk support

Something that tools do is run simplified approximations of the drc during pnr since pnr needs super quick feedback (microseconds)
Then during final signoff you can run full drc. The approximations come from the simplified tech descriptions provided by pdk (tlef, lef)

## From call with Tim Edwards (magic vlsi maintainer)

LEF is usually enough for PnR DRC checks, a lot of the signoff drc checks don't have much to do with PnR
So integrating an external PnR tool shouldn't be too difficult even for proprietary PDK since lef's standardised
Challenges with standardising PDK distribution are more so political not technical.

## Liberty File Notes (While working on GL lex->graph step)

Lib files play a role in both frontend synthesis/tech-mapping + backend (pnr etc.)
They are essentially a look-up table of IP (std-cells) to spice simulations so you don't have to sim everytime.
Contain things like stdcell area, ports and metadata of cells, timing related info, capacitances, etc.
Also have a lot of general metadata/waveform for whatever corner, temperature, voltage, etc. they are for.

Since Gate Level netlists instantiate std-cells we will need to be able to parse those and their metadata from .lib files pre PnR.

The liberty spec defines 3 top level groups:-
1. Library group (Info/metadata about the library, default values)
2. Cell & model group (model group obsolete now, the idea was to provide generics applicable to multiple cells)
3. Pin group (pins on cells)

Within each there are 3 types of attributes (ways to convey information):-
1. Simple Attributes (key:val)
2. Complex Attributes (maps)
3. Group Statements (recursive structs containing subgroups / simple attributes within, eg. Cell, Pin groups.)

The only top level group is library and that is always the root of a lib file.
Lib files contain scaling attributes which basically say if the value of this measurement was x at these env conditions, here's how much to scale it by for diff temp/voltage/env conditions.
These aren't super reliable but are provided since you can't have simulations for all conditions (PDKs do provide multiple lib files at diff corners and conditions though)
