package main
import "core:fmt"
import rl "vendor:raylib"

Window :: struct {
	name:          cstring,
	width:         i32,
	height:        i32,
	fps:           i32,
	bg_color:      rl.Color,
	control_flags: rl.ConfigFlags,
}

run_gui :: proc() {
	window := Window{"Femtolane", 1024, 1024, 0, rl.WHITE, rl.ConfigFlags{.WINDOW_RESIZABLE}}
	rl.SetConfigFlags(window.control_flags)
	rl.SetTargetFPS(window.fps)
	rl.InitWindow(window.width, window.height, window.name)
	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(window.bg_color)
		rl.SetWindowTitle(fmt.ctprint("Femtolane", rl.GetFPS(), "FPS"))
		rl.EndDrawing()
	}
}
