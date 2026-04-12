// Common utilities and types
package main

import "core:os"

writeDataToFile :: #force_inline proc(filepath: string, data: ^[]byte) {
	ensure(os.write_entire_file_from_bytes(filepath, data^) == nil, "Error writing file")
}
