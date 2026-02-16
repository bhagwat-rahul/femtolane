package femtolane

// Oasis file creation according to the oasis spec

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

// Currently makes a corrupted file, we need to make this ULEB128 encoded (Unsigned Little Endian Base 128)
create_oasis_data :: proc() -> (buf: [dynamic]byte) {
	buf = make([dynamic]byte, 0)
	append(&buf, ..OASIS_FILE_START)
	append(&buf, ..OASIS_START)
	append(&buf, ..OASIS_VERSION)
	append(&buf, ..OASIS_UNIT)
	append(&buf, ..OASIS_END)
	return buf
}
