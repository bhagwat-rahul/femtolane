package femtolane_oasis

// Oasis file creation according to the oasis spec,
// some things need to be written as raw bytes,
// like the file_start magic string, etc.
// others need to be encoded with varint/uleb128

OASIS_FILE_START :: []byte {
	0x25,
	0x53,
	0x45,
	0x4D,
	0x49,
	0x2D,
	0x4F,
	0x41,
	0x53,
	0x49,
	0x53,
	0x0D,
	0x0A,
} // corresponds to string "%SEMI-OASIS\r\n" which all oasis files start with

OASIS_START :: []byte{0x01} // Start bit
OASIS_VERSION :: []byte{0x03, 0x31, 0x2E, 0x30} // Version of oasis used
OASIS_UNIT :: []byte{0x00} // Unit (microns, etc.)
OASIS_END :: []byte{0x02} // End bit

// This will look-up what to encode as uleb128 vs not and stream into the file eventually
create_oasis_data :: proc() -> (buf: []byte) {
	dynamic_buf := make([dynamic]byte)
	append(&dynamic_buf, ..OASIS_FILE_START)
	append(&dynamic_buf, ..OASIS_START)
	append(&dynamic_buf, ..OASIS_VERSION)
	append(&dynamic_buf, ..OASIS_UNIT)
	append(&dynamic_buf, ..OASIS_END)
	return dynamic_buf[:]
}
