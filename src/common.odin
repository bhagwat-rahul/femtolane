// Common utilities and types
package main
import "core:fmt"
import "core:os"

writeDataToFile :: #force_inline proc(filepath: string, data: ^[]byte) {
	err := os.write_entire_file_from_bytes(filepath, data^)
	ensure(err == nil, fmt.tprint("Error: ", err))
}
