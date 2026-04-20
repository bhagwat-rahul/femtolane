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

PanelStyle :: struct {
	bg_color:         rl.Color,
	font:             rl.Font,
	internal_padding: i32,
	corner_rounding:  i32,
}

PanelID :: distinct u8 // upto 255 panels
Panel :: struct {
	id:     PanelID, // For lookup/re-render + if 2 panels have same name.
	name:   cstring,
	bounds: rl.Rectangle,
	style:  PanelStyle,
}

run_gui :: proc() {
	window := Window {
		name          = "Femtolane",
		width         = 0, // max
		height        = 0, // max
		fps           = 0, // max
		bg_color      = rl.WHITE,
		control_flags = rl.ConfigFlags{.WINDOW_RESIZABLE},
	}

	rl.SetConfigFlags(window.control_flags)
	rl.InitWindow(window.width, window.height, window.name)
	rl.SetTargetFPS(window.fps)
	rl.SetWindowSize(rl.GetScreenWidth() - 200, rl.GetScreenHeight() - 200) // we need to set this post window init otherwise width/height returns 0
	showMessage: bool = true

	for !rl.WindowShouldClose() {
		screen_width, screen_height := rl.GetScreenWidth(), rl.GetScreenHeight()
		rl.BeginDrawing()
		rl.SetWindowTitle(fmt.ctprint("Femtolane", rl.GetFPS(), "FPS"))
		rl.ClearBackground(window.bg_color)

		if showMessage == true {
			msg_rect := rl.Rectangle{0, 0, 300, 100}
			result := rl.GuiMessageBox(msg_rect, "Message Box", "Hi! This is a message!", "Nice;Cool")
			if (result >= 0) { showMessage = false }
		} else {
			msg_rect := rl.Rectangle{0, 0, 300, 100}
			result := rl.GuiMessageBox(msg_rect, "Non Message Box", "Hi! This is a non-message!", "Bleh;Blah")
			if (result >= 0) { showMessage = true }
		}

		rl.EndDrawing()
	}

	rl.CloseWindow()
}
