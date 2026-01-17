package rvdbg

import glm "core:math/linalg/glsl"
import "core:os"

import "vendor:glfw"
import stbtt "vendor:stb/truetype"

import "glodin"

ATLAS_RESOLUTION :: 512
FONT_SIZE :: 48

window_x, window_y: i32

window :: proc(text: string) {
	ok := glfw.Init();assert(bool(ok))
	window := glfw.CreateWindow(900, 600, "", nil, nil)

	glfw.SetWindowSizeCallback(window, proc "c" (window: glfw.WindowHandle, x, y: i32) {
		window_x, window_y = x, y
		context = {}
		glodin.clear_color(0, 0.1)
	})

	glodin.init_glfw(window)
	defer glodin.uninit()

	window_x, window_y = 900, 600
	glodin.clear_color(0, 0.1)
	glodin.window_size_callback(900, 600)

	program :=
		glodin.create_program_file("vertex.glsl", "fragment.glsl") or_else panic(
			"Failed to compile program",
		)
	defer glodin.destroy(program)

	data := os.read_entire_file("/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf") or_else panic("Failed to open font file")
	defer delete(data)

	out_data := make([]u8, ATLAS_RESOLUTION * ATLAS_RESOLUTION)
	defer delete(out_data)

	font: Font
	font.characters = make([]stbtt.bakedchar, 256)
	defer delete(font.characters)

	result := stbtt.BakeFontBitmap(
		raw_data(data),
		0,
		cast(f32)FONT_SIZE,
		raw_data(out_data),
		ATLAS_RESOLUTION,
		ATLAS_RESOLUTION,
		0,
		256,
		raw_data(font.characters),
	)
	assert(result > 0)

	font.texture = glodin.create_texture_with_data(ATLAS_RESOLUTION, ATLAS_RESOLUTION, out_data)
	glodin.set_texture_sampling_state(font.texture, .Nearest, .Nearest)
	defer glodin.destroy(font.texture)

	glodin.set_uniforms(program, {
		{ "u_texture", font.texture,               },
		{ "u_color",   glm.vec4{0.8, 0.6, 0.5, 1}, },
	})
	glodin.enable(.Blend)

	for !glfw.WindowShouldClose(window) {
		glodin.clear_color(0, 0.1)

		draw_string(font, text, glm.round(glm.vec2{-f32(window_x), -f32(window_y) + FONT_SIZE * 1.5} * 0.5 + 10))

		mesh := glodin.create_mesh(vertex_buffer[:])
		defer glodin.destroy_mesh(mesh)

		glodin.draw(0, program, mesh)

		clear(&vertex_buffer)

		glfw.SwapBuffers(window)

		glfw.PollEvents()
	}

	glodin.write_texture_to_png(font.texture, "atlas.png")
}

vertex_buffer: [dynamic]Vertex_2D

Vertex_2D :: struct {
	position:   glm.vec2,
	tex_coords: glm.vec2,
}

Font :: struct {
	characters: []stbtt.bakedchar,
	texture:    glodin.Texture,
}

draw_string :: proc(font: Font, str: string, position: glm.vec2) {
	start_position := position
	position       := position

	quad: stbtt.aligned_quad
	for char in str {
		if char == '\n' {
			position.x = start_position.x
			position.y += FONT_SIZE
			continue
		}
		if char == '\t' {
			position.x += font.characters[' '].xadvance * 4
			continue
		}
		stbtt.GetBakedQuad(
			raw_data(font.characters),
			ATLAS_RESOLUTION,
			ATLAS_RESOLUTION,
			i32(char),
			&position.x,
			&position.y,
			&quad,
			true,
		)

		// quad.t0 -= 0.5 / ATLAS_RESOLUTION
		// quad.t1 -= 0.5 / ATLAS_RESOLUTION
		// quad.s0 += 0.5 / ATLAS_RESOLUTION
		// quad.s1 += 0.5 / ATLAS_RESOLUTION

		append(
			&vertex_buffer,
			Vertex_2D {
				position   = 2 * glm.vec2{quad.x0, quad.y0} / glm.vec2{f32(window_x), f32(window_y)},
				tex_coords = {quad.s0, quad.t0},
			},
			Vertex_2D {
				position   = 2 * glm.vec2{quad.x0, quad.y1} / glm.vec2{f32(window_x), f32(window_y)},
				tex_coords = {quad.s0, quad.t1},
			},
			Vertex_2D {
				position   = 2 * glm.vec2{quad.x1, quad.y1} / glm.vec2{f32(window_x), f32(window_y)},
				tex_coords = {quad.s1, quad.t1},
			},

			Vertex_2D {
				position   = 2 * glm.vec2{quad.x0, quad.y0} / glm.vec2{f32(window_x), f32(window_y)},
				tex_coords = {quad.s0, quad.t0},
			},
			Vertex_2D {
				position   = 2 * glm.vec2{quad.x1, quad.y0} / glm.vec2{f32(window_x), f32(window_y)},
				tex_coords = {quad.s1, quad.t0},
			},
			Vertex_2D {
				position   = 2 * glm.vec2{quad.x1, quad.y1} / glm.vec2{f32(window_x), f32(window_y)},
				tex_coords = {quad.s1, quad.t1},
			},
		)
	}
}

measure_text :: proc(font: Font, text: string) -> f32 {
	p: glm.vec2

	quad: stbtt.aligned_quad
	for char in text {
		stbtt.GetBakedQuad(
			raw_data(font.characters),
			ATLAS_RESOLUTION,
			ATLAS_RESOLUTION,
			i32(char),
			&p.x,
			&p.y,
			&quad,
			true,
		)
	}

	return p.x
}
