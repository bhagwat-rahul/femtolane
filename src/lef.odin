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
import "core:reflect"
import "core:strings"

LEF_COMMENT :: '#'
LEF_DEFAULT_BUS_BIT_CHARS :: "[]"
LEF_DEFAULT_DIVIDER_CHAR :: '/'
LEF_STATEMENT_END_SEMICOLON :: ';'

/*
LefKeywords can be used in any order in a lef file, can't use something before defining (no forward declarations.)
The LefKeyword enum is ordered so that if things are defined in this order, all data will be defined before being used.
*/
LefKeyword :: enum {
	NONE,
	VERSION,
	BUSBITCHARS,
	DIVIDERCHAR,
	UNITS,
	MANUFACTURINGGRID,
	USEMINSPACING,
	CLEARANCEMEASURE,
	PROPERTYDEFINITIONS, // applicable to 32/28 nm and below nodes (lef 5.8)
	FIXEDMASK,
	LAYER,
	MAXVIASTACK,
	VIARULE_GENERATE,
	VIA,
	VIARULE,
	NONDEFAULTRULE,
	SITE,
	MACRO,
	BEGINEXT,
	END,
}

LefExtension :: struct {
	tag:      string,
	contents: string,
}

LefConfig :: struct {
	version:                  LefVersion,
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

LefHardSpacing :: bool // if true, then any spacing values violating requirements are treated as 'hard' violations instead of soft errors

// Min cuts allowed for any via using specified cut layer
LefLayerMinCuts :: struct {
	cut_layer_name: ^LefCutLayer, // TODO(rahul): this should only ever point to a cut layer (for now assert, ideally want compile time check)
	num_cuts:       u32, // minimum no. of cuts allowed for layer positive int
}

LefLayerIndex :: distinct u8

LefLayer :: union {
	LefCutLayer,
	LefImplantLayer,
}

// TODO(rahul): Incomplete
LefCutLayer :: struct {
	name:                         string,
	layer_idx:                    LefLayerIndex,
	ac_current_density:           LefAcCurrentDensity,
	antenna_area_diff_reduce_pwl: LefAntennaAreaDiffReducePwl,
	antenna_area_factor:          LefAntennaAreaFactor,
	antenna_area_ratio:           LefAntennaAreaRatio,
	antenna_cum_area_ratio:       LefAntennaCumAreaRatio,
}

LefImplantLayer :: struct {
	name:         string,
	layer_idx:    LefLayerIndex,
	layer_name_2: ^LefImplantLayer, // another implant layer requiring extra spacing >= minspacing from this layer
	mask_num:     u8, // how many double / triple patterning masks used here, has to be >= 2, usually 2 or 3
	property_val: ^LefPropertyDefinitions, // numerical or string val for prop that applies here (we use pointer cz easier)
	min_spacing:  f64, // min spacing, float in microns
	min_width:    f64, // float, microns
	width_rule:   LefWidthRule,
}

LefRoutingLayer :: struct {
	name:                         string,
	layer_idx:                    LefLayerIndex,
	ac_current_density:           LefAcCurrentDensity,
	antenna_area_diff_reduce_pwl: LefAntennaAreaDiffReducePwl,
	antenna_area_factor:          LefAntennaAreaFactor,
	antenna_area_ratio:           LefAntennaAreaRatio,
	antenna_cum_area_ratio:       LefAntennaCumAreaRatio,
}

LefWidthRule :: struct {
	length: f64, // microns
	width:  f64, // microns
}

LefAntennaAreaDiffReducePwl :: []f64 // defaults to 1.0 ANTENNAAREADIFFREDUCEPWL
LefAntennaAreaFactor :: f64 // default 1.0 ANTENNAAREAFACTOR (multiply factor for antenna metal calc)
LefAntennaAreaMinusDiff :: f64 // default 0.0; antenna ratio cut_area should subtract connected diffusion area
LefAntennaAreaRatio :: f64 // max legal antenna ratio using metal wire area NOT connected to diffusion diode
LefAntennaCumAreaRatio :: f64 // cumulative antenna ratio using metal wire area NOT connected to diffusion diode
LefAntennaCumDiffAreaRatio :: f64 // cumulative antenna ratio using metal wire area CONNECTED to diffusion diode, specify val or using piecewise linear format

LefAcCurrentDensity :: struct {
	value:         f64, // max val for layer in mA/um
	type:          LefAcCurrentDensityType,
	cut_area_vals: []f64, // um^2 (CUTAREA)
	// maybe use int for all these
	frequency:     []f64, // if a single val of 1 provided, ignore, just used to satisfy syntax (freq values, mega-hertz)
	width:         []f64, // wire width vals, microns
	table_entries: []f64, // max current for each freq / width pair
}

LefAcCurrentDensityType :: enum {
	PEAK,
	AVERAGE,
	RMS,
}

LefVersion :: enum {
	LEF_58, // v5.80
	LEF_60, // v6.0 (not supported by us yet)
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
	name:         string,
	diag_width:   f64, // diagonal width for layerName when 45 degree routing used (microns)
	hard_spacing: LefHardSpacing,
	min_cuts:     LefLayerMinCuts,
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
		version                  = nil,
		bus_bit_chars            = LEF_DEFAULT_BUS_BIT_CHARS,
		clearance_measure        = .EUCLIDEAN,
		divider_char             = LEF_DEFAULT_DIVIDER_CHAR,
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
		skip_newlines_and_whitespaces(&l)
		switch peek(&l) {
		case LEF_COMMENT: lef_skip_comments(l = &l)
		case: lef_handle_statement(&l, &lef_config)
		}
	}
}

lef_skip_comments :: #force_inline proc(l: ^Lexer) { for peek(l) != '\n' { advance(l) } }

lef_handle_statement :: proc(l: ^Lexer, lef_config: ^LefConfig) {
	ident := scan_ident(l)
	keyword := return_lef_keyword_from_ident(ident)

	#partial switch keyword {
	case .NONE: fmt.println("Unable to match keyword")
	case .VERSION: parse_lef_version(l, lef_config)
	case .BUSBITCHARS: parse_bus_bit_chars(l, lef_config)
	case .CLEARANCEMEASURE: // which of 2 enums
	case .DIVIDERCHAR: // single byte in quotes
	case .BEGINEXT: // Parse from BEGINEXT to ENDEXT
	case .FIXEDMASK: lef_config.fixed_mask = true
	case .LAYER: // parse layer -> END layername
	case .PROPERTYDEFINITIONS: // This has a bunch of diff cases and metadata
	case .MACRO: // Parse Macro
	case .MANUFACTURINGGRID: // Get float val (maybe scaled to int)
	case .MAXVIASTACK: // Parse int + check if lower/upper bound given else applies to all
	case .NONDEFAULTRULE: // Parse non-default rules

	case: fmt.println("TODO(rahul): Implement")
	}

}

parse_bus_bit_chars :: proc(l: ^Lexer, lef_config: ^LefConfig) {
	skip_newlines_and_whitespaces(l)
	delimiters := scan_double_quote_wrapped_string(l)
	lexer_ensure(l = l, condition = len(delimiters) == 2, err_msg = "Found more than 2 chars in bus bit chars")
	lef_config.bus_bit_chars[0] = delimiters[0]
	lef_config.bus_bit_chars[1] = delimiters[1]
	lef_consume_statement_end(l)
}

return_lef_keyword_from_ident :: proc(ident: string) -> LefKeyword {
	// TODO(rahul): Just init as rodata or something, doing this to feel clever rn
	lef_keyword_id := typeid_of(LefKeyword)
	names := reflect.enum_field_names(lef_keyword_id)
	for Keyword in LefKeyword {
		if strings.equal_fold(ident, names[Keyword]) { return Keyword }
	}
	return .NONE
}

lef_consume_statement_end :: #force_inline proc(l: ^Lexer) {
	skip_newlines_and_whitespaces(l)
	consume(l, SEMICOLON)
	skip_newlines_and_whitespaces(l)
}

parse_lef_version :: #force_inline proc(l: ^Lexer, lef_config: ^LefConfig) {
	fmt.println("versioning")
	skip_newlines_and_whitespaces(l)
	major_version := scan_ident(l)
	consume(l, DOT)
	minor_version := scan_ident(l)
	if peek(l) == DOT { consume(l, DOT) } 	// we don't care about sub minor versions for now
	switch major_version {
	case "5": lef_config.version = .LEF_58 // TODO(rahul) : Handle minor versions
	case "6": lef_config.version = .LEF_60 // TODO(rahul) : Handle minor versions
	case: lexer_panic(l, "We don't handle the lef version used")
	}
	fmt.println("TODO(rahul): Maybe we set property definition prefix based on parsed version num")
	lef_consume_statement_end(l)
}
