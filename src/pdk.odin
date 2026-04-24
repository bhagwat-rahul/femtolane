/* nodeinfo.json at open_pdk root
foundry       :	Short name of the foundry, equal to the foundry directory root, above the PDK variants.
foundry-name  : Long name of the foundry.
node          :	The name of the PDK variant
feature-size  : The foundry process feature size (e.g. 130nm)
status        : "active" or "inactive". May be used by tools to present or hide specific PDK variants.
description   :	Long text description of the process variant (e.g., 6-metal stack + MiM caps)
options       :	List of options, corresponding to the definitions used in the Makefile and passed to preproc.py.
stdcells      :	List of standard cell libraries available for this PDK variant.
iocells       :	List of I/O pad cell libraries available for this PDK variant.
*/

package main

// func's to help with loading a pdk setting up pdk specific structs, provide a browsing interface
// for now, let's start with supporting openPDK and then go on to generalise this.

import "core:fmt"
import "core:os"

PDK_ROOT :: "PDK_ROOT" // This is the env var that contains path to pdk root
OPENPDK_REF :: "libs.ref" // Foundry IP
OPENPDK_TECH :: "libs.tech" // Tool specific (probably won't need at all)

pdk_status :: enum {
	active,
	inactive,
}
// Load from nodeinfo.json in .config for openpdk pdk's
OPENPDK_METADATA :: struct {
	foundry:      string,
	foundry_name: string,
	node:         string,
	feature_size: string,
	description:  string,
	options:      string,
	status:       pdk_status,
	stdcells:     []string,
	iocells:      []string,
	version:      string,
}

// set PDK_ROOT to dir with libs.ref and libs.tech (openpdk format)
openpdk_load :: proc() {
	pdk_root := os.get_env(PDK_ROOT, context.temp_allocator)
	defer delete(pdk_root)
	ensure(len(pdk_root) > 0, "Please set env var PDK_ROOT")

	reflibs, err := os.read_all_directory_by_path(fmt.tprintf("%s/%s/", pdk_root, OPENPDK_REF), context.temp_allocator)
	defer delete(reflibs)
	ensure(err == nil, fmt.tprintf("Error reading libs.ref: %v", err))
	for dir in reflibs { defer delete(dir.fullpath) }
}
