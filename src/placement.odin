package main

// run macro placement and other big block placement

PlacementGuide :: enum {
	NONE, // place wherever you want
	SOFT, // try to cluster these cells together (regardless of where and in what area)
	GUIDE, // try to place in defined area
	REGION, // must place in defined area
	FENCE, // must place in defined area and not place anything else in this area
}

PlacementBlockage :: enum {
	NONE, // no blockage
	HARD, // nothing can be placed here
	SOFT, // can't be used during placement (for stdcells), can use during optimization pass
	PARTIAL, // don't utilize too much of this area (utilise set %)
	HALO, // area outside a macro to keep stdcells away from it (halo like pattern)
}
