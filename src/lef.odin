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
	BEGINEXT,
	FIXEDMASK,
	LAYER,
	PROPERTYDEFINITIONS, // applicable to 32/28 nm and below nodes (lef 5.8)
	MACRO,
	MANUFACTURINGGRID,
	MAXVIASTACK,
	NONDEFAULTRULE,
}

LefExtension :: struct {
	tag:      string,
	contents: string,
}

LefConfig :: struct {
	bus_bit_chars:            [2]byte, // delimiters on buses (escape if used elsewhere) (default [])
	clearance_measure:        ClearanceMeasure, // default euclidean
	divider_char:             byte, // express hierarchy when lef names mapped to/from other dbs (default "/", escape if used elsewhere)
	extensions:               [dynamic]LefExtension, // adds customized syntax, can be ignored by tools that don't use this syntax
	fixed_mask:               bool, // disallow mask shifting if true. all lef macro pin shapes need MASK assignments if true
	layers:                   [dynamic]LefLayer,
	property_definitions:     [dynamic]LefPropertyDefinitions,
	macros:                   [dynamic]LefMacro,
	manufacturing_grid_value: f64, // Maybe int instead?
	max_via_stack:            LefMaxViaStack,
	non_default_rules:        [dynamic]LefNonDefaultRule,
}

ClearanceMeasure :: enum {
	MAXXY, // Uses the largest x or y distances for spacing between objects.
	EUCLIDEAN, // Uses the euclidean distance for spacing between objects, i.e. sqrt(x2 + y2) (default)
}

LefLayer :: struct {
	name:       string,
	type:       LefLayerType,
	layer_data: [dynamic]string, // TODO(rahul): add more types to this struct instead of catch-all data
}

LefLayerType :: enum {
	CUT,
	IMPLANT,
	MASTERSLICE,
	OVERLAP,
	ROUTING,
}

LefVersion :: enum {
	LEF_58, // v5.80
	LEF_60, // v 6.0 (not supported by us yet)
}

LefLibraryProperties :: enum {
	CELL_EDGE_SPACING,
	LAYER_MASK_SHIFT,
	OA_LAYER_MAP, // Open Access Layer Map
}

LefPropertyDefinitions :: struct {
	name:                  string,
	lef_version:           LefVersion,
	library_property_type: LefLibraryProperties, // prop type string prefixed with version num like 'LEF58_' for v5.8
	// TODO(rahul): this has more metadata in it (need it to support advanced nodes)
}

LefMacro :: struct {
	name:  string,
	class: LefMacroClass,
	// TODO(rahul): Bunch of other things within each macro
}

LefMacroClass :: enum {
	COVER,
	RING,
	BLOCK,
	PAD,
	CORE,
	ENDCAP,
}

LefMaxViaStack :: struct {
	value:        int,
	bottom_layer: ^LefLayer,
	top_layer:    ^LefLayer,
}

LefNonDefaultRule :: struct {
	name: string,
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
		bus_bit_chars            = "[]",
		clearance_measure        = .EUCLIDEAN,
		divider_char             = '/',
		extensions               = make([dynamic]LefExtension, allocator), // store all extensions in this
		fixed_mask               = false, // default false, make true if sttmt found
		layers                   = make([dynamic]LefLayer, allocator),
		property_definitions     = make([dynamic]LefPropertyDefinitions, allocator),
		macros                   = make([dynamic]LefMacro, allocator),
		manufacturing_grid_value = 0, // not sure yet if good to start w 0 default
		max_via_stack            = LefMaxViaStack{},
		non_default_rules        = make([dynamic]LefNonDefaultRule, allocator),
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
	case .BEGINEXT: // Parse from BEGINEXT to ENDEXT
	case .FIXEDMASK: // flip lef_config.fixed_mask to true
	case .LAYER: // parse layer -> END layername
	case .PROPERTYDEFINITIONS: // This has a bunch of diff cases and metadata
	case .MACRO: // Parse Macro
	case .MANUFACTURINGGRID: // Get float val (maybe scaled to int)
	case .MAXVIASTACK: // Parse int + check if lower/upper bound given else applies to all
	case .NONDEFAULTRULE: // Parse non-default rules

	}

}

return_lef_keyword_from_ident :: proc(ident: string) -> LefKeyword {
	if strings.equal_fold(ident, "BUSBITCHARS") { return .BUSBITCHARS }
	if strings.equal_fold(ident, "CLEARANCEMEASURE") { return .CLEARANCEMEASURE }
	if strings.equal_fold(ident, "DIVIDERCHAR") { return .DIVIDERCHAR }
	if strings.equal_fold(ident, "BEGINEXT") { return .BEGINEXT }
	if strings.equal_fold(ident, "FIXEDMASK") { return .FIXEDMASK }
	if strings.equal_fold(ident, "LAYER") { return .LAYER }
	if strings.equal_fold(ident, "PROPERTYDEFINITIONS") { return .PROPERTYDEFINITIONS }
	if strings.equal_fold(ident, "MACRO") { return .MACRO }
	if strings.equal_fold(ident, "MANUFACTURINGGRID") { return .MANUFACTURINGGRID }
	if strings.equal_fold(ident, "MAXVIASTACK") { return .MAXVIASTACK }
	if strings.equal_fold(ident, "NONDEFAULTRULE") { return .NONDEFAULTRULE }

	return .NONE
}
