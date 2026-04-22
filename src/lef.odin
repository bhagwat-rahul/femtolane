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
	VERSION,
	BUSBITCHARS,
	DIVIDERCHAR,
}

read_lef :: proc(filepath: string = "", allocator: mem.Allocator = context.temp_allocator) {
	data, err := os.read_entire_file_from_path(filepath, allocator)
	ensure(err == nil, "Error reading file")

	l: Lexer = {
		src      = data,
		idx      = 0,
		filepath = filepath,
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
	case .VERSION:
	case .BUSBITCHARS:
	case .DIVIDERCHAR:
	}

}

return_lef_keyword_from_ident :: proc(ident: string) -> LefKeyword {
	if strings.equal_fold(ident, "busbitchars") { return .BUSBITCHARS }
	if strings.equal_fold(ident, "dividerchar") { return .DIVIDERCHAR }
	return .NONE
}
