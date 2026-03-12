package main
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

Window :: struct {
	name:          cstring,
	width:         i32,
	height:        i32,
	fps:           i32,
	control_flags: rl.ConfigFlags,
}

run_gui :: proc() {
	window := Window{"Femtolane", 1024, 1024, 0, rl.ConfigFlags{.WINDOW_RESIZABLE}}
	rl.SetConfigFlags(window.control_flags)
	rl.SetTargetFPS(window.fps)
	rl.InitWindow(window.width, window.height, window.name)
	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(rl.WHITE)
		rl.GuiLabel({100, 100, 500, 300}, strings.clone_to_cstring(fmt.tprintf("FPS=%v", rl.GetFPS())))
		rl.EndDrawing()
	}
}
