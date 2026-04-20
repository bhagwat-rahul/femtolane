package main
import "core:fmt"
import "vendor:raylib"

Window :: struct {
	name:          cstring,
	width:         i32,
	height:        i32,
	fps:           i32,
	bg_color:      raylib.Color,
	control_flags: raylib.ConfigFlags,
}

PanelStyle :: struct {
	bg_color:         raylib.Color,
	font:             raylib.Font,
	internal_padding: i32,
	corner_rounding:  i32,
}

PanelID :: distinct u8 // upto 255 panels
Panel :: struct {
	id:     PanelID, // For lookup/re-render + if 2 panels have same name.
	name:   cstring,
	bounds: raylib.Rectangle,
	style:  PanelStyle,
}

run_gui :: proc() {
	window := Window {
		name          = "Femtolane",
		width         = 0, // max
		height        = 0, // max
		fps           = 0, // max
		bg_color      = raylib.WHITE,
		control_flags = raylib.ConfigFlags{.WINDOW_RESIZABLE},
	}

	raylib.SetConfigFlags(window.control_flags)
	raylib.InitWindow(window.width, window.height, window.name)
	raylib.SetTargetFPS(window.fps)
	raylib.SetWindowSize(raylib.GetScreenWidth() - 200, raylib.GetScreenHeight() - 200) // we need to set this post window init otherwise width/height returns 0
	showMessage: bool = true

	for !raylib.WindowShouldClose() {
		screen_width, screen_height := raylib.GetScreenWidth(), raylib.GetScreenHeight()
		raylib.BeginDrawing()
		raylib.SetWindowTitle(fmt.ctprint("Femtolane", raylib.GetFPS(), "FPS"))
		raylib.ClearBackground(window.bg_color)

		if showMessage == true {
			msg_rect := raylib.Rectangle{0, 0, 300, 100}
			result := raylib.GuiMessageBox(msg_rect, "Message Box", "Hi! This is a message!", "Nice;Cool")
			if (result >= 0) { showMessage = false }
		} else {
			msg_rect := raylib.Rectangle{0, 0, 300, 100}
			result := raylib.GuiMessageBox(msg_rect, "Non Message Box", "Hi! This is a non-message!", "Bleh;Blah")
			if (result >= 0) { showMessage = true }
		}

		raylib.EndDrawing()
	}

	raylib.CloseWindow()
}
