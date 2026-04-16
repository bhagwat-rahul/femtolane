/*
There are 3 types of attributes in liberty:
1. simple: `name : value,`
2. complex: `name(arg1, arg2, ...)`
3. group: `name(arg1, arg2, ...) { body }`

GL netlist lex and Liberty lex is different cz in lib files we have 200+ keywords we need to switch over and just store their vals (or nested vals) whereas in GL netlist there are only like 8-10 keywords and the semantics are more important
*/

package main

import "core:fmt"
import "core:mem"
import "core:os"

LibraryType :: enum {
	CMOS,
	FPGA,
}

Revision :: union {
	f64,
	string,
}

TimeUnit :: enum {} /* 1ps , 10ps , 100ps , 1ns */
VoltageUnit :: enum {} /* 1mV , 10mV , 100mV , 1V */

/* Trip Point : A float between 0.0 - 100.0 default 50.0 */
TripPoint :: distinct f64

TRIP_POINT_MIN :: 0.0
TRIP_POINT_MAX :: 100.0
TRIP_POINT_DEFAULT :: TripPoint(50.0)
/* End Trip Point Type */

Library :: struct {
	name:                          string,
	description:                   string,
	type:                          LibraryType,

	/* START: Simple Attributes */
	altitude_unit:                 LibraryAltitudeUnit,
	bus_naming_style:              string,
	comment:                       string,
	current_unit:                  LibraryCurrentUnit,
	date:                          string, // TODO(rahul): can be any dateformat, normalise to some kind of type
	delay_model:                   LibraryDelayModel,
	em_temp_degradation_factor:    f64,
	input_threshold_pct_fall:      TripPoint,
	input_threshold_pct_rise:      TripPoint,
	is_soi:                        bool,
	leakage_power_unit:            LibraryLeakagePowerUnit,
	nom_process:                   f64,
	nom_temperature:               f64,
	nom_voltage:                   f64,
	output_threshold_pct_fall:     TripPoint,
	output_threshold_pct_rise:     TripPoint,
	power_model:                   TableLookup,
	pulling_resistance_unit:       PullingResistanceUnit,
	revision:                      Revision,
	slew_derate_from_library:      Derate,
	slew_lower_threshold_pct_fall: TripPoint,
	slew_lower_threshold_pct_rise: TripPoint,
	slew_upper_threshold_pct_fall: TripPoint,
	slew_upper_threshold_pct_rise: TripPoint,
	soft_error_rate_confidence:    f64,
	time_unit:                     TimeUnit,
	voltage_unit:                  VoltageUnit,

	/* Library Description: Default Attributes */
	/* These attributes define default values at the library level for attributes that normally belong to lower-level groups (cell, pin, timing, etc). Individual groups can override these by specifying the corresponding attribute within that group. */
	default_cell_leakage_power:    f64,
	default_connection_class:      string, // name | name_liststring
	default_fanout_load:           f64,
	default_inout_pin_cap:         f64,
	default_input_pin_cap:         f64,
	default_max_capacitance:       f64,
	default_max_fanout:            f64,
	default_max_transition:        f64,
	default_operating_conditions:  string, // namestring ;
	default_output_pin_cap:        f64,
	default_wire_load:             string, //namestring ;
	default_wire_load_area:        f64,
	default_wire_load_capacitance: f64,
	default_wire_load_mode:        WireLoadMode,
	default_wire_load_resistance:  f64,
	default_wire_load_selection:   string, // namestring ;
	/* Scaling Attributes */
	k_process_cell_fall:           f64, /* nonlinear model only */
	k_process_cell_rise:           f64, /* nonlinear model only */
	k_process_fall_propagation:    f64, /* nonlinear model only */
	k_process_fall_transition:     f64, /* nonlinear model only */
	k_process_pin_cap:             f64,
	k_process_rise_propagation:    f64, /* nonlinear model only */
	k_process_rise_transition:     f64, /* nonlinear model only */
	k_process_wire_cap:            f64,
	k_temp_cell_rise:              f64, /* nonlinear model only */
	k_temp_cell_fall:              f64, /* nonlinear model only */
	k_temp_fall_propagation:       f64, /* nonlinear model only */
	k_temp_fall_transition:        f64, /* nonlinear model only */
	k_temp_pin_cap:                f64,
	k_temp_rise_propagation:       f64, /* nonlinear model only */
	k_temp_rise_transition:        f64, /* nonlinear model only */
	k_temp_rise_wire_resistance:   f64,
	k_temp_wire_cap:               f64,
	k_volt_cell_fall:              f64, /* nonlinear model only */
	k_volt_cell_rise:              f64, /* nonlinear model only */
	k_volt_fall_propagation:       f64, /* nonlinear model only */
	k_volt_fall_transition:        f64, /* nonlinear model only */
	k_volt_pin_cap:                f64,
	k_volt_rise_propagation:       f64, /* nonlinear model only */
	k_volt_rise_transition:        f64, /* nonlinear model only */
	k_volt_wire_cap:               f64,
	/* END: Simple Attributes */

	/* START: Complex Attributes */
	// capacitive_load_unit : CapacitiveLoadSpec,
	// default_part (default_part_nameid, speed_gradeid) ;
	// define (name, object, type) ; /*user—defined attributes only */
	// define_cell_area (area_name, resource_type) ;
	// define_group (attribute_namestring, group_namestring,attribute_typestring ;
	// library_features (value_1, value_2, ..., value_n) ;
	// receiver_capacitance_rise_threshold_pct ("float, float, ...") ;
	// receiver_capacitance_fall_threshold_pct ("float, float, ...") ;
	// technology ("name") ;
	/* END: Complex Attributes */

	/* START: Group Statements */
	// cell (name) { }
	// dc_current_template (template_nameid) { }
	// default_soft_error_rate (name) { }
	// em_lut_template (name) { }
	// fall_net_delay : name ;
	// fall_transition_degradation (name) { }
	// input_voltage (name) { }
	// lu_table_template (name) { }
	// ocv_derate (name) { }
	// ocv_table_template (template_name) { }
	// operating_conditions (name) { }
	// output_voltage (name) { }
	// part (name){ }
	// power_lut_template (template_nameid ) { }
	// rise_net_delay : name ;
	// rise_transition_degradation () { }
	// soft_error_rate_template (name) { }
	// timing (name | name_list) { }
	// type (name) { }
	// voltage_state_range_list
	// wire_load (name) { }
	// wire_load_selection (name)
	/* END: Group Statements */
}

LibraryAltitudeUnit :: enum {}
LibraryCurrentUnit :: enum {}
LibraryDelayModel :: enum {}
LibraryLeakagePowerUnit :: enum {}
PullingResistanceUnit :: enum {
	Ohm1,
	Ohm10,
	Ohm100,
	Ohm1000,
} /*1ohm | 10ohm | 100ohm | 1kohm*/
CapacitiveLoadUnit :: enum {
	FF, // FemtoFarad
	PF, // PicoFarad
}

WireLoadMode :: enum {
	Top,
	Segmented,
	Enclosed,
}

CapacitiveLoadSpec :: struct {
	scale: f64,
	unit:  CapacitiveLoadUnit,
}
Derate :: struct {}
TableLookup :: enum {
	UNKNOWN,
	NLDM,
	CCS,
	ECSM,
}

LibertyCell :: struct {
	name: string,
	area: u64, // not a f64 for since we will downscale measurement unit so no f64s are needed here, for easier/accurate calculation
	pins: [dynamic]LibertyPin,
}

LibertyPin :: struct {}

LibertyLexer :: struct {
	src:           []byte,
	curr_byte_idx: int,
	filepath:      string,
}

LIBERTY_IDENT_START, LIBERTY_IDENT_CHAR: [256]bool

@(init)
init_liberty_ident_tables :: proc "contextless" () {
	for i in 0 ..< 256 {
		LIBERTY_IDENT_START[i] = false
		LIBERTY_IDENT_CHAR[i] = false
	}

	for c in 'a' ..= 'z' {
		LIBERTY_IDENT_START[c] = true
		LIBERTY_IDENT_CHAR[c] = true
	}

	for c in 'A' ..= 'Z' {
		LIBERTY_IDENT_START[c] = true
		LIBERTY_IDENT_CHAR[c] = true
	}

	LIBERTY_IDENT_START['_'] = true
	LIBERTY_IDENT_CHAR['_'] = true

	for c in '0' ..= '9' {
		LIBERTY_IDENT_CHAR[c] = true
	}

	LIBERTY_IDENT_CHAR['$'] = true
}

is_liberty_ident_start :: #force_inline proc(b: byte) -> bool { return LIBERTY_IDENT_START[b] }

is_liberty_ident_char :: #force_inline proc(b: byte) -> bool { return LIBERTY_IDENT_CHAR[b] }

scan_liberty_ident :: #force_inline proc(l: ^LibertyLexer) -> string {
	start := l.curr_byte_idx
	for l.curr_byte_idx < len(l.src) && is_liberty_ident_char(l.src[l.curr_byte_idx]) { l.curr_byte_idx += 1 }
	return string(l.src[start:l.curr_byte_idx])
}

skip_whitespace_and_comments :: #force_inline proc(l: ^LibertyLexer) {
	for l.curr_byte_idx < len(l.src) {
		c := l.src[l.curr_byte_idx]

		// whitespace
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			l.curr_byte_idx += 1
			continue
		}

		// line comment: // ...
		if c == '/' && l.curr_byte_idx + 1 < len(l.src) && l.src[l.curr_byte_idx + 1] == '/' {
			l.curr_byte_idx += 2
			for l.curr_byte_idx < len(l.src) && l.src[l.curr_byte_idx] != '\n' { l.curr_byte_idx += 1 }
			continue
		}

		// block comment: /* ... */
		if c == '/' && l.curr_byte_idx + 1 < len(l.src) && l.src[l.curr_byte_idx + 1] == '*' {
			l.curr_byte_idx += 2

			for {
				if l.curr_byte_idx + 1 >= len(l.src) { panic("unterminated comment") }
				if l.src[l.curr_byte_idx] == '*' && l.src[l.curr_byte_idx + 1] == '/' {
					l.curr_byte_idx += 2
					break
				}
				l.curr_byte_idx += 1
			}
			continue
		}

		break
	}
}

trip_point_parse :: proc(v: f64) -> TripPoint {
	if v < TRIP_POINT_MIN || v > TRIP_POINT_MAX { panic("trip_point out of range") }
	return TripPoint(v)
}

parse_liberty_create_cells_pins :: proc(liberty_filepath: string, alloc: mem.Allocator, hgr: ^NetlistHyperGraph) {
	resolved_liberty_path := liberty_filepath
	for len(resolved_liberty_path) == 0 {
		resolved_liberty_path, _ = pick_path(File_Picker_Request{mode = .Open_File, title = "Select Gate-Level Netlist"})
	}

	data, err := os.read_entire_file_from_path(resolved_liberty_path, alloc)
	ensure(err == nil, fmt.tprintln("FileReadError:", err))

	l: LibertyLexer = {
		src           = data,
		curr_byte_idx = 0,
		filepath      = resolved_liberty_path,
	}

	nodes: [dynamic]^LibertyNode
	nodes = make([dynamic]^LibertyNode, alloc)

	for l.curr_byte_idx < len(l.src) {
		skip_whitespace_and_comments(&l)
		if l.curr_byte_idx >= len(l.src) { break }

		n := parse_stmt(&l, alloc)
		append(&nodes, n)
	}

	lib := nodes[0] // or find "library"

	for child in lib.children {
		if child.name != "cell" { continue }

		// --- CREATE CELL ---
		cell_name := child.args[0]

		cell_ptr := create_cell(
			hgr = hgr,
			arena_alloc = alloc,
			cell_val = Cell{name = cell_name, pdk_provided = true, resolved = true, children_ports = make([dynamic]^CellPort, alloc)},
		)

		// --- PARSE CELL BODY ---
		for cchild in child.children {

			switch cchild.name {

			case "pin", "pg_pin":
				port_name := cchild.args[0]
				create_cell_port(parent_cell_ptr = cell_ptr, arena_alloc = alloc, name = port_name)
			}
		}
	}
}

LibertyNode :: struct {
	name:     string,
	args:     [dynamic]string,
	value:    string,
	children: [dynamic]^LibertyNode,
}

peek_liberty :: #force_inline proc(l: ^LibertyLexer) -> byte {
	if l.curr_byte_idx >= len(l.src) { return 0 }
	return l.src[l.curr_byte_idx]
}

consume :: #force_inline proc(l: ^LibertyLexer, c: byte) {
	if peek_liberty(l) != c { panic("unexpected char") }
	l.curr_byte_idx += 1
}

parse_args :: proc(l: ^LibertyLexer, alloc: mem.Allocator) -> [dynamic]string {
	args := make([dynamic]string, alloc)

	consume(l, '(')
	skip_whitespace_and_comments(l)

	for peek_liberty(l) != ')' {

		c := peek_liberty(l)

		// 🔥 NEW: handle quoted string
		if c == '"' {
			append(&args, scan_string(l))

			// normal identifier
		} else if is_liberty_ident_start(c) {
			append(&args, scan_liberty_ident(l))

			// fallback (numbers, weird stuff)
		} else {
			start := l.curr_byte_idx
			for peek_liberty(l) != ',' && peek_liberty(l) != ')' {
				l.curr_byte_idx += 1
			}
			append(&args, string(l.src[start:l.curr_byte_idx]))
		}

		skip_whitespace_and_comments(l)

		if peek_liberty(l) == ',' {
			l.curr_byte_idx += 1
			skip_whitespace_and_comments(l)
		}
	}

	consume(l, ')')
	return args
}

scan_string :: proc(l: ^LibertyLexer) -> string {
	consume(l, '"')
	start := l.curr_byte_idx

	for {
		if l.curr_byte_idx >= len(l.src) { panic("unterminated string") }
		if l.src[l.curr_byte_idx] == '"' {
			s := string(l.src[start:l.curr_byte_idx]) // ← NO quotes
			l.curr_byte_idx += 1
			return s
		}
		l.curr_byte_idx += 1
	}
}

parse_stmt :: proc(l: ^LibertyLexer, alloc: mem.Allocator) -> ^LibertyNode {
	skip_whitespace_and_comments(l)

	name := scan_liberty_ident(l)
	skip_whitespace_and_comments(l)

	node, _ := new(LibertyNode, alloc)
	node.name = name

	// SIMPLE: name : value ;
	if peek_liberty(l) == ':' {
		l.curr_byte_idx += 1
		skip_whitespace_and_comments(l)

		start := l.curr_byte_idx
		for peek_liberty(l) != ';' {
			l.curr_byte_idx += 1
		}

		node.value = string(l.src[start:l.curr_byte_idx])
		consume(l, ';')
		return node
	}

	// COMPLEX / GROUP
	if peek_liberty(l) == '(' {
		node.args = parse_args(l, alloc)
		skip_whitespace_and_comments(l)

		// GROUP
		if peek_liberty(l) == '{' {
			node.children = make([dynamic]^LibertyNode, alloc)

			consume(l, '{')
			skip_whitespace_and_comments(l)

			for peek_liberty(l) != '}' {
				child := parse_stmt(l, alloc)
				append(&node.children, child)
				skip_whitespace_and_comments(l)
			}

			consume(l, '}')
			return node
		}

		// COMPLEX ATTR
		consume(l, ';')
		return node
	}

	panic(fmt.tprintf("Error: invalid syntax for char %r at byte %d in file %s", l.src[l.curr_byte_idx], l.curr_byte_idx, l.filepath))
}

liberty_panic :: #force_inline proc(err_msg: string, l: ^LibertyLexer) {
	panic(fmt.tprintf("Error: %s for char %r at byte %d", err_msg, l.src[l.curr_byte_idx], l.curr_byte_idx))
}
