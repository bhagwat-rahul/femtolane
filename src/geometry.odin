// Normalise GDS, OASIS, DEF data into geometry data so we can run DRC on this format and can easily stream both out, need to think about both drc checking + rendering when designing layout
package main

GeometryPolygon :: struct {}

// IR for OASIS/GDS/DEF data that we display / run drc and do other processing on
GeometryDatabase :: struct {
	polygons: [dynamic]GeometryPolygon,
}
