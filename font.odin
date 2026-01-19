package rvdbg

import glm "core:math/linalg/glsl"
import "core:os"
import "core:slice"

import       "vendor:glfw"
import stbtt "vendor:stb/truetype"

import "glodin"

ATLAS_RESOLUTION :: 512

FONT_PATHS :: [Ui_Font]string {
	// .Interface = "/usr/share/fonts/inter/InterVariable.ttf",
	.Interface = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	.Monospace = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
}

CLEAR_COLOR :: UI_BACKGROUND_COLOR

window_x, window_y: i32

window :: proc(text: string) {
	ok := glfw.Init();
	assert(bool(ok), "glfw.Init")
	window := glfw.CreateWindow(900, 600, "", nil, nil)

	glfw.SetWindowSizeCallback(window, proc "c" (window: glfw.WindowHandle, x, y: i32) {
		window_x, window_y = x, y
	})

	glodin.init_glfw(window)
	defer glodin.uninit()

	window_x, window_y = 900, 600
	glodin.clear_color(0, CLEAR_COLOR)
	glodin.window_size_callback(900, 600)

	program := glodin.create_program_file("vertex.glsl", "fragment.glsl") or_else panic("Failed to compile program")
	defer glodin.destroy(program)

	atlas_pixels := make([]u8, ATLAS_RESOLUTION * ATLAS_RESOLUTION)
	defer delete(atlas_pixels)

	fonts: [Ui_Font]Font
	for font_path, font_id in FONT_PATHS {
		font_data := os.read_entire_file(font_path) or_else panic("Failed to open font file")
		defer delete(font_data)

		fonts[font_id].characters = make([]stbtt.bakedchar, 256)

		font_info: stbtt.fontinfo
		stbtt.InitFont(&font_info, raw_data(font_data), 0)

		ascent, descent: i32
		stbtt.GetFontVMetrics(&font_info, &ascent, &descent, nil)

		// This is the most accurate way to get glyph height to my knowledge and yes, that is insane
		cap_height: i32
		stbtt.GetCodepointBox(&font_info, 'H', nil, nil, nil, &cap_height)
		assert(cap_height > 0)

		scale        := f32(UI_TEXT_HEIGHT) / f32(cap_height)
		pixel_height := f32(ascent - descent) * scale

		result := stbtt.BakeFontBitmap(
			raw_data(font_data),
			0,
			pixel_height,
			raw_data(atlas_pixels),
			ATLAS_RESOLUTION,
			ATLAS_RESOLUTION,
			0,
			256,
			raw_data(fonts[font_id].characters),
		)
		assert(result > 0)

		fonts[font_id].texture = glodin.create_texture_with_data(
			ATLAS_RESOLUTION,
			ATLAS_RESOLUTION,
			atlas_pixels,
			mag_filter = .Nearest,
			min_filter = .Nearest,
		)
	}

	defer for font in fonts {
		delete(font.characters)
		glodin.destroy(font.texture)
	}

	glodin.enable(.Blend)

	ui_ctx: Ui_Context
	ui_ctx.measure_text = proc(font: Ui_Font, font_size: int, text: string, user_pointer: rawptr) -> int {
		return int(measure_text((^[Ui_Font]Font)(user_pointer)[font], text))
	}
	ui_ctx.user_pointer = &fonts

	quad := glodin.create_mesh(vertex_buffer[:])
	defer glodin.destroy_mesh(quad)

	for !glfw.WindowShouldClose(window) && !ui_ctx.should_close {
		glodin.clear_color(0, CLEAR_COLOR)

		w, h        := glfw.GetFramebufferSize(window)
		ui_ctx.max.x = int(w)
		ui_ctx.max.y = int(h)

		x, y                 := glfw.GetCursorPos(window)
		ui_ctx.mouse_position = { int(x), int(y), }

		for &button, i in ui_ctx.mouse_buttons {
			pressed := glfw.GetMouseButton(window, i32(i)) == glfw.PRESS
			if pressed {
				if button == .None {
					button = .Just_Clicked
				} else {
					button = .Clicked
				}
			} else {
				button = .None
			}
		}

		debugger_ui(&ui_ctx)

		glodin.set_uniforms(program, {
			{ "u_window_size", glm.vec2{ f32(w), f32(h), }, },
			{ "u_texture",     fonts[.Interface].texture,   },
		})

		slice.stable_sort_by(ui_ctx.cmds[:], proc(a, b: Ui_Cmd) -> bool {
			za, zb: int
			switch v in a {
			case Ui_Cmd_Text:
				za = v.z
			case Ui_Cmd_Rect:
				za = v.z
			}
			switch v in b {
			case Ui_Cmd_Text:
				zb = v.z
			case Ui_Cmd_Rect:
				zb = v.z
			}
			return za < zb
		})

		for cmd in ui_ctx.cmds {
			switch cmd in cmd {
			case Ui_Cmd_Text:
				draw_string(fonts[.Interface], cmd.text, { f32(cmd.position.x), f32(cmd.position.y), }, cmd.color)
			case Ui_Cmd_Rect:
				rect := cmd.rect
				append(&instance_buffer, Instance_Data {
					rect                = { f32(rect.min.x), f32(rect.min.y), f32(rect.max.x), f32(rect.max.y), },
					color               = cmd.color,
					border_color        = cmd.border.color,
					border_width_radius = { f32(cmd.border.width), f32(cmd.border.radius), },
				})
			}
		}

		mesh := glodin.create_instanced_mesh(quad, instance_buffer[:])
		defer glodin.destroy(mesh)

		glodin.draw(0, program, mesh)

		clear(&instance_buffer)

		glfw.SwapBuffers(window)

		glfw.PollEvents()
	}
}

instance_buffer: [dynamic]Instance_Data

Instance_Data :: struct {
	rect, tex_rect:      glm.vec4,
	color, border_color: glm.vec4,
	border_width_radius: glm.vec2,
	use_texture:         bool,
}

vertex_buffer: []Vertex_2D = {
	{ position = { 0, 0, }, },
	{ position = { 0, 1, }, },
	{ position = { 1, 0, }, },

	{ position = { 1, 1, }, },
	{ position = { 0, 1, }, },
	{ position = { 1, 0, }, },
}

Vertex_2D :: struct {
	position: glm.vec2,
}

Font :: struct {
	characters: []stbtt.bakedchar,
	texture:    glodin.Texture,
}

draw_string :: proc(
	font:     Font,
	str:      string,
	position: glm.vec2,
	color:    [4]f32,
) {
	position := position

	chars_in_line: int
	quad: stbtt.aligned_quad
	for char in str {
		switch char {
		case '\t':
			position.x    += font.characters[' '].xadvance * f32(4 - chars_in_line % 4)
			chars_in_line += 4 - chars_in_line % 4
			continue
		case:
			chars_in_line += 1
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

		append(&instance_buffer, Instance_Data {
			rect        = { quad.x0, quad.y0, quad.x1, quad.y1, },
			tex_rect    = { quad.s0, quad.t0, quad.s1, quad.t1, },
			color       = color,
			use_texture = true,
		})
	}
}

measure_text :: proc(font: Font, text: string) -> f32 {
	p: glm.vec2

	chars_in_line: int
	quad: stbtt.aligned_quad
	for char in text {
		switch char {
		case '\t':
			p.x           += font.characters[' '].xadvance * f32(4 - chars_in_line % 4)
			chars_in_line += 4 - chars_in_line % 4
			continue
		case:
			chars_in_line += 1
		}
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
