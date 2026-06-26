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

LEF_COMMENT :: '#'
LEF_DEFAULT_BUS_BIT_CHARS :: "[]"
LEF_DEFAULT_DIVIDER_CHAR :: '/'
LEF_STATEMENT_END_SEMICOLON :: ';'
LEF_DEFAULT_CLEARANCE_MEASURE: ClearanceMeasure : .EUCLIDEAN

/*
LefKeywords can be used in any order in a lef file, can't use something before defining (no forward declarations.)
The LefKeyword enum is ordered so that if things are defined in this order, all data will be defined before being used.
LefKeyword :: enum {
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
*/

@(rodata)
LEF_EXPECTED_UNITS := [LefUnitType]string {
	.TIME        = "NANOSECONDS",
	.CAPACITANCE = "PICOFARADS",
	.RESISTANCE  = "OHMS",
	.POWER       = "MILLIWATTS",
	.CURRENT     = "MILLIAMPS",
	.VOLTAGE     = "VOLTS",
	.DATABASE    = "MICRONS",
	.FREQUENCY   = "MEGAHERTZ",
}

LefExtension :: struct {
	tag:      string,
	contents: string,
}

LefDistance :: distinct i64
LefArea :: distinct i64
LefSizeWidthByHeight :: struct {
	size_width_dbu:  LefDistance,
	size_height_dbu: LefDistance,
}

LefDatabase :: struct {
	version:                  LefVersion,
	bus_bit_chars:            [2]byte, // delimiters on buses (escape if used elsewhere) (default [])
	clearance_measure:        ClearanceMeasure, // default euclidean
	units:                    [LefUnitType]LefUnit,
	divider_char:             byte, // express hierarchy when lef names mapped to/from other dbs (default "/", escape if used elsewhere)
	extensions:               [dynamic]LefExtension, // adds customized syntax, can be ignored by tools that don't use this syntax
	use_min_spacing:          bool, // OBS {ON / OFF}
	fixed_mask:               bool, // disallow mask shifting if true. all lef macro pin shapes need MASK assignments if true
	placement_sites:          [dynamic]LefPlacementSite,
	layers:                   [dynamic]LefLayer,
	property_definitions:     [dynamic]LefPropertyDefinitions,
	macros:                   [dynamic]LefMacro,
	manufacturing_grid_value: LefDistance,
	max_via_stack:            LefMaxViaStack,
	non_default_rules:        [dynamic]LefNonDefaultRule,
}

ClearanceMeasure :: enum {
	MAXXY, // Uses the largest x or y distances for spacing between objects.
	EUCLIDEAN, // Uses the euclidean distance for spacing between objects, i.e. sqrt(x2 + y2) (default)
}

// Defines placement grids for macro families like I/O, core, block, analog, digital, short, tall, etc.
LefPlacementSiteName :: distinct string // Not sure if i should ref things by name or pointer or pos in arr
LefPlacementSite :: struct {
	site_name:   LefPlacementSiteName,
	site_class:  LefPlacementSiteClass,
	size:        LefSizeWidthByHeight,
	symmetry:    LefPlacementSiteSymmetry,
	row_pattern: [16]LefPlacementSiteRowPattern, // if len(row_pattern) == 0, then this is a basic site that can be used for other sites
}

// Specifies previous sites that together form this site (prev sites have to be "basic" w no pattern)
LefPlacementSiteRowPattern :: struct {
	previous_site_name:   LefPlacementSiteName,
	previous_site_orient: LefPlacementSiteOrient,
}

LefPlacementSiteOrient :: enum {
	N,
	S,
	E,
	W,
	FN,
	FS,
	FE,
	FW,
}

// Created as such so we can OR different values to define combos
LefPlacementSiteSymmetry :: enum u8 {
	None = 0000_0000,
	X    = 0000_0001,
	Y    = 0000_0010,
	R90  = 0000_0100,
}

LefPlacementSiteClass :: enum {
	PAD,
	CORE,
}

LefHardSpacing :: bool // if true, then any spacing values violating requirements are treated as 'hard' violations instead of soft errors

// Min cuts allowed for any via using specified cut layer
LefLayerMinCuts :: struct {
	cut_layer_name: ^LefCutLayer, // TODO(rahul): this should only ever point to a cut layer (for now assert, ideally want compile time check)
	num_cuts:       u32, // minimum no. of cuts allowed for layer positive int
}

LefLayerIndex :: distinct u8 // not more than 255 layers, some pdks could have more but safe bet for now
LefLayerProperty :: struct {
	property_definition: ^LefPropertyDefinitions,
	value:               LefPropertyDefinitionPropertyType,
}

LefLayer :: struct {
	name:               string,
	manufacturing_grid: LefDistance,
	mask:               LefDistance,
	property:           LefLayerProperty,
	layer_data:         union {
		LefCutLayer,
		LefImplantLayer,
		LefRoutingLayer,
		LefMastersliceOverlapLayer,
	},
}

// TODO(rahul): Incomplete
LefCutLayer :: struct {
	ac_current_density:           LefAcCurrentDensity,
	antenna_area_diff_reduce_pwl: LefAntennaAreaDiffReducePwl,
	antenna_area_factor:          LefAntennaAreaFactor,
	antenna_area_ratio:           LefAntennaAreaRatio,
	antenna_cum_area_ratio:       LefAntennaCumAreaRatio,
	antenna_cum_dif_area_ratio:   LefAntennaCumDiffAreaRatio,
	// antenna_gate_plus_diff:       LefAntennaGatePlusDiff,
	// antenna_area_minus_diff:      LefAreaMinusDiff,
	// spacing_table:                LefCutLayerSpacingTable,
	// array_spacing:                LefCutLayerArraySpacing,
	// min_width:                    LefDistance,
	// enclosure:                    LefLayerEnclosure,
	// preference_closure:           LefLayerPreferenceClosure,
	// resistance:                   LefLayerResistance,
	// property:                     LefProperty,
	// dc_current_density:           LefDCCurrentDensity,
	// antenna_model:                LefAntennaModel,
	// antenna_diff_area_ratio:      LefAntennaDiffAreaRatio,
	// antenna_cum_routing_plus_cut: LefAntennaCumRoutingPlusCut,
}

LefImplantLayer :: struct {
	layer_name_2: ^LefImplantLayer, // another implant layer requiring extra spacing >= minspacing from this layer
	mask_num:     u8, // how many double / triple patterning masks used here, has to be >= 2, usually 2 or 3
	min_spacing:  LefDistance, // min spacing, float in microns
	min_width:    LefDistance, // float, microns
	width_rule:   LefWidthRule,
}

LefRoutingLayer :: struct {
	ac_current_density:           LefAcCurrentDensity,
	antenna_area_diff_reduce_pwl: LefAntennaAreaDiffReducePwl,
	antenna_area_factor:          LefAntennaAreaFactor,
	antenna_area_ratio:           LefAntennaAreaRatio,
	antenna_cum_area_ratio:       LefAntennaCumAreaRatio,
}

LefMastersliceOverlapLayer :: struct {
	type: enum {
		MASTERSLICE,
		OVERLAP,
	},
}

LefWidthRule :: struct {
	length: f64, // microns
	width:  f64, // microns
}

LefAntennaAreaDiffReducePwl :: []f64 // default 1.0 ANTENNAAREADIFFREDUCEPWL
LefAntennaAreaFactor :: f64 // default 1.0 ANTENNAAREAFACTOR (multiply factor for antenna metal calc)
LefAntennaAreaMinusDiff :: f64 // default 0.0; antenna ratio cut_area should subtract connected diffusion area
LefAntennaAreaRatio :: f64 // max legal antenna ratio using metal wire area NOT connected to diffusion diode
LefAntennaCumAreaRatio :: f64 // cumulative antenna ratio using metal wire area NOT connected to diffusion diode
LefAntennaCumDiffAreaRatio :: f64 // cumulative antenna ratio using metal wire area CONNECTED to diffusion diode, specify val or using piecewise linear format

LefAcCurrentDensity :: struct {
	value:         f64, // max val for layer in mA/um
	type:          LefAcCurrentDensityType,
	cut_area_vals: []LefArea,
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

LefPropertyDefinitionObjectType :: enum {
	LAYER,
	LIBRARY,
	MACRO,
	NONDEFAULTRULE,
	PIN,
	VIA,
	VIARULE,
}

LefPropertyDefinitionPropertyType :: union {
	int,
	f64,
	string,
}

// [PROPERTYDEFINITIONS
// [objectType propName propType [RANGE min max]
// [value | "stringValue"]
// ;] ...
// END PROPERTYDEFINITIONS]
LefPropertyDefinitions :: struct {
	object_type:           LefPropertyDefinitionObjectType,
	property_name:         string,
	property_type:         LefPropertyDefinitionPropertyType,
	range:                 [2]string,
	value:                 string, // for some things the implementation will select value
	library_property_type: LefLibraryProperties, // prefixed with version num like 'LEF58_' for v5.8
}

LefMacro :: struct {
	name:                string,
	class:               LefMacroClass,
	fixed_mask:          bool,
	foreign_cell_name:   bool, // TODO(rahul): Implement foreign keyword
	// origin:              LefOriginPt,
	electric_equivalent: ^LefMacro, // `EEG macroName` (Electrically equivalent, used for multiple impl's of smae OR gate, etc.)
	size:                LefSizeWidthByHeight,
	symmetry:            LefPlacementSiteSymmetry,
	site:                LefPlacementSite,
	// pin : LefPin
	// TODO(rahul): Bunch of other things within each macro
}

LefMacroForeignOffsetOrientation :: struct {
	x_value:     i32,
	y_value:     i32,
	orientation: LefPlacementSiteOrient, // Default value is N
}

LefMacroPin :: struct {
	name: string,
	// taper_rule: LefTaperRule,
	// other pin statements
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
	value:            int,
	bottom_top_layer: []LefLayer, // instead of layer index just store slice
}

LefNonDefaultRule :: struct {
	name:         string,
	diag_width:   f64, // diagonal width for layerName when 45 degree routing used (microns)
	hard_spacing: LefHardSpacing,
	min_cuts:     LefLayerMinCuts,
}

LefUnit :: distinct i64

// *CURRENTLY* , all LefUnits apart from distance (DATABASE) and CAPACITANCE are fixed
LefUnitType :: enum {
	TIME, // default 1 ns = 1000 DBUs
	CAPACITANCE, // default 1 pF = 1,000,000 DBUs (user can override)
	RESISTANCE, // default 1 ohm = 10,000 DBUs
	POWER, // default 1 milliwatt = 10,000 DBUs
	CURRENT, // default 1 milliamp = 10,000 DBUs
	VOLTAGE, // default 1 volt = 1000 DBUs
	DATABASE, // (distance) User defined
	FREQUENCY, // default 1 ns = 10,000 DBUs
}

// How many units = 1 micron
LefConvertFactorDistanceMicrons :: enum {
	DBU_100,
	DBU_200,
	DBU_400,
	DBU_800,
	DBU_1000,
	DBU_2000,
	DBU_4000,
	DBU_8000,
	DBU_10000,
	DBU_20000,
}

read_lef :: proc(filepath: string = "", allocator: mem.Allocator = context.temp_allocator) {
	data, err := os.read_entire_file_from_path(filepath, allocator)
	ensure(err == nil, "Error reading file")

	l: Lexer = {
		src      = data,
		idx      = 0,
		filepath = filepath,
	}

	lef_database := LefDatabase {
		version                  = LefVersion{},
		bus_bit_chars            = LEF_DEFAULT_BUS_BIT_CHARS,
		clearance_measure        = LEF_DEFAULT_CLEARANCE_MEASURE,
		divider_char             = LEF_DEFAULT_DIVIDER_CHAR,
		units                    = [LefUnitType]LefUnit{},
		placement_sites          = make([dynamic]LefPlacementSite), // TODO(rahul): makes sense for soa but things will be in macros
		use_min_spacing          = false, // default false since reccomended in spec
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
		case: lef_handle_statement(&l, &lef_database)
		}
	}
}

lef_skip_comments :: #force_inline proc(l: ^Lexer) { for peek(l) != '\n' { advance(l) } }

lef_handle_statement :: proc(l: ^Lexer, lef_database: ^LefDatabase, allocator: mem.Allocator = context.temp_allocator) {
	ident := scan_ident_ascii_upper(l)
	skip_newlines_and_whitespaces(l)
	switch ident {
	case "VERSION": set_config_lef_version(l, lef_database)
	case "BUSBITCHARS": set_config_bus_bit_chars(l, lef_database)
	case "DIVIDERCHAR": set_config_divider_char(l, lef_database)
	case "UNITS": set_config_units(l, lef_database)
	case "MANUFACTURINGGRID": set_config_manufacturing_grid(l, lef_database)
	case "USEMINSPACING": set_config_use_min_spacing(l, lef_database)
	case "CLEARANCEMEASURE": set_config_clearance_measure(l, lef_database)
	case "PROPERTYDEFINITIONS": set_config_property_definitions(l, lef_database)
	case "FIXEDMASK": lef_database.fixed_mask = true // true if statement exists
	case "LAYER": lef_create_layer(l, lef_database)
	case "MAXVIASTACK": // Parse int + check if lower/upper bound given else applies to all
	case "VIA":
	case "VIARULE": // NOTE(rahul): Handle both regular viarule and viarule generate here
	case "NONDEFAULTRULE": // Parse non-default rules
	case "SITE": lef_create_macro_placement_site(l, lef_database)
	case "MACRO": lef_create_macro(l, lef_database)
	case "BEGINEXT": // Parse from BEGINEXT to ENDEXT
	case "END":
	case: lexer_panic(l = l, err_msg = fmt.tprintf("Found unimplemented keyword %s", ident))
	}
}

/* Start set config functions */

set_config_bus_bit_chars :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	delimiters := scan_double_quote_wrapped_string(l)
	lexer_ensure(l = l, condition = len(delimiters) == 2, err_msg = "Found more than 2 chars in bus bit chars")
	lef_database.bus_bit_chars[0] = delimiters[0]
	lef_database.bus_bit_chars[1] = delimiters[1]
	lef_consume_statement_end(l)
}

set_config_divider_char :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	divider := scan_double_quote_wrapped_string(l)
	lexer_ensure(l = l, condition = len(divider) == 1, err_msg = "Divider should be a single char")
	lef_database.divider_char = divider[0]
	lef_consume_statement_end(l)
}

set_config_lef_version :: #force_inline proc(l: ^Lexer, lef_database: ^LefDatabase) {
	major_version := peek(l)
	advance(l)
	lexer_consume(l, DOT)
	minor_version := peek(l)
	advance(l)
	if peek(l) == DOT { lexer_consume(l, DOT) } 	// we don't care about sub minor versions for now
	switch major_version {
	case '5': lef_database.version = .LEF_58 // TODO(rahul) : Handle minor versions
	case '6': lef_database.version = .LEF_60 // TODO(rahul) : Handle minor versions
	case: lexer_panic(l, "We don't handle the lef version used")
	}
	lef_consume_statement_end(l)
}

// TODO(rahul): this function is only stubbed for now, fix it for all cases
set_config_property_definitions :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	set_prop_def_loop: for {
		prop_def: LefPropertyDefinitions = {}
		skip_newlines_and_whitespaces(l)
		object_type := scan_ident_ascii_upper(l)
		skip_newlines_and_whitespaces(l)
		switch object_type {
		case "LAYER": prop_def.object_type = .LAYER
		case "LIBRARY": prop_def.object_type = .LIBRARY
		case "MACRO": prop_def.object_type = .MACRO
		case "NONDEFAULTRULE": prop_def.object_type = .NONDEFAULTRULE
		case "PIN": prop_def.object_type = .PIN
		case "VIA": prop_def.object_type = .VIA
		case "VIARULE": prop_def.object_type = .VIARULE
		case "END":
			lef_consume_section_end(l, "PROPERTYDEFINITIONS")
			break set_prop_def_loop
		case: lexer_panic(l, "Unknown property definition object type")
		}
		prop_def.property_name = scan_ident_ascii_upper(l)
		skip_newlines_and_whitespaces(l)
		property_type := scan_ident_ascii_upper(l)
		switch property_type {
		case "INTEGER": prop_def.property_type = int{}
		case "REAL": prop_def.property_type = f64{}
		case "STRING": prop_def.property_type = string{}
		case: lexer_panic(l, "Unknown property definition property type")
		}
		skip_newlines_and_whitespaces(l)
		prop_def.value = scan_ident_ascii_upper(l) if peek(l) != SEMICOLON else ""
		skip_newlines_and_whitespaces(l)
		lef_consume_statement_end(l)
		append(&lef_database.property_definitions, prop_def)
	}
}

set_config_units :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	set_units_loop: for {
		skip_newlines_and_whitespaces(l)
		unit_string := scan_ident_ascii_upper(l)
		skip_newlines_and_whitespaces(l)
		unit_kind: LefUnitType
		switch unit_string {
		case "TIME": unit_kind = .TIME
		case "CAPACITANCE": unit_kind = .CAPACITANCE
		case "RESISTANCE": unit_kind = .RESISTANCE
		case "POWER": unit_kind = .POWER
		case "CURRENT": unit_kind = .CURRENT
		case "VOLTAGE": unit_kind = .VOLTAGE
		case "DATABASE": unit_kind = .DATABASE
		case "FREQUENCY": unit_kind = .FREQUENCY
		case "END":
			lef_consume_section_end(l, "UNITS")
			break set_units_loop
		case: lexer_panic(l, fmt.tprint("Unkown unit type", unit_string))
		}
		unit_name := scan_ident_ascii_upper(l)
		lexer_ensure(l = l, condition = unit_name == LEF_EXPECTED_UNITS[unit_kind], err_msg = "Wrong unit for type")
		skip_newlines_and_whitespaces(l)
		value := scan_lef_decimal_scaled_i64(l, 1)
		lexer_ensure(l, value > 0, "Unit conversion factor must be positive")
		lef_database.units[unit_kind] = LefUnit(value)
		lef_consume_statement_end(l)
	}
}

set_config_manufacturing_grid :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	dbu_per_micron := i64(lef_database.units[.DATABASE])
	lexer_ensure(l, dbu_per_micron > 0, "DATABASE MICRONS must precede MANUFACTURINGGRID")
	lef_database.manufacturing_grid_value = LefDistance(scan_lef_decimal_scaled_i64(l, dbu_per_micron))
	lexer_ensure(l, lef_database.manufacturing_grid_value > 0, "Manufacturing grid must be positive")
	lef_consume_statement_end(l)
}

set_config_clearance_measure :: #force_inline proc(l: ^Lexer, lef_database: ^LefDatabase) {
	lef_database.clearance_measure = .MAXXY if scan_ident_ascii_upper(l) == "MAXXY" else .EUCLIDEAN
	lef_consume_statement_end(l)
}

set_config_use_min_spacing :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	lexer_ensure(l = l, condition = scan_ident_ascii_upper(l) == "OBS", err_msg = "No OBS keyword after USEMINSPACING")
	skip_newlines_and_whitespaces(l)
	min_spacing_bool := scan_ident_ascii_upper(l)
	lexer_ensure(l = l, condition = (min_spacing_bool == "ON" || min_spacing_bool == "OFF"), err_msg = "obs is something other than on/off")
	lef_database.use_min_spacing = (min_spacing_bool == "ON")
	lef_consume_statement_end(l)
}

/* End set config functions */

/* Begin LEF data structure creation */

// SITE siteName
// CLASS {PAD | CORE} ;
// [SYMMETRY {X | Y | R90} ... ;]
// [ROWPATTERN {previousSiteName siteOrient} ... ;]
// SIZE width BY height ;
// END siteName

// SITE Fsite
// CLASS CORE ;
// SIZE 4.0 BY 7.0 ; #4.0 um width, 7.0 um height
// END Fsite
// SITE Lsite
// CLASS CORE ;
// SIZE 6.0 BY 7.0 ; #6.0 um width, 7.0 um height
// END Lsite
// SITE mySite
// ROWPATTERN Fsite N Lsite N Lsite FS ; #Pattern of F + L + flipped L
// SIZE 16.0 BY 7.0 ; #Width = width(F + L + L)
// END mySite
lef_create_macro_placement_site :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	created_site := LefPlacementSite {
		site_name = LefPlacementSiteName(scan_ident_ascii_upper(l)),
	}
	placement_loop: for {
		skip_newlines_and_whitespaces(l)
		placement_keyword := scan_ident_ascii_upper(l)
		skip_newlines_and_whitespaces(l)
		switch placement_keyword {
		case "CLASS":
			placement_class := scan_ident_ascii_upper(l)
			lexer_ensure(l = l, condition = placement_class == "CORE" || placement_class == "PAD", err_msg = "Unexpected placement class")
			created_site.site_class = .CORE if placement_class == "CORE" else .PAD
		case "SIZE":
			dbu_per_micron := i64(lef_database.units[.DATABASE])
			lexer_ensure(l, dbu_per_micron > 0, "DATABASE MICRONS must precede SITE SIZE")
			created_site.size.size_width_dbu = LefDistance(scan_lef_decimal_scaled_i64(l, dbu_per_micron))
			skip_newlines_and_whitespaces(l)
			by_keyword := scan_ident_ascii_upper(l)
			lexer_ensure(l = l, condition = by_keyword == "BY", err_msg = "No BY keyword between width/length")
			created_site.size.size_height_dbu = LefDistance(scan_lef_decimal_scaled_i64(l, dbu_per_micron))
		case "SYMMETRY": symmetry_loop: for {
					skip_newlines_and_whitespaces(l)
					if peek(l) == SEMICOLON { break symmetry_loop }
					sym_type := scan_ident_ascii_upper(l)
					switch sym_type {
					case "X": created_site.symmetry |= .X
					case "Y": created_site.symmetry |= .Y
					case "R90": created_site.symmetry |= .R90
					case: lexer_panic(l, fmt.tprint("Invalid symmetry type", sym_type))
					}
				}
		case "ROWPATTERN": for i := 0; i <= 15 && peek(l) != SEMICOLON; i += 1 {
					previous_site_name := LefPlacementSiteName(scan_ident_ascii_upper(l)) // we need to ensure len(row_pattern) == 0 for all
					skip_newlines_and_whitespaces(l)
					previous_site_orient: LefPlacementSiteOrient
					site_orient_str := scan_ident_ascii_upper(l)
					switch site_orient_str {
					case "N": previous_site_orient = .N
					case "S": previous_site_orient = .S
					case "E": previous_site_orient = .E
					case "W": previous_site_orient = .W
					case "FN": previous_site_orient = .FN
					case "FS": previous_site_orient = .FS
					case "FE": previous_site_orient = .FE
					case "FW": previous_site_orient = .FW
					}
					created_site.row_pattern[i] = LefPlacementSiteRowPattern {
						previous_site_name   = previous_site_name,
						previous_site_orient = previous_site_orient,
					}
				}
		case "END":
			lef_consume_section_end(l, string(created_site.site_name))
			break placement_loop
		case: lexer_panic(l, fmt.tprint("Unhandled keyword", placement_keyword, "in create_macro_placement for site", created_site.site_name))
		}
		lef_consume_statement_end(l)
	}
	append(&lef_database.placement_sites, created_site)
}

lef_create_macro :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	/* Scan macro name and other things within MACRO section and create / append to dynamic macro array */
}

lef_create_layer :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	new_layer: LefLayer
	layer_name := scan_ident_ascii_upper(l)
	skip_newlines_and_whitespaces(l)
	lexer_ensure(l = l, condition = scan_ident_ascii_upper(l) == "TYPE", err_msg = "Layer type not defined right after LAYER keyword")
	skip_newlines_and_whitespaces(l)
	layer_type := scan_ident_ascii_upper(l)
	switch layer_type {
	case "CUT": new_layer.layer_data = LefCutLayer{}
	case "MASTERSLICE": new_layer.layer_data = LefMastersliceOverlapLayer {
				type = .MASTERSLICE,
			}
	case "OVERLAP": new_layer.layer_data = LefMastersliceOverlapLayer {
				type = .OVERLAP,
			}
	case "IMPLANT": new_layer.layer_data = LefImplantLayer{}
	case "ROUTING": new_layer.layer_data = LefRoutingLayer{}
	case: lexer_panic(l, "Unknown layer type")
	}
	lef_consume_statement_end(l)
	layer_loop: for {
		layer_property := scan_ident_ascii_upper(l)
		switch layer_property {
		case "END": break layer_loop
		case "MANUFACTURINGGRID":
		case "PROPERTY":
			skip_newlines_and_whitespaces(l)
			prop_name := scan_ident_ascii_upper(l)
			skip_newlines_and_whitespaces(l)
			prop_val := scan_double_quote_wrapped_string(l)
			for &property in lef_database.property_definitions {
				if prop_name == property.property_name {new_layer.property = LefLayerProperty {
						property_definition = &property,
						value               = prop_val,
					}
				}
			}
			lexer_ensure(l, new_layer.property.property_definition != nil, "Property name not found")
			lef_consume_statement_end(l)
		case "MASK":
		}
		switch &layer in new_layer.layer_data {
		case LefCutLayer:
		case LefImplantLayer:
		case LefRoutingLayer:
		case LefMastersliceOverlapLayer:
		case: lexer_panic(l, fmt.tprint("Unhandled layer type", layer_type))
		}
	}
	lef_consume_section_end(l, layer_name)
	append(&lef_database.layers, new_layer)
}

/* End LEF data structure creation */

/* LEF helper procs */
lef_consume_statement_end :: #force_inline proc(l: ^Lexer) {
	skip_newlines_and_whitespaces(l)
	lexer_consume(l, SEMICOLON)
	skip_newlines_and_whitespaces(l)
}

lef_consume_section_end :: #force_inline proc(l: ^Lexer, statement: string) {
	skip_newlines_and_whitespaces(l)
	lexer_ensure(l = l, condition = scan_ident_ascii_upper(l) == statement, err_msg = "Incorrect keyword after section end")
	skip_newlines_and_whitespaces(l)
}

/* TODO(rahul): scan_lef_decimal_scaled_i64 is LLM generated, review and fix if needed */
scan_lef_decimal_scaled_i64 :: #force_inline proc(l: ^Lexer, scale: i64) -> i64 {
	skip_newlines_and_whitespaces(l)
	negative := peek(l) == '-'
	if negative { advance(l) }
	value: i128
	digit_count := 0
	for '0' <= peek(l) && peek(l) <= '9' {
		value = value * 10 + i128(peek(l) - '0'); digit_count += 1; advance(l)
	}
	fraction_digits := 0
	if peek(l) == '.' {
		advance(l)
		for '0' <= peek(l) && peek(l) <= '9' {
			value = value * 10 + i128(peek(l) - '0'); digit_count += 1; fraction_digits += 1; advance(l)
		}
	}
	lexer_ensure(l, digit_count > 0, "Expected decimal number")
	exponent := 0
	if peek(l) == 'e' || peek(l) == 'E' {
		advance(l); exponent_negative := false
		if peek(l) == '-' || peek(l) == '+' { exponent_negative = peek(l) == '-'; advance(l) }
		lexer_ensure(l, '0' <= peek(l) && peek(l) <= '9', "Expected decimal exponent")
		for '0' <= peek(l) && peek(l) <= '9' { exponent = exponent * 10 + int(peek(l) - '0'); advance(l) }
		if exponent_negative { exponent = -exponent }
	}
	result, power := value * i128(scale), fraction_digits - exponent
	if power < 0 { for _ in 0 ..< -power { result *= 10 } } else {
		divisor: i128 = 1; for _ in 0 ..< power { divisor *= 10 }
		lexer_ensure(l, result % divisor == 0, "Decimal is not exactly representable at this scale"); result /= divisor
	}
	if negative { result = -result }
	lexer_ensure(l, i128(min(i64)) <= result && result <= i128(max(i64)), "Scaled decimal exceeds i64 range")
	return i64(result)
}

lef_dbu_per_micron :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> i64 {
	dbu := i64(db.units[.DATABASE])
	lexer_ensure(l, dbu > 0, "DATABASE MICRONS must be known before parsing LEF distances")
	return dbu
}

/* TODO(rahul): Review and uncomment as needed and when used
scan_lef_distance :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefDistance {
	return LefDistance(scan_lef_decimal_scaled_i64(l, lef_dbu_per_micron(l, db)))
}

scan_lef_positive_distance :: #force_inline proc(l: ^Lexer, db: ^LefDatabase, msg: string) -> LefDistance {
	d := scan_lef_distance(l, db)
	lexer_ensure(l, d > 0, msg)
	return d
}
scan_lef_area :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefArea {
	dbu := lef_dbu_per_micron(l, db)
	return LefArea(scan_lef_decimal_scaled_i64(l, dbu * dbu))
}
*/

/* End LEF helper procs*/
