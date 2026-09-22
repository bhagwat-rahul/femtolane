package main

// DEF files are supposed to contain intermediate reps of your layout during PnR before you streamout to a GDSII (or similar) format

/*
A Design Exchange Format (DEF) file contains the design-specific information of a circuit and is a representation of the design at any point during the layout process. The DEF file is an ASCII representation using the syntax conventions described in “Typographic and Syntax Conventions” on page 9.

DEF conveys logical design data to, and physical design data from, place-and-route tools.
Logical design data can include internal connectivity (represented by a netlist), grouping information, and physical constraints.
Physical data includes placement locations and orientations, routing geometry data, and logical design changes for backannotation.
Place-and-route tools also can read physical design data, for example, to perform ECO (engineering change order; i.e. when something for a 'frozen' stage needs to be changed) changes.

For standard-cell-based/ASIC flow tools, floorplanning is part of the design flow. You typically
use the various floorplanning commands to interactively create a floorplan. This data then
becomes part of the physical data output for the design using the ROWS, TRACKS,
GCELLGRID, and DIEAREA statements. You also can manually enter this data into DEF to
create the floorplan.

It is legal for a DEF file to contain only floorplanning information, such as ROWS.
In many cases, the DEF netlist information is in a separate format, such as Verilog, or in a separate DEF file.
It is also common to have a DEF file that only contains a COMPONENTS section to pass placement information.
*/
