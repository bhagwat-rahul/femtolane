// /* tLEF */
// [VERSION statement]
// [BUSBITCHARS statement]
// [DIVIDERCHAR statement]
// [UNITS statement]
// [MANUFACTURINGGRID statement]
// [USEMINSPACING statement]
// [CLEARANCEMEASURE statement ;]
// [PROPERTYDEFINITIONS statement]
// [FIXEDMASK ;]
// [LAYER (Nonrouting) statement
// | LAYER (Routing) statement] ...
// [MAXVIASTACK statement]
// [VIA statement] ...
// [VIARULE statement] ...
// [VIARULE GENERATE statement] ...
// [NONDEFAULTRULE statement] ...
// [SITE statement] ...
// [BEGINEXT statement] ...
// [END LIBRARY]
// /* end tLEF */
// /* LEF */
// [VERSION statement]
// [BUSBITCHARS statement]
// [DIVIDERCHAR statement]
// [VIA statement] ...
// [SITE statement]
// [MACRO statement
// [PIN statement] ...
// [OBS statement ...] ] ...
// [BEGINEXT statement] ...
// [END LIBRARY]
// /* end LEF */

package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

LEF_COMMENT :: '#'

LefKeyword :: enum {
	NONE,
	BUSBITCHARS,
	CLEARANCEMEASURE,
	DIVIDERCHAR,
}

LefConfig :: struct {
	bus_bit_chars:     [2]byte, // delimiters on buses (escape if used elsewhere) (default [])
	clearance_measure: ClearanceMeasure, // default euclidean
	divider_char:      byte, // express hierarchy when lef names mapped to/from other dbs (default "/", escape if used elsewhere)
}

ClearanceMeasure :: enum {
	MAXXY, // Uses the largest x or y distances for spacing between objects.
	EUCLIDEAN, // Uses the euclidean distance for spacing between objects, i.e. sqrt(x2 + y2) (default)
}

read_lef :: proc(filepath: string = "", allocator: mem.Allocator = context.temp_allocator) {
	data, err := os.read_entire_file_from_path(filepath, allocator)
	ensure(err == nil, "Error reading file")

	l: Lexer = {
		src      = data,
		idx      = 0,
		filepath = filepath,
	}

	lef_config: LefConfig = {
		bus_bit_chars     = "[]",
		clearance_measure = .EUCLIDEAN,
		divider_char      = '/',
	}

	for l.idx < len(l.src) {
		switch peek(&l) {
		case LEF_COMMENT: lef_skip_comments(l = &l)
		case: handle_keyword(&l)
		}
	}
}

lef_skip_comments :: #force_inline proc(l: ^Lexer) { for peek(l) != '\n' { advance(l) } }

handle_keyword :: proc(l: ^Lexer) {
	ident := scan_ident(l)
	keyword := return_lef_keyword_from_ident(ident)

	switch keyword {
	case .NONE: fmt.println("Unable to match keyword")
	case .BUSBITCHARS: // get 2 byte pair enclosed in quotes
	case .CLEARANCEMEASURE: // which of 2 enums
	case .DIVIDERCHAR: // single byte in quotes

	}

}

return_lef_keyword_from_ident :: proc(ident: string) -> LefKeyword {
	if strings.equal_fold(ident, "BUSBITCHARS") { return .BUSBITCHARS }
	if strings.equal_fold(ident, "CLEARANCEMEASURE") { return .CLEARANCEMEASURE }
	if strings.equal_fold(ident, "DIVIDERCHAR") { return .DIVIDERCHAR }

	return .NONE
}
