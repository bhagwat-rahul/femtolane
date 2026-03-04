// TODO(rahul): IMPORTANT!!! Made with codex 5.2, review and re-write
package femtolane_gui

import fl_lex "../lexer"
import rl "vendor:raylib"

HGWINDOWWIDTH :: 1280
HGWINDOWHEIGHT :: 900
HGWINDOWFPS :: 240

layout_col :: proc(count: int, x, top, bottom: f32, out: ^[dynamic]rl.Vector2) {
	if count <= 0 {return}
	if count == 1 {
		append(out, rl.Vector2{x, (top + bottom) * 0.5})
		return
	}
	step := (bottom - top) / f32(count - 1)
	for idx in 0 ..< count {
		append(out, rl.Vector2{x, top + step * f32(idx)})
	}
}

// Visualise net hypergraph, pass pointer to graph to avoid passing large graph struct
draw_net_hg :: proc(hg: ^fl_lex.NetHyperGraph) {
	vertex_pos := make([dynamic]rl.Vector2, 0, len(hg.vertices))
	net_pos := make([dynamic]rl.Vector2, 0, len(hg.nets))
	vertex_degree := make([dynamic]int, len(hg.vertices))
	net_degree := make([dynamic]int, len(hg.nets))
	vertex_mark := make([dynamic]bool, len(hg.vertices))
	net_mark := make([dynamic]bool, len(hg.nets))
	defer {
		delete(vertex_pos)
		delete(net_pos)
		delete(vertex_degree)
		delete(net_degree)
		delete(vertex_mark)
		delete(net_mark)
	}

	rl.InitWindow(HGWINDOWWIDTH, HGWINDOWHEIGHT, "Net Hypergraph")
	defer rl.CloseWindow()
	rl.SetTargetFPS(HGWINDOWFPS)

	top: f32 = 60
	bottom: f32 = f32(HGWINDOWHEIGHT) - 60
	left_x: f32 = 220
	right_x: f32 = f32(HGWINDOWWIDTH) - 220

	layout_col(len(hg.vertices), left_x, top, bottom, &vertex_pos)
	layout_col(len(hg.nets), right_x, top, bottom, &net_pos)

	for ni in 0 ..< len(hg.nets) {
		start := int(hg.nets[ni].first_pin)
		end := start + int(hg.nets[ni].pin_count)
		if start < 0 {start = 0}
		if end < start {end = start}
		if end > len(hg.pins) {end = len(hg.pins)}
		net_degree[ni] = end - start
		for pi in start ..< end {
			vi := int(hg.pins[pi].vertex)
			if vi >= 0 && vi < len(vertex_degree) {
				vertex_degree[vi] += 1
			}
		}
	}

	camera := rl.Camera2D {
		offset   = rl.Vector2{0, 0},
		target   = rl.Vector2{0, 0},
		rotation = 0,
		zoom     = 1,
	}
	show_labels := false
	vertex_radius: f32 = 7
	net_radius: f32 = 5

	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(.L) {
			show_labels = !show_labels
		}

		if rl.IsMouseButtonDown(.MIDDLE) {
			delta := rl.GetMouseDelta()
			camera.target[0] -= delta[0] / camera.zoom
			camera.target[1] -= delta[1] / camera.zoom
		}

		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			mouse := rl.GetMousePosition()
			before := rl.GetScreenToWorld2D(mouse, camera)
			camera.zoom *= 1.0 + wheel * 0.12
			if camera.zoom < 0.15 {camera.zoom = 0.15}
			if camera.zoom > 6.0 {camera.zoom = 6.0}
			after := rl.GetScreenToWorld2D(mouse, camera)
			camera.target[0] += before[0] - after[0]
			camera.target[1] += before[1] - after[1]
		}

		hover_vertex := -1
		hover_net := -1
		world_mouse := rl.GetScreenToWorld2D(rl.GetMousePosition(), camera)
		best_dist_sq: f32 = 1e18
		vertex_pick := vertex_radius * 1.9
		net_pick := net_radius * 2.3

		for pos, vi in vertex_pos {
			dx := world_mouse[0] - pos[0]
			dy := world_mouse[1] - pos[1]
			dist_sq := dx * dx + dy * dy
			if dist_sq <= vertex_pick * vertex_pick && dist_sq < best_dist_sq {
				best_dist_sq = dist_sq
				hover_vertex = vi
				hover_net = -1
			}
		}
		for pos, ni in net_pos {
			dx := world_mouse[0] - pos[0]
			dy := world_mouse[1] - pos[1]
			dist_sq := dx * dx + dy * dy
			if dist_sq <= net_pick * net_pick && dist_sq < best_dist_sq {
				best_dist_sq = dist_sq
				hover_net = ni
				hover_vertex = -1
			}
		}

		for i in 0 ..< len(vertex_mark) {vertex_mark[i] = false}
		for i in 0 ..< len(net_mark) {net_mark[i] = false}

		if hover_vertex >= 0 {
			vertex_mark[hover_vertex] = true
			for ni in 0 ..< len(hg.nets) {
				start := int(hg.nets[ni].first_pin)
				end := start + int(hg.nets[ni].pin_count)
				if start < 0 {start = 0}
				if end < start {end = start}
				if end > len(hg.pins) {end = len(hg.pins)}
				for pi in start ..< end {
					vi := int(hg.pins[pi].vertex)
					if vi == hover_vertex {
						net_mark[ni] = true
						break
					}
				}
			}
		}

		if hover_net >= 0 {
			net_mark[hover_net] = true
			start := int(hg.nets[hover_net].first_pin)
			end := start + int(hg.nets[hover_net].pin_count)
			if start < 0 {start = 0}
			if end < start {end = start}
			if end > len(hg.pins) {end = len(hg.pins)}
			for pi in start ..< end {
				vi := int(hg.pins[pi].vertex)
				if vi >= 0 && vi < len(vertex_mark) {
					vertex_mark[vi] = true
				}
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 24, 30, 255})
		rl.BeginMode2D(camera)

		// Draw edges first so nodes sit on top
		for ni in 0 ..< len(hg.nets) {
			start := int(hg.nets[ni].first_pin)
			end := start + int(hg.nets[ni].pin_count)
			for pi in start ..< end {
				if pi < 0 || pi >= len(hg.pins) {
					continue
				}
				vi := int(hg.pins[pi].vertex)
				if vi < 0 || vi >= len(vertex_pos) {
					continue
				}
				highlight := vertex_mark[vi] && net_mark[ni]
				thickness: f32 = 1.25
				color := rl.Color{95, 110, 130, 60}
				if highlight {
					thickness = 2.5
					color = rl.Color{255, 232, 140, 220}
				}
				rl.DrawLineEx(vertex_pos[vi], net_pos[ni], thickness, color)
			}
		}

		for pos, vi in vertex_pos {
			radius := vertex_radius
			color := rl.Color{90, 200, 255, 225}
			if vertex_mark[vi] {
				radius = vertex_radius + 2.8
				color = rl.Color{120, 236, 255, 255}
			}
			rl.DrawCircleV(pos, radius, color)
			if show_labels || vertex_mark[vi] {
				rl.DrawText(
					rl.TextFormat("V%d d=%d", vi, vertex_degree[vi]),
					i32(pos[0] + 10),
					i32(pos[1] - 7),
					12,
					rl.Color{190, 225, 255, 255},
				)
			}
		}
		for pos, ni in net_pos {
			radius := net_radius
			color := rl.Color{255, 175, 75, 235}
			if net_mark[ni] {
				radius = net_radius + 2.3
				color = rl.Color{255, 205, 115, 255}
			}
			rl.DrawCircleV(pos, radius, color)
			if show_labels || net_mark[ni] {
				rl.DrawText(
					rl.TextFormat("N%d d=%d", ni, net_degree[ni]),
					i32(pos[0] + 8),
					i32(pos[1] - 7),
					12,
					rl.Color{255, 220, 170, 255},
				)
			}
		}
		rl.EndMode2D()

		rl.DrawText("Instances", 120, 20, 20, rl.Color{190, 225, 255, 255})
		rl.DrawText("Nets", HGWINDOWWIDTH - 280, 20, 20, rl.Color{255, 215, 165, 255})
		rl.DrawText(
			"L: labels  MMB drag: pan  Wheel: zoom  ESC: close",
			HGWINDOWWIDTH / 2 - 270,
			20,
			16,
			rl.Color{180, 180, 180, 255},
		)

		panel_x: i32 = 16
		panel_y: i32 = HGWINDOWHEIGHT - 122
		panel_w: i32 = HGWINDOWWIDTH - 32
		panel_h: i32 = 106
		rl.DrawRectangle(panel_x, panel_y, panel_w, panel_h, rl.Color{8, 12, 18, 225})
		rl.DrawRectangleLines(panel_x, panel_y, panel_w, panel_h, rl.Color{48, 62, 78, 255})

		rl.DrawText(
			rl.TextFormat(
				"vertices=%d  nets=%d  pins=%d  zoom=%.2f",
				len(hg.vertices),
				len(hg.nets),
				len(hg.pins),
				camera.zoom,
			),
			panel_x + 12,
			panel_y + 10,
			20,
			rl.Color{220, 225, 232, 255},
		)
		if hover_vertex >= 0 {
			rl.DrawText(
				rl.TextFormat(
					"hover vertex V%d: name=%u cell=%u degree=%d",
					hover_vertex,
					u32(hg.vertices[hover_vertex].name),
					u32(hg.vertices[hover_vertex].cell),
					vertex_degree[hover_vertex],
				),
				panel_x + 12,
				panel_y + 48,
				18,
				rl.Color{175, 230, 255, 255},
			)
		} else if hover_net >= 0 {
			rl.DrawText(
				rl.TextFormat(
					"hover net N%d: name=%u first_pin=%u pin_count=%u degree=%d",
					hover_net,
					u32(hg.nets[hover_net].name),
					hg.nets[hover_net].first_pin,
					hg.nets[hover_net].pin_count,
					net_degree[hover_net],
				),
				panel_x + 12,
				panel_y + 48,
				18,
				rl.Color{255, 220, 180, 255},
			)
		} else {
			rl.DrawText(
				"hover a node to inspect ids/degree and highlight neighbors",
				panel_x + 12,
				panel_y + 48,
				18,
				rl.Color{165, 175, 190, 255},
			)
		}
		rl.EndDrawing()
	}

}
