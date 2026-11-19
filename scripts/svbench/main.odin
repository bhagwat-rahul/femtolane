/*
Response-file driven SystemVerilog parser harness.

Modes:
  svbench <response>          batch parse; RESET starts a new compilation unit
  svbench --time <response>   preload files, then report preprocess/parse phases
  svbench --lex <response>    raw lexer throughput (no preprocessing or AST)

Response-file format, one directive per line:
  INCDIR <directory>
  DEFINE <name>[=<value>]
  FILE <path>
  RESET
Lines beginning with '#' or '//' are ignored.
*/
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

SVFile :: struct {
	path: string,
	data: []byte,
}

Mode :: enum {
	Batch,
	Time,
	Lex,
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(2)
	}

	mode := Mode.Batch
	response_path := ""
	for arg in args {
		switch {
		case arg == "--time":
			mode = .Time
		case arg == "--lex":
			mode = .Lex
		case arg == "-h" || arg == "--help":
			usage()
			return
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("unknown option: %s", arg)
			usage()
			os.exit(2)
		case response_path == "":
			response_path = arg
		case:
			fmt.eprintfln("unexpected argument: %s", arg)
			os.exit(2)
		}
	}
	if response_path == "" {
		usage()
		os.exit(2)
	}

	switch mode {
	case .Batch: batch_mode(response_path)
	case .Time:  time_mode(response_path)
	case .Lex:   lex_mode(response_path)
	}
}

usage :: proc() {
	fmt.eprintln("usage: svbench [--time|--lex] <response-file>")
}

response_lines :: proc(path: string) -> ([]string, []byte) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read response file %s", path)
		os.exit(2)
	}
	lines := strings.split_lines(string(data))
	return lines, data
}

is_comment :: #force_inline proc(line: string) -> bool {
	return strings.has_prefix(line, "#") || strings.has_prefix(line, "//")
}

// ---------------------------------------------------------------------------------------
// Batch mode: mirrors the corpus runners used during parser development.
// ---------------------------------------------------------------------------------------

batch_mode :: proc(response_path: string) {
	lines, response := response_lines(response_path)
	defer delete(lines)
	defer delete(response, context.allocator)

	arena: mem.Arena
	mem.arena_init(&arena, make([]byte, 1 << 33))
	defer mem.arena_free_all(&arena)
	allocator := mem.arena_allocator(&arena)

	ast: SystemVerilogAST
	system_verilog_ast_init(&ast, allocator)

	for line in lines {
		if len(line) == 0 || is_comment(line) { continue }
		switch {
		case strings.has_prefix(line, "INCDIR "):
			append(&ast.include_dirs, line[len("INCDIR "):])
		case strings.has_prefix(line, "DEFINE "):
			add_define(&ast, line[len("DEFINE "):], allocator)
		case strings.has_prefix(line, "RESET"):
			ast = {}
			system_verilog_ast_init(&ast, allocator)
		case strings.has_prefix(line, "FILE "):
			path := line[len("FILE "):]
			fmt.eprintfln("TRY  %s", path)
			system_verilog_parse_to_ast(path, &ast, allocator)
		case:
			fmt.eprintfln("bad response line: %s", line)
			os.exit(2)
		}
	}
	fmt.eprintfln(
		"OK modules=%d packages=%d interfaces=%d",
		len(ast.modules),
		len(ast.packages),
		len(ast.interfaces),
	)
}

add_define :: proc(ast: ^SystemVerilogAST, spec: string, allocator: mem.Allocator) {
	name := spec
	value := "1"
	if eq := strings.index_byte(spec, '='); eq >= 0 {
		name = spec[:eq]
		value = spec[eq + 1:]
	}
	def := SVDefine{body = value}
	def.params = make([dynamic]string, allocator)
	def.param_defaults = make([dynamic]string, allocator)
	ast.defines[name] = def
}

// ---------------------------------------------------------------------------------------
// Timed mode: read inputs once, then measure preprocessing and parsing separately.
// ---------------------------------------------------------------------------------------

time_mode :: proc(response_path: string) {
	lines, response := response_lines(response_path)
	defer delete(lines)
	defer delete(response, context.allocator)

	arena: mem.Arena
	mem.arena_init(&arena, make([]byte, 1 << 33))
	defer mem.arena_free_all(&arena)
	allocator := mem.arena_allocator(&arena)

	ast: SystemVerilogAST
	system_verilog_ast_init(&ast, allocator)
	files: [dynamic]SVFile
	defer delete(files)
	defer for f in files { delete(f.data, context.allocator) }

	for line in lines {
		if len(line) == 0 || is_comment(line) { continue }
		switch {
		case strings.has_prefix(line, "INCDIR "):
			append(&ast.include_dirs, line[len("INCDIR "):])
		case strings.has_prefix(line, "DEFINE "):
			add_define(&ast, line[len("DEFINE "):], allocator)
		case strings.has_prefix(line, "RESET"):
			// Timed mode treats the whole response as one compilation unit.
		case strings.has_prefix(line, "FILE "):
			path := line[len("FILE "):]
			data, err := os.read_entire_file_from_path(path, context.allocator)
			if err != nil {
				fmt.eprintfln("read error %s", path)
				os.exit(2)
			}
			append(&files, SVFile{path = path, data = data})
		case:
			fmt.eprintfln("bad response line: %s", line)
			os.exit(2)
		}
	}

	total_bytes: int
	for f in files { total_bytes += len(f.data) }
	fmt.eprintfln(
		"BENCH files=%d bytes=%d",
		len(files),
		total_bytes,
	)

	{
		pp_time: time.Duration
		parse_time: time.Duration
		pre_offset: int
		tokens: int
		for f in files {
			before := arena.offset
			t0 := time.tick_now()
			pp := svpp_init(&ast, allocator)
			toks := svpp_preprocess(&pp, f.data, f.path)
			t1 := time.tick_now()
			tokens += len(toks)
			after_pp := arena.offset
			svp_parse_tokens(&ast, toks, pp.owned_data[:], pp.source_line_base[:], f.path, allocator)
			t2 := time.tick_now()
			pp_time += time.tick_diff(t0, t1)
			parse_time += time.tick_diff(t1, t2)
			pre_offset += after_pp - before
		}
		total := pp_time + parse_time
		fmt.eprintfln(
			"ITER pp=%.3fs parse=%.3fs total=%.3fs tokens=%d ast_modules=%d arena=%.1fMB pp_alloc=%.1fMB parse_alloc=%.1fMB",
			time.duration_seconds(pp_time),
			time.duration_seconds(parse_time),
			time.duration_seconds(total),
			tokens,
			len(ast.modules),
			f64(arena.peak_used) / (1 << 20),
			f64(pre_offset) / (1 << 20),
			f64(arena.peak_used - pre_offset) / (1 << 20),
		)
	}
}

// ---------------------------------------------------------------------------------------
// Raw lexer mode: useful for separating scanner cost from parser/AST cost.
// ---------------------------------------------------------------------------------------

lex_mode :: proc(response_path: string) {
	lines, response := response_lines(response_path)
	defer delete(lines)
	defer delete(response, context.allocator)

	arena: mem.Arena
	mem.arena_init(&arena, make([]byte, 1 << 33))
	defer mem.arena_free_all(&arena)
	allocator := mem.arena_allocator(&arena)

	files: [dynamic]SVFile
	defer delete(files)
	defer for f in files { delete(f.data, context.allocator) }
	for line in lines {
		if len(line) == 0 || is_comment(line) { continue }
		if strings.has_prefix(line, "FILE ") {
			path := line[len("FILE "):]
			data, err := os.read_entire_file_from_path(path, context.allocator)
			if err != nil {
				fmt.eprintfln("read error %s", path)
				os.exit(2)
			}
			append(&files, SVFile{path = path, data = data})
		}
	}

	total_time: time.Duration
	total_tokens: int
	for file, i in files {
		l := svl_init(file.data, u16(i))
		t0 := time.tick_now()
		for {
			t := svl_next(&l)
			if t.kind == .EOF { break }
			total_tokens += 1
		}
		total_time += time.tick_diff(t0, time.tick_now())
	}
	fmt.eprintfln(
		"LEX files=%d tokens=%d time=%.3fs",
		len(files),
		total_tokens,
		time.duration_seconds(total_time),
	)
}
