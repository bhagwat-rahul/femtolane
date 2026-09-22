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

LEF_COMMENT :: '#'
LEF_DEFAULT_BUS_BIT_CHARS :: "[]"
LEF_DEFAULT_DIVIDER_CHAR :: '/'
LEF_STATEMENT_END_SEMICOLON :: ';'
LEF_DEFAULT_CLEARANCE_MEASURE: LefClearanceMeasure : .EUCLIDEAN

YOCTOFARADS_PER_PICOFARAD : i64 : 1_000_000_000_000

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
LefArea :: distinct u64
LefSizeWidthByHeight :: struct {
	size_width_dbu:  LefDistance,
	size_height_dbu: LefDistance,
}

LefTime :: distinct i64
LefCapacitance :: distinct i64 // yoctoFarads
LefResistance :: distinct i64
LefPower :: distinct i64
LefCurrent :: distinct i64
LefVoltage :: distinct i64
LefFrequency :: distinct i64

LefCapacitancePerDistance :: distinct i64 // yF / um
LefCapacitancePerArea :: distinct i64 // yF / um2

LefAntennaModel :: enum {
	OXIDE1, // default
	OXIDE2,
	OXIDE3,
	OXIDE4,
}

LefMaskNum :: enum {
	SINGLE, // not specified
	DOUBLE_MASK, // 2
	TRIPLE_MASK, // 3
}

LefDatabase :: struct {
	version:                  LefVersion,
	bus_bit_chars:            [2]byte, // delimiters on buses (escape if used elsewhere) (default [])
	clearance_measure:        LefClearanceMeasure, // default euclidean
	units:                    [LefUnitType]LefUnit,
	divider_char:             byte, // express hierarchy when lef names mapped to/from other dbs (default "/", escape if used elsewhere)
	extensions:               [dynamic]LefExtension, // adds customized syntax, can be ignored by tools that don't use this syntax
	use_min_spacing:          bool, // OBS {ON / OFF}
	fixed_mask:               bool, // disallow mask shifting if true. all lef macro pin shapes need MASK assignments if true
	placement_sites:          [dynamic]LefPlacementSite,
	layers:                   [dynamic]LefLayer,
	vias:                     [dynamic]LefVia,
	via_rules:                [dynamic]LefViaRule,
	property_definitions:     [dynamic]LefPropertyDefinitions,
	macros:                   [dynamic]LefMacro,
	manufacturing_grid_value: LefDistance,
	max_via_stack:            LefMaxViaStack,
	non_default_rules:        [dynamic]LefNonDefaultRule,
}

LefClearanceMeasure :: enum {
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

LefVia :: struct {
	name:       string,
	default:    bool,
	mask_num:   LefMaskNum,
	enclosures: [4]LefDistance,
	offset:     [4]LefDistance,
	origin:     [2]LefDistance,
	layers:     [3]^LefLayer, // [bottomMetalLayer, CutLayer, TopMetalLayer]
	layer_shapes: [3][dynamic]LefDistance,
}

LefViaRule :: struct {
	name:          string,
	generate:      bool, // is it a viarule generate? typically yes unless legacy lef
	mask_num:      LefMaskNum,
	enclosures:    [3][2]LefDistance,
	layers:        [3]^LefLayer,
	layer_shapes:  [3][dynamic]LefDistance,
	spacing:       [3][2]LefDistance, // can be overridden by SPACING ADJACENTCUTS in cut layer statement.
}

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
	mask:               LefMaskNum, // will usually be empty but can be 2 or 3 if specified
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
	min_width:                    LefDistance,
	min_spacing :                 LefDistance,
	enclosures:                   [4]LefDistance, // 0 and 1 is ABOVE overhang 1-2, 2 and 3 is BELOW overhang 1-2
	// preference_closure:           LefLayerPreferenceClosure,
	// resistance:                   LefLayerResistance,
	// property:                     LefProperty,
	// dc_current_density:           LefDCCurrentDensity,
	antenna_model:                LefAntennaModel,
	// antenna_diff_area_ratio:      LefAntennaDiffAreaRatio,
	// antenna_cum_routing_plus_cut: LefAntennaCumRoutingPlusCut,
	resistance:                   LefResistance,
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
	antenna_model:                LefAntennaModel,
	antenna_cum_area_ratio:       LefAntennaCumAreaRatio,
	direction:                    LefRoutingLayerDirection,
	spacing_rules:                LefRoutingLayerSpacingRules,
	min_width:                    LefDistance,
	width_rule:                   LefWidthRule,
	pitch:                        [2]LefDistance, // if only 1 distance present then both are same x == y
	offset:                       [2]LefDistance, // if 1 specified then it's for preffered direction routing tracks, if 2 then 1st is x offset for vertical 2nd is y for horizontal
	area:                         LefArea,
	spacing_table:                LefSpacingTable,
	thickness:                    LefDistance,
	min_size:                     [dynamic][2]LefDistance, // array of minwidth, minlength
	edge_capacitance:             LefCapacitancePerDistance,
	capacitance:                  LefCapacitancePerArea,
	resistance:                   LefResistance,
}

LefSpacingTable :: struct {
	parallel_run_length: [dynamic]LefDistance,
	width:               [dynamic][dynamic]LefDistance,
}

LefRoutingLayerSpacingRules :: struct
{
	min_spacing  : LefDistance,
	samenet      : bool, // min spacing rule only applies to same-net metal
	pgonly       : bool, // min spacing only applies to same-net that's also power or gnd
	notch_length : LefDistance,
	// TODO(rahul): a lot more semantic stuff here
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

LefRoutingLayerDirection :: enum {
	HORIZONTAL,
	VERTICAL,
	DIAG45,
	DIAG135,
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

LefMacroForeignCell :: struct {
	name   : string,
	points : [2]LefDistance, // TODO(rahul): This is orientation not point
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
	foreign_cell:        LefMacroForeignCell,
	origin:              [2]LefDistance, // TODO(rahul): Maybe lefcoord?
	electric_equivalent: ^LefMacro, // `EEG macroName` (Electrically equivalent, used for multiple implementations of same OR gate, etc.)
	size:                LefSizeWidthByHeight,
	symmetry:            LefPlacementSiteSymmetry,
	site:                LefPlacementSite,
	pins:                [dynamic]LefMacroPin,
	obstruction:                 [dynamic]LefMacroObstructionLayerGeometry,
	// TODO(rahul): Bunch of other things within each macro
}

LefMacroForeignOffsetOrientation :: struct {
	x_value:     i32,
	y_value:     i32,
	orientation: LefPlacementSiteOrient, // Default value is N
}

LefMacroPinUse :: enum {
	SIGNAL, // default
	ANALOG,
	POWER,
	GROUND,
	CLOCK
}

LefMacroPin :: struct {
	name:      string,
	direction: LefMacroPinDirection,
	ports:     [dynamic]LefMacroPinPort,
	use:       LefMacroPinUse,
	// taper_rule: LefTaperRule,
	// other pin statements
}

LefMacroPinPort :: struct {
	layer:  ^LefLayer,
	points: [dynamic]LefDistance,
	// points in rect or poly
}

LefMacroObstructionLayerGeometry :: struct {
	layer:  ^LefLayer,
	points: [dynamic][dynamic]LefDistance,
}

LefMacroPinDirection :: enum {
	INPUT,
	OUTPUT,
	INOUT
}

LefMacroClass :: enum {
	// Core types
	CORE, // default class if unspecified
	CORE_FEEDTHRU,
	CORE_TIEHIGH,
	CORE_TIELOW,
	CORE_SPACER,
	CORE_ANTENNACELL,
	CORE_WELLTAP,
	// Cover Types
	COVER,
	COVER_BUMP,
	// Ring Type
	RING,
	// Block Types
	BLOCK,
	BLOCK_BLACKBOX,
	BLOCK_SOFT,
	// Pad Types
	PAD,
	PAD_INPUT,
	PAD_OUTPUT,
	PAD_INOUT,
	PAD_POWER,
	PAD_SPACER,
	PAD_AREAIO,
	// Endcap Types
	ENDCAP_PRE,
	ENDCAP_POST,
	ENDCAP_TOPLEFT,
	ENDCAP_TOPRIGHT,
	ENDCAP_BOTTOMLEFT,
	ENDCAP_BOTTOMRIGHT
}

LefMaxViaStack :: struct {
	value:            int,
	bottom_top_layer: []LefLayer, // instead of layer index just store slice
}

LefNonDefaultRule :: struct {
	name:         string,
	diag_width:   f64, // diagonal width for layerName when 45 degree routing used (microns)
	hard_spacing: bool, // if true, then any spacing values violating requirements are treated as 'hard' violations instead of soft errors
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

lef_create_new_database :: proc(allocator : mem.Allocator) -> LefDatabase {
	lef_database := LefDatabase {
		version                  = LefVersion{},
		bus_bit_chars            = LEF_DEFAULT_BUS_BIT_CHARS,
		clearance_measure        = LEF_DEFAULT_CLEARANCE_MEASURE,
		divider_char             = LEF_DEFAULT_DIVIDER_CHAR,
		units                    = [LefUnitType]LefUnit{},
		placement_sites          = make([dynamic]LefPlacementSite, allocator), // TODO(rahul): makes sense for soa but things will be in macros
		use_min_spacing          = false, // default false since reccomended in spec
		extensions               = make([dynamic]LefExtension, allocator), // store all extensions in this
		fixed_mask               = false, // default false, make true if sttmt found
		layers                   = make([dynamic]LefLayer, allocator),
		vias                     = make([dynamic]LefVia, allocator),
		via_rules                = make([dynamic]LefViaRule, allocator),
		property_definitions     = make([dynamic]LefPropertyDefinitions, allocator),
		macros                   = make([dynamic]LefMacro, allocator),
		manufacturing_grid_value = 0, // not sure yet if good to start w 0 default
		max_via_stack            = LefMaxViaStack{},
		non_default_rules        = make([dynamic]LefNonDefaultRule, allocator),
	}
	return lef_database
}

lef_read_file_into_database :: proc(filepath: string = "", allocator: mem.Allocator = context.temp_allocator, lef_database : ^LefDatabase) {
	resolved_lef_path := filepath
	if len(resolved_lef_path) == 0 {
		fmt.println("Please select a liberty file")
		resolved_lef_path = pick_path(File_Picker_Request{mode = .Open_File, title = "Select Gate-Level Netlist"})
	}
	ensure(len(resolved_lef_path) > 0, "Program terminated as you did not select a liberty file")

	data, err := os.read_entire_file_from_path(resolved_lef_path, allocator)
	ensure(err == nil, fmt.tprint("Lef File Read Error:", err))

	l: Lexer = {
		src      = data,
		idx      = 0,
		filepath = resolved_lef_path,
	}

	for l.idx < len(l.src) {
		lef_skip_whitespace_and_comments(&l)
		if l.idx >= len(l.src) { break }
		lef_handle_statement(&l, lef_database, allocator)
	}
}

lef_skip_whitespace_and_comments :: #force_inline proc(l: ^Lexer) {
    for {
        skip_newlines_and_whitespaces(l)
        if peek(l) != LEF_COMMENT { break }
        for l.idx < len(l.src) && peek(l) != '\n' { advance(l) }
    }
}

lef_handle_statement :: proc(l: ^Lexer, lef_database: ^LefDatabase, allocator: mem.Allocator = context.temp_allocator) {
	ident := scan_ident_ascii_upper(l)
	lef_skip_whitespace_and_comments(l)
	switch ident {
	case "VERSION": lef_set_config_version(l, lef_database)
	case "BUSBITCHARS": lef_set_config_bus_bit_chars(l, lef_database)
	case "DIVIDERCHAR": lef_set_config_divider_char(l, lef_database)
	case "UNITS": lef_set_config_units(l, lef_database)
	case "MANUFACTURINGGRID": lef_set_config_manufacturing_grid(l, lef_database)
	case "USEMINSPACING": lef_set_config_use_min_spacing(l, lef_database)
	case "CLEARANCEMEASURE": lef_set_config_clearance_measure(l, lef_database)
	case "PROPERTYDEFINITIONS": lef_set_config_property_definitions(l, lef_database)
	case "FIXEDMASK": lef_database.fixed_mask = true // true if statement exists
	case "LAYER": lef_create_layer(l, lef_database, allocator)
	case "MAXVIASTACK": // Parse int + check if lower/upper bound given else applies to all
	case "VIA": lef_create_via(l, lef_database, allocator)
	case "VIARULE": lef_create_viarule(l, lef_database, allocator)
	case "NONDEFAULTRULE": // Parse non-default rules
	case "SITE": lef_create_macro_placement_site(l, lef_database)
	case "MACRO": lef_create_macro(l, lef_database, allocator)
	case "BEGINEXT": // Parse from BEGINEXT to ENDEXT
	case "END": lef_consume_section_end(l, "LIBRARY")
	case: lexer_panic(l = l, err_msg = fmt.tprintf("Found unimplemented keyword %s", ident))
	}
}

/* Start set config functions */

lef_set_config_bus_bit_chars :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	delimiters := scan_double_quote_wrapped_string(l)
	lexer_ensure(l = l, condition = len(delimiters) == 2, err_msg = "Found more than 2 chars in bus bit chars")
	lef_database.bus_bit_chars[0] = delimiters[0]
	lef_database.bus_bit_chars[1] = delimiters[1]
	lef_consume_statement_end(l)
}

lef_set_config_divider_char :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	divider := scan_double_quote_wrapped_string(l)
	lexer_ensure(l = l, condition = len(divider) == 1, err_msg = "Divider should be a single char")
	lef_database.divider_char = divider[0]
	lef_consume_statement_end(l)
}

lef_set_config_version :: #force_inline proc(l: ^Lexer, lef_database: ^LefDatabase) {
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
lef_set_config_property_definitions :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	set_prop_def_loop: for {
		prop_def: LefPropertyDefinitions = {}
		lef_skip_whitespace_and_comments(l)
		object_type := scan_ident_ascii_upper(l)
		lef_skip_whitespace_and_comments(l)
		if object_type == "END" {
			lef_consume_section_end(l, "PROPERTYDEFINITIONS")
			break set_prop_def_loop
		}
		value, ok := reflect.enum_from_name(LefPropertyDefinitionObjectType, object_type)
		lexer_ensure(l, ok, "Unknown property definition object type")
		prop_def.object_type = value
		prop_def.property_name = scan_ident_ascii_upper(l)
		lef_skip_whitespace_and_comments(l)
		property_type := scan_ident_ascii_upper(l)
		switch property_type {
		case "INTEGER": prop_def.property_type = int{}
		case "REAL": prop_def.property_type = f64{}
		case "STRING": prop_def.property_type = string{}
		case: lexer_panic(l, "Unknown property definition property type")
		}
		lef_skip_whitespace_and_comments(l)
		prop_def.value = scan_ident_ascii_upper(l) if peek(l) != SEMICOLON else ""
		lef_skip_whitespace_and_comments(l)
		lef_consume_statement_end(l)
		append(&lef_database.property_definitions, prop_def)
	}
}

lef_set_config_units :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	set_units_loop: for {
		lef_skip_whitespace_and_comments(l)
		unit_string := scan_ident_ascii_upper(l)
		lef_skip_whitespace_and_comments(l)
		if unit_string == "END" {
			lef_consume_section_end(l, "UNITS")
			break set_units_loop
		}
		unit_kind, ok := reflect.enum_from_name(LefUnitType, unit_string)
		lexer_ensure(l, ok, fmt.tprint("Unkown unit type", unit_string))
		unit_name := scan_ident_ascii_upper(l)
		lexer_ensure(l = l, condition = unit_name == LEF_EXPECTED_UNITS[unit_kind], err_msg = "Wrong unit for type")
		lef_skip_whitespace_and_comments(l)
		value := lef_scan_decimal_scaled_i64(l, 1)
		lexer_ensure(l, value > 0, "Unit conversion factor must be positive")
		lef_database.units[unit_kind] = LefUnit(value)
		lef_consume_statement_end(l)
	}
}

lef_set_config_manufacturing_grid :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	dbu_per_micron := i64(lef_database.units[.DATABASE])
	lexer_ensure(l, dbu_per_micron > 0, "DATABASE MICRONS must precede MANUFACTURINGGRID")
	lef_database.manufacturing_grid_value = LefDistance(lef_scan_decimal_scaled_i64(l, dbu_per_micron))
	lexer_ensure(l, lef_database.manufacturing_grid_value > 0, "Manufacturing grid must be positive")
	lef_consume_statement_end(l)
}

lef_set_config_clearance_measure :: #force_inline proc(l: ^Lexer, lef_database: ^LefDatabase) {
	lef_database.clearance_measure = .MAXXY if scan_ident_ascii_upper(l) == "MAXXY" else .EUCLIDEAN
	lef_consume_statement_end(l)
}

lef_set_config_use_min_spacing :: proc(l: ^Lexer, lef_database: ^LefDatabase) {
	lexer_ensure(l = l, condition = scan_ident_ascii_upper(l) == "OBS", err_msg = "No OBS keyword after USEMINSPACING")
	lef_skip_whitespace_and_comments(l)
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
		lef_skip_whitespace_and_comments(l)
		placement_keyword := scan_ident_ascii_upper(l)
		lef_skip_whitespace_and_comments(l)
		switch placement_keyword {
		case "CLASS":
			placement_class := scan_ident_ascii_upper(l)
			lexer_ensure(l = l, condition = placement_class == "CORE" || placement_class == "PAD", err_msg = "Unexpected placement class")
			created_site.site_class = .CORE if placement_class == "CORE" else .PAD
		case "SIZE":
			dbu_per_micron := i64(lef_database.units[.DATABASE])
			lexer_ensure(l, dbu_per_micron > 0, "DATABASE MICRONS must precede SITE SIZE")
			created_site.size.size_width_dbu = lef_scan_distance(l, lef_database)
			lef_skip_whitespace_and_comments(l)
			by_keyword := scan_ident_ascii_upper(l)
			lexer_ensure(l = l, condition = by_keyword == "BY", err_msg = "No BY keyword between width/length")
			created_site.size.size_height_dbu = lef_scan_distance(l, lef_database)
		case "SYMMETRY": symmetry_loop: for {
					lef_skip_whitespace_and_comments(l)
					if peek(l) == SEMICOLON { break symmetry_loop }
					sym_type := scan_ident_ascii_upper(l)
					sym_type_enum, ok := reflect.enum_from_name(LefPlacementSiteSymmetry, sym_type)
					lexer_ensure(l,ok, fmt.tprint("Invalid symmetry type", sym_type))
					created_site.symmetry |= sym_type_enum
				}
		case "ROWPATTERN": for i := 0; i <= 15 && peek(l) != SEMICOLON; i += 1 {
					previous_site_name := LefPlacementSiteName(scan_ident_ascii_upper(l)) // we need to ensure len(row_pattern) == 0 for all
					lef_skip_whitespace_and_comments(l)
					site_orient_str := scan_ident_ascii_upper(l)
					previous_site_orient, ok := reflect.enum_from_name(LefPlacementSiteOrient, site_orient_str)
					lexer_ensure(l, ok, fmt.tprint("Unknown site orient", site_orient_str))
					created_site.row_pattern[i] = LefPlacementSiteRowPattern {
						previous_site_name   = previous_site_name,
						previous_site_orient = previous_site_orient,
					}
					lef_skip_whitespace_and_comments(l)
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

lef_create_macro :: proc(l: ^Lexer, lef_database: ^LefDatabase, allocator : mem.Allocator) {
	/* Scan macro name and other things within MACRO section and create / append to dynamic macro array */
	lef_skip_whitespace_and_comments(l)
	macro := LefMacro {
	name = scan_ident_ascii_upper(l),
	class = .CORE, // default class
	fixed_mask = false, // default
	pins = make([dynamic]LefMacroPin, allocator),
	obstruction = make([dynamic]LefMacroObstructionLayerGeometry, allocator),
	}
	lef_skip_whitespace_and_comments(l)
	macro_loop: for {
		keyword := scan_ident_ascii_upper(l)
		switch keyword {
		case "CLASS":
			lef_skip_whitespace_and_comments(l)
			class := scan_ident_ascii_upper(l)
			lef_skip_whitespace_and_comments(l)
			if peek(l) != SEMICOLON {
				subclass := scan_ident_ascii_upper(l)
				class = fmt.tprintf("%s_%s", class, subclass)
			}
			value, ok := reflect.enum_from_name(LefMacroClass, class)
			lexer_ensure(l, ok, fmt.tprintf("Unknown macro class %s", class))
			macro.class = value
		case "ORIGIN":
			// TODO(rahul): Fix this implementation, cz origin shifts macro so its not a distance
			lef_skip_whitespace_and_comments(l)
			macro.origin[0] = lef_scan_distance(l, lef_database)
			lef_skip_whitespace_and_comments(l)
			macro.origin[1] = lef_scan_distance(l, lef_database)
		case "FIXEDMASK": macro.fixed_mask = true
		case "SYMMETRY": symmetry_loop: for {
					lef_skip_whitespace_and_comments(l)
					if peek(l) == SEMICOLON { break symmetry_loop }
					sym_type := scan_ident_ascii_upper(l)
					sym_type_enum, ok := reflect.enum_from_name(LefPlacementSiteSymmetry, sym_type)
					lexer_ensure(l,ok, fmt.tprint("Invalid symmetry type", sym_type))
					macro.symmetry |= sym_type_enum
				}
		case "SITE":
			lef_skip_whitespace_and_comments(l)
			placement_site_name := LefPlacementSiteName(scan_ident_ascii_upper(l))
			for site in lef_database.placement_sites { if placement_site_name == site.site_name { macro.site = site } }
			lexer_ensure(l, macro.site != LefPlacementSite{}, "Site not found")
		case "FOREIGN":
			lef_skip_whitespace_and_comments(l)
			macro.foreign_cell.name = scan_ident_ascii_upper(l)
			lef_skip_whitespace_and_comments(l)
			if peek(l) != SEMICOLON {
				macro.foreign_cell.points[0] = lef_scan_distance(l, lef_database)
				lef_skip_whitespace_and_comments(l)
				macro.foreign_cell.points[1] = lef_scan_distance(l, lef_database)
			}
		case "SIZE":
			dbu_per_micron := i64(lef_database.units[.DATABASE])
			lexer_ensure(l, dbu_per_micron > 0, "DATABASE MICRONS must precede SITE SIZE")
			macro.size.size_width_dbu = lef_scan_distance(l, lef_database)
			lef_skip_whitespace_and_comments(l)
			by_keyword := scan_ident_ascii_upper(l)
			lexer_ensure(l = l, condition = by_keyword == "BY", err_msg = "No BY keyword between width/length")
			macro.size.size_height_dbu = lef_scan_distance(l, lef_database)
		case "PIN":
			lef_add_pin_to_macro(l, lef_database, &macro,allocator)
			continue macro_loop
		case "OBS":
			lef_add_obs_to_macro(l, lef_database, &macro, allocator)
			continue macro_loop
		case "END": break macro_loop
		}
		lef_consume_statement_end(l)
	}
	lef_consume_section_end(l, macro.name)
	append(&lef_database.macros, macro)
}

lef_add_pin_to_macro :: proc(l : ^Lexer, lef_database : ^LefDatabase, macro : ^LefMacro, allocator : mem.Allocator) {
	lef_skip_whitespace_and_comments(l)
	pin := LefMacroPin {
		name = scan_ident_ascii_upper(l),
		ports = make([dynamic]LefMacroPinPort, allocator),
	}
	lef_skip_whitespace_and_comments(l)
	pin_loop : for {
		keyword := scan_ident_ascii_upper(l)
		switch keyword {
		case "DIRECTION":
			lef_skip_whitespace_and_comments(l)
			pin_direction_string := scan_ident_ascii_upper(l)
			pin_direction, ok := reflect.enum_from_name(LefMacroPinDirection, pin_direction_string)
			lexer_ensure(l, ok, fmt.tprintf("Couldn't find macro pin direction %s for macro % pin %s", pin_direction_string, macro.name, pin.name))
		case "USE" :
			lef_skip_whitespace_and_comments(l)
			use_str := scan_ident_ascii_upper(l)
			use_enum, ok := reflect.enum_from_name(LefMacroPinUse, use_str)
			lexer_ensure(l, ok, "Failed to convert use enum for pin usage")
			pin.use = use_enum
		case "PORT":
			lef_add_port_to_macro_pin(l, lef_database, macro, &pin, allocator)
			continue pin_loop
		case "END" : break pin_loop
		case : lexer_panic(l, fmt.tprintf("Unhandled keyword %s for pin %s for macro %s", keyword, pin.name, macro.name))
		}
		lef_consume_statement_end(l)
	}
	lef_consume_section_end(l, pin.name)
	append(&macro.pins, pin)
}

lef_add_port_to_macro_pin :: proc(l: ^Lexer, lef_database : ^LefDatabase, macro: ^LefMacro, pin : ^LefMacroPin, allocator : mem.Allocator) {
	lef_skip_whitespace_and_comments(l)
	port := LefMacroPinPort {
		points = make([dynamic]LefDistance, allocator),
	}
	pin_port_loop: for {
		keyword := scan_ident_ascii_upper(l)
		switch keyword {
		case "LAYER":
			lef_skip_whitespace_and_comments(l)
			layer_name := scan_ident_ascii_upper(l)
			for &layer in lef_database.layers { if layer.name == layer_name { port.layer = &layer } }
			lexer_ensure(l, port.layer != nil, fmt.tprint("Unable to find layer", layer_name))
		case "RECT", "POLYGON":
			for peek(l) != SEMICOLON {
				lef_skip_whitespace_and_comments(l)
				point := lef_scan_distance(l, lef_database)
				append(&port.points, point)
				lef_skip_whitespace_and_comments(l)
			}
		case "END":
			lef_skip_whitespace_and_comments(l)
			break pin_port_loop
		}
		lef_consume_statement_end(l)
	}
	append(&pin.ports, port)
}

lef_add_obs_to_macro :: proc(l: ^Lexer, lef_database: ^LefDatabase, macro: ^LefMacro, allocator : mem.Allocator) {
	lef_skip_whitespace_and_comments(l)
	obstruction : LefMacroObstructionLayerGeometry
	obs_loop: for {
		keyword := scan_ident_ascii_upper(l)
		switch keyword {
		case "LAYER":
			if obstruction.layer != nil { append(&macro.obstruction, obstruction) }
			obstruction = LefMacroObstructionLayerGeometry {
				points = make([dynamic][dynamic]LefDistance, allocator),
			}
			lef_skip_whitespace_and_comments(l)
			layer_name := scan_ident_ascii_upper(l)
			for &layer in lef_database.layers { if layer.name == layer_name { obstruction.layer = &layer } }
			lexer_ensure(l, obstruction.layer != nil, fmt.tprint("Unable to find layer", layer_name))
		case "RECT", "POLYGON":
			lexer_ensure(l, obstruction.layer != nil, "OBS geometry must follow LAYER")
			points := make([dynamic]LefDistance, allocator)
			for peek(l) != SEMICOLON {
				lef_skip_whitespace_and_comments(l)
				point := lef_scan_distance(l, lef_database)
				append(&points, point)
				lef_skip_whitespace_and_comments(l)
			}
			append(&obstruction.points, points)
		case "END":
			lef_skip_whitespace_and_comments(l)
			break obs_loop
		case: lexer_panic(l, fmt.tprintf("Unhandled OBS keyword %s for macro %s", keyword, macro.name))
		}
		lef_consume_statement_end(l)
	}
	append(&macro.obstruction, obstruction)
}

lef_create_layer :: proc(l: ^Lexer, lef_database: ^LefDatabase, lef_allocator : mem.Allocator) {
	new_layer: LefLayer
	new_layer.name = scan_ident_ascii_upper(l)
	lef_skip_whitespace_and_comments(l)
	lexer_ensure(l = l, condition = scan_ident_ascii_upper(l) == "TYPE", err_msg = "Layer type not defined right after LAYER keyword")
	lef_skip_whitespace_and_comments(l)
	layer_type := scan_ident_ascii_upper(l)
	switch layer_type {
	case "CUT": new_layer.layer_data = LefCutLayer{}
	case "MASTERSLICE": new_layer.layer_data = LefMastersliceOverlapLayer { type = .MASTERSLICE }
	case "OVERLAP": new_layer.layer_data = LefMastersliceOverlapLayer { type = .OVERLAP }
	case "IMPLANT": new_layer.layer_data = LefImplantLayer{}
	case "ROUTING": new_layer.layer_data = LefRoutingLayer{}
	case: lexer_panic(l, "Unknown layer type")
	}
	lef_consume_statement_end(l)

	// set defaults
	new_layer.manufacturing_grid = lef_database.manufacturing_grid_value // Set default val if manufacturing grid not present
	new_layer.mask = .SINGLE // not specified

	layer_loop: for {
		layer_property := scan_ident_ascii_upper(l)
		switch layer_property {
		case "END": break layer_loop
		case "MANUFACTURINGGRID":
			new_layer.manufacturing_grid = lef_scan_distance(l, lef_database) // override default
		case "PROPERTY":
			lef_skip_whitespace_and_comments(l)
			prop_name := scan_ident_ascii_upper(l)
			lef_skip_whitespace_and_comments(l)
			prop_val := scan_double_quote_wrapped_string(l)
			for &property in lef_database.property_definitions {
				if prop_name == property.property_name {
					new_layer.property = LefLayerProperty {
						property_definition = &property,
						value               = prop_val,
					}
				}
			}
			lexer_ensure(l, new_layer.property.property_definition != nil, "Property name not found")
		case "MASK": lef_skip_whitespace_and_comments(l)
			mask_num := peek(l)
			lexer_ensure(l, mask_num == '2' || mask_num == '3', "Invalid mask num in layer")
			new_layer.mask = .DOUBLE_MASK if mask_num == '2' else .TRIPLE_MASK
			lexer_consume(l,mask_num)
		case : // If not any of common types, has to be layer data (or invalid type)
			lef_skip_whitespace_and_comments(l)
			switch &layer in new_layer.layer_data {
			case LefCutLayer:  switch layer_property {
				case: lexer_panic(l, fmt.tprint("Unhandled layer property", layer_property, "for", layer_type))
				case "SPACING": layer.min_spacing = lef_scan_distance(l, lef_database)
				case "WIDTH": layer.min_width = lef_scan_distance(l, lef_database)
				case "ENCLOSURE":
					type :=  scan_ident_ascii_upper(l)
					lef_skip_whitespace_and_comments(l)
					overhang_1 := lef_scan_distance(l, lef_database)
					lef_skip_whitespace_and_comments(l)
					overhang_2 := lef_scan_distance(l, lef_database)
					if type == "ABOVE" {
						layer.enclosures[0] = overhang_1
						layer.enclosures[1] = overhang_2
					} else if type == "BELOW" {
						layer.enclosures[2] = overhang_1
						layer.enclosures[3] = overhang_2
					}
				case "RESISTANCE":
				skip_newlines_and_whitespaces(l)
				layer.resistance = lef_scan_resistance(l, lef_database)
				case "ANTENNAMODEL", "ANTENNADIFFSIDEAREARATIO", "ANTENNADIFFAREARATIO": lef_scan_antenna_properties(l, lef_database, &new_layer, layer_property)
				case "DCCURRENTDENSITY":
				}
			case LefImplantLayer: switch layer_property {
				case: lexer_panic(l, fmt.tprint("Unhandled layer property", layer_property, "for", layer_type))
				}
			case LefRoutingLayer: switch layer_property {
					case "DIRECTION":
						direction := scan_ident_ascii_upper(l)
						value, ok := reflect.enum_from_name(LefRoutingLayerDirection, direction)
						if ok { layer.direction = value }
					case "PITCH":
						layer.pitch[0] = lef_scan_distance(l, lef_database)
						lef_skip_whitespace_and_comments(l)
						// if only 1 pitch given then xy distance is same else different
						layer.pitch[1] = lef_scan_distance(l, lef_database) if peek(l) != SEMICOLON else layer.pitch[0]
					case "OFFSET":
						layer.offset[0] = lef_scan_distance(l, lef_database)
						lef_skip_whitespace_and_comments(l)
						layer.offset[1] = lef_scan_distance(l, lef_database) if peek(l) != SEMICOLON else layer.offset[0]
					case "WIDTH": layer.min_width = lef_scan_distance(l, lef_database)
					case "SPACING":
						layer.spacing_rules.min_spacing = lef_scan_distance(l, lef_database)
						lef_skip_whitespace_and_comments(l)
						for peek(l) != SEMICOLON {
							spacing_attribute := scan_ident_ascii_upper(l)
							switch spacing_attribute {
							case "RANGE":
							case "INFLUENCE":
							case "SAMENET":
								layer.spacing_rules.samenet = true
								lef_skip_whitespace_and_comments(l)
								if peek(l) != SEMICOLON {
									lexer_ensure(l, scan_ident_ascii_upper(l) == "PGONLY", "Unknown string after samenet statement")
									layer.spacing_rules.pgonly = true
							 }
							case "ENDOFLINE":
							case "PARALLELEDGE":
							case "NOTCHLENGTH":
							case "ENDOFNOTCHWIDTH":
							case : lexer_panic(l, fmt.tprint("Unknown spacing attribute", spacing_attribute, "for layer", layer_type))
							}
							lef_skip_whitespace_and_comments(l)
						}
					case "SPACINGTABLE":
						spacing_table := &layer.spacing_table
						spacing_table.parallel_run_length = make([dynamic]LefDistance, lef_allocator)
						spacing_table.width = make([dynamic][dynamic]LefDistance, lef_allocator)
						lef_skip_whitespace_and_comments(l)
						lexer_ensure(l, scan_ident_ascii_upper(l) == "PARALLELRUNLENGTH", "Parallel run length keyword not found")
						for peek(l) != 'W' {
							lef_skip_whitespace_and_comments(l)
							run_length := lef_scan_distance(l, lef_database)
							lexer_ensure(l, len(spacing_table.parallel_run_length) == 0 || run_length > spacing_table.parallel_run_length[len(spacing_table.parallel_run_length)-1], "PARALLELRUNLENGTH values must be strictly increasing")
							append(&spacing_table.parallel_run_length, run_length)
							lef_skip_whitespace_and_comments(l)
						}
						width_index := 0
						for {
							lef_skip_whitespace_and_comments(l)
							if peek(l) == SEMICOLON { break }
							lexer_ensure(l, scan_ident_ascii_upper(l) == "WIDTH", "Expected WIDTH")
							width := lef_scan_distance(l, lef_database)
							lexer_ensure(l, width_index == 0 || width > spacing_table.width[width_index-1][0], "WIDTH thresholds must be strictly increasing")
							append(&spacing_table.width, make([dynamic]LefDistance, lef_allocator))
							append(&spacing_table.width[width_index], width)
							for _ in 0..<len(spacing_table.parallel_run_length) {
								spacing := lef_scan_distance(l, lef_database)
								append(&spacing_table.width[width_index], spacing)
							}
							width_index += 1
						}
						lexer_ensure(l, width_index > 0, "Expected at least one WIDTH row")
					case "AREA": layer.area = lef_scan_area(l, lef_database)
					case "MINSIZE":
						// TODO(rahul): think about how to allocate here and for other dynamic layer property types
						layer.min_size = make([dynamic][2]LefDistance, lef_allocator)
						for peek(l) != SEMICOLON {
						lef_skip_whitespace_and_comments((l))
						min_width := lef_scan_distance(l, lef_database)
						lef_skip_whitespace_and_comments((l))
						min_length := lef_scan_distance(l, lef_database)
						append(&layer.min_size, [2]LefDistance{min_width, min_length})
						lef_skip_whitespace_and_comments((l))
					}
					case "MINENCLOSEDAREA":

					case "THICKNESS":
						skip_newlines_and_whitespaces(l)
						layer.thickness = lef_scan_distance(l, lef_database)
					case "EDGECAPACITANCE":
						skip_newlines_and_whitespaces(l)
						layer.edge_capacitance = lef_scan_capacitance_per_distance(l, lef_database)
					case "CAPACITANCE":
						skip_newlines_and_whitespaces(l)
						lexer_ensure(l, scan_ident_ascii_upper(l) == "CPERSQDIST", "Invalid keyword after capacitance")
						skip_newlines_and_whitespaces(l)
						layer.capacitance = lef_scan_capacitance_per_area(l, lef_database)
					case "RESISTANCE":
						skip_newlines_and_whitespaces(l)
						lexer_ensure(l, scan_ident_ascii_upper(l) == "RPERSQ", "Invalid keyword after resistance")
						skip_newlines_and_whitespaces(l)
						layer.resistance = lef_scan_resistance(l, lef_database)
					case "DCCURRENTDENSITY":
					case "ACCURRENTDENSITY":
					case "ANTENNAMODEL", "ANTENNADIFFSIDEAREARATIO": lef_scan_antenna_properties(l, lef_database, &new_layer, layer_property)
					case: lexer_panic(l, fmt.tprint("Unhandled layer property", layer_property, "for", layer_type))
					}
			case LefMastersliceOverlapLayer: switch layer_property {
				case: lexer_panic(l, fmt.tprint("Unhandled layer property", layer_property, "for", layer_type))
				}
			case: lexer_panic(l, fmt.tprint("Unhandled layer type", layer_type))
			}
		}
		lef_consume_statement_end(l)
	}
	lef_consume_section_end(l, new_layer.name)
	append(&lef_database.layers, new_layer)
}

lef_create_via :: proc(l: ^Lexer, lef_database: ^LefDatabase, lef_allocator: mem.Allocator) {
	via : LefVia
	for &shape in via.layer_shapes { shape = make([dynamic]LefDistance, lef_allocator) }
	via.name = scan_ident_ascii_upper(l)
	lef_skip_whitespace_and_comments(l)
	ident := scan_ident_ascii_upper(l)
	if ident == "DEFAULT" { via.default = true; lef_skip_whitespace_and_comments(l) }
	layer_index : u8 = 0
	via_loop : for {
		via_property := scan_ident_ascii_upper(l) if ident == "DEFAULT" else ident
		via_switch : switch via_property {
		case "LAYER":
			lef_skip_whitespace_and_comments(l)
			layer_name := scan_ident_ascii_upper(l)
			find_layer : for &layer in lef_database.layers
			{
				if layer.name == layer_name {
					lexer_ensure(l, layer_index < len(via.layers), fmt.tprintf("VIA %s has more than 3 layers", via.name))
					via.layers[layer_index] = &layer
					layer_index += 1
					break find_layer
				}
			}
			lexer_ensure(l, via.layers[layer_index-1] != nil, fmt.tprintf("Layer %s not found", layer_name))
		case "RECT", "POLYGON":
			for peek(l) != SEMICOLON {
				lef_skip_whitespace_and_comments(l)
				point := lef_scan_distance(l, lef_database)
				append(&via.layer_shapes[layer_index-1], point)
				lef_skip_whitespace_and_comments(l)
			}
		case "LAYERS": lef_add_layers_to_via(l, lef_database, &via)
		case "END": break via_loop
		case: lexer_panic(l, fmt.tprintf("Unknown via property %s for via %s", via_property, via.name))
		}
		lef_consume_statement_end(l)
	}
	lef_consume_section_end(l, via.name)
	append(&lef_database.vias, via)
}

lef_add_layers_to_via :: proc(l: ^Lexer, lef_database: ^LefDatabase, via: ^LefVia)
{
	for i in 0..<3 {
		lef_skip_whitespace_and_comments(l)
		layer_name := scan_ident_ascii_upper(l)
		for &layer in lef_database.layers { if layer_name == layer.name { via.layers[i] = &layer } }
	}
	lef_consume_statement_end(l)
}

lef_create_viarule :: proc(l: ^Lexer, lef_database: ^LefDatabase, allocator : mem.Allocator) {
	lef_skip_whitespace_and_comments(l)
	viarule : LefViaRule
	for &shape in viarule.layer_shapes { shape = make([dynamic]LefDistance, allocator) }
	viarule.name = scan_ident_ascii_upper(l)
	lef_skip_whitespace_and_comments(l)
	lexer_ensure(l, scan_ident_ascii_upper(l) == "GENERATE", "Old via syntax found, TODO(rahul): Maybe support this case if it pops up?")
	lef_skip_whitespace_and_comments(l)
	layer_index := 0
	viarule_loop : for {
		keyword := scan_ident_ascii_upper(l)
		switch keyword {
		case "LAYER":
			lef_skip_whitespace_and_comments(l)
			layer_name := scan_ident_ascii_upper(l)
			find_layer : for &layer in lef_database.layers
			{
				if layer.name == layer_name {
					lexer_ensure(l, layer_index < len(viarule.layers), fmt.tprintf("VIARULE %s has more than 3 layers", viarule.name))
					viarule.layers[layer_index] = &layer
					layer_index += 1
					break find_layer
				}
			}
			lexer_ensure(l, viarule.layers[layer_index-1] != nil, fmt.tprintf("Layer %s not found", layer_name))
		case "ENCLOSURE":
			lef_skip_whitespace_and_comments(l)
			viarule.enclosures[layer_index-1][0] = lef_scan_distance(l, lef_database)
			lef_skip_whitespace_and_comments(l)
			viarule.enclosures[layer_index-1][1] = lef_scan_distance(l, lef_database)
		case "RECT", "POLYGON":
			for peek(l) != SEMICOLON {
				lef_skip_whitespace_and_comments(l)
				point := lef_scan_distance(l, lef_database)
				append(&viarule.layer_shapes[layer_index-1], point)
				lef_skip_whitespace_and_comments(l)
			}
		case "SPACING":
			lef_skip_whitespace_and_comments(l)
			viarule.spacing[layer_index-1][0] = lef_scan_distance(l, lef_database)
			lef_skip_whitespace_and_comments(l)
			lexer_ensure(l, scan_ident_ascii_upper(l) == "BY", "By keyword not found")
			viarule.spacing[layer_index-1][1] = lef_scan_distance(l, lef_database)
		case "END": break viarule_loop
		}
		lef_consume_statement_end(l)
	}
	lef_consume_section_end(l, viarule.name)
	append(&lef_database.via_rules, viarule)
}

/* End LEF data structure creation */

/* LEF helper procs */
lef_consume_statement_end :: #force_inline proc(l: ^Lexer) {
	lef_skip_whitespace_and_comments(l)
	lexer_consume(l, SEMICOLON)
	lef_skip_whitespace_and_comments(l)
}

lef_consume_section_end :: #force_inline proc(l: ^Lexer, statement: string) {
	lef_skip_whitespace_and_comments(l)
	lexer_ensure(l = l, condition = scan_ident_ascii_upper(l) == statement, err_msg = "Incorrect keyword after section end")
	lef_skip_whitespace_and_comments(l)
}

/* TODO(rahul): scan_lef_decimal_scaled_i64 is LLM generated, review and fix if needed */
lef_scan_decimal_scaled_i64 :: #force_inline proc(l: ^Lexer, scale: i64) -> i64 {
	lef_skip_whitespace_and_comments(l)
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

lef_scan_distance :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefDistance { return LefDistance(lef_scan_decimal_scaled_i64(l, lef_dbu_per_micron(l, db))) }

lef_scan_area :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefArea {
    dbu := lef_dbu_per_micron(l, db)
    area := lef_scan_decimal_scaled_i64(l, dbu * dbu)
    lexer_ensure(l, area >= 0, "LEF area cannot be negative")
    return LefArea(area)
}

// TODO(rahul): Normalise scaling factor unit (can override capacitance)
lef_scan_capacitance_value :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefCapacitance {
	return LefCapacitance(lef_scan_decimal_scaled_i64(l, YOCTOFARADS_PER_PICOFARAD))
}

lef_scan_capacitance_per_distance :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefCapacitancePerDistance {
	return LefCapacitancePerDistance(lef_scan_decimal_scaled_i64(l, YOCTOFARADS_PER_PICOFARAD))
}

lef_scan_capacitance_per_area:: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefCapacitancePerArea {
	return LefCapacitancePerArea(lef_scan_decimal_scaled_i64(l, YOCTOFARADS_PER_PICOFARAD))
}

// TODO(rahul): Normalise (same resistance scaling cant override)
lef_scan_resistance :: #force_inline proc(l: ^Lexer, db: ^LefDatabase) -> LefResistance {
	LEF_RESISTANCE_DBU_PER_OHM : i64 : 10000 // Cannot be overriden
	return LefResistance(lef_scan_decimal_scaled_i64(l, LEF_RESISTANCE_DBU_PER_OHM))
}

// Scan all props related to process antenna violations
lef_scan_antenna_properties :: proc(l : ^Lexer, db: ^LefDatabase, layer: ^LefLayer, keyword : string) {
	skip_newlines_and_whitespaces(l)
	switch keyword {
	case "ANTENNAMODEL":
		switch &layer in layer.layer_data {
		case LefRoutingLayer:
			skip_newlines_and_whitespaces(l)
			antenna_model := scan_ident_ascii_upper(l)
			antenna_model_enum, ok := reflect.enum_from_name(LefAntennaModel, antenna_model)
			lexer_ensure(l, ok, fmt.tprint("Invalid antenna model found", antenna_model))
			layer.antenna_model = antenna_model_enum
		case LefCutLayer, LefImplantLayer, LefMastersliceOverlapLayer: lexer_panic(l, "TODO(rahul):Does this layer type support antenna model?")
		}

	case "ANTENNADIFFAREA":
	case "ANTENNAGATEAREA":

	case "ANTENNAAREAFACTOR":
	case "ANTENNASIDEAREAFACTOR":

	case "ANTENNAAREARATIO":
	case "ANTENNASIDEAREARATIO":
	case "ANTENNADIFFSIDEAREARATIO":
	// skip_newlines_and_whitespaces(l)
	// lexer_ensure(l, scan_ident_ascii_upper(l) == "PWL", "TODO(rahul): handle all cases")
	// skip_newlines_and_whitespaces(l)
	case "ANTENNADIFFAREARATIO":
		lexer_ensure(l, scan_ident_ascii_upper(l) == "PWL", "PWL not found")
		skip_newlines_and_whitespaces(l)
		lexer_consume(l, LPAREN)
		for peek(l) != RPAREN {
			skip_newlines_and_whitespaces(l)
			lexer_consume(l, LPAREN)
			skip_newlines_and_whitespaces(l)
			this := lef_scan_decimal_scaled_i64(l, 100)
			skip_newlines_and_whitespaces(l)
			that := lef_scan_decimal_scaled_i64(l, 100)
			skip_newlines_and_whitespaces(l)
			lexer_consume(l, RPAREN)
			skip_newlines_and_whitespaces(l)
			// TODO(rahul): append
		}
		lexer_consume(l, RPAREN)
	case "ANTENNACUMAREARATIO":
	case "ANTENNACUMSIDEAREARATIO":
	case "ANTENNACUMDIFFAREARATIO":
	case "ANTENNACUMDIFFSIDEAREARATIO":

	case: lexer_panic(l, fmt.tprint("Unknown keyword", keyword))
	}
}

// lef_scan_time
// lef_scan_capacitance
// lef_scan_resistance
// lef_scan_power
// lef_scan_current
// lef_scan_voltage
// lef_scan_distance
// lef_scan_frequency

/* End LEF helper procs*/
