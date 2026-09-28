// Parse GDS data into geometry IR
package main

import "core:os"

gds_streamout_lef_def_database_to_gds :: proc(lef_db: LefDatabase, def_db: DefDatabase, gds_outfilepath: string) -> os.Error {
	gds_data: []byte // construct data to be streamed out to gds file
	return os.write_entire_file_from_bytes(gds_outfilepath, gds_data)
}
