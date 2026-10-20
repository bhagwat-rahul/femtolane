package main

// NOTE(rahul): What even is a pdk except an electrical + geometric characterisation of stdcells & their properties + rules to use them / widely used hard macros? (at least for digital), analog can have spice and primitive devices etc.
PDK :: struct {
	name, path:                                                                                         string,
	lef_filepaths, def_filepaths, liberty_filepaths, verilog_filepaths, gds_filepaths, oasis_filepaths: []string,
}

// TODO(rahul): load in all lef and lib files? (on the larger side a pdk is ~2TB, so do we load instant or no? maybe we mmap stuff since files in pdk will be static and then stream things into memory as we need?)
pdk_load_files :: proc() {  }
