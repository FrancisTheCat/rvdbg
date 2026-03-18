package rvdbg

import la "core:math/linalg"
import    "core:os"

import ttf "odin-ttf"
import     "glodin"

Instance_Data :: struct {
	rect, tex_rect:      [4]f32,
	color, border_color: [4]f32,
	border_width_radius: [2]f32,
	has_font:            i32,
}

Renderer :: struct {
	quad:            glodin.Mesh,
	instance_buffer: [dynamic]Instance_Data,
	program:         glodin.Program,
	fonts:           [Ui_Font]Font,
	text_height:     int,
	font_draw_ctx:   Font_Draw_Context,

}

renderer_init :: proc(renderer: ^Renderer) {
	glodin.disable(.Cull_Face)

	Vertex_2D :: struct {
		position: [2]f32,
	}

	quad_vertex_buffer: []Vertex_2D = {
		{ position = { 0, 0, }, },
		{ position = { 0, 1, }, },
		{ position = { 1, 0, }, },

		{ position = { 1, 1, }, },
		{ position = { 0, 1, }, },
		{ position = { 1, 0, }, },
	}

	renderer.quad            = glodin.create_mesh(quad_vertex_buffer)
	renderer.instance_buffer = make([dynamic]Instance_Data, context.allocator)
	renderer.program         = glodin.create_program_source(#load("vertex.glsl"), #load("fragment.glsl")) or_else panic("Failed to compile program")

	for &font, font_id in renderer.fonts {
		font.data = os.read_entire_file(FONT_PATHS[font_id], context.allocator) or_else panic("Failed to open font file")
		font.font = ttf.load(font.data) or_else panic("Failed to load font")
	}

	font_draw_context_init(&renderer.font_draw_ctx)
}

renderer_destroy :: proc(renderer: Renderer) {
	glodin.destroy(renderer.quad)
	glodin.destroy(renderer.program)
	delete(renderer.instance_buffer)
	for font in renderer.fonts {
		delete(font.data)
	}

	font_draw_context_destroy(renderer.font_draw_ctx)
}

Render_Settings :: struct {
	subpixel:     bool,
	font_quality: int,
	text_height:  int,
	scale:        [2]f32,
}

render_ui :: proc(
	renderer:   ^Renderer,
	commands:   []Ui_Cmd,
	resolution: [2]int,
	settings:   Render_Settings,
) {
	if renderer.text_height != settings.text_height {
		for &font in renderer.fonts {
			font.font_height = f32(settings.text_height)
			font.scale       = ttf.font_height_to_scale(font.font, font.font_height)
		}
		renderer.text_height = settings.text_height
	}

	clear(&renderer.instance_buffer)

	for cmd in commands {
		switch cmd in cmd {
		case Ui_Cmd_Text:
			draw_string(
				&renderer.font_draw_ctx,
				&renderer.instance_buffer,
				&renderer.fonts[cmd.font],
				cmd.text,
				{ f32(cmd.position.x), f32(cmd.position.y), },
				renderer.fonts[cmd.font].scale,
				cmd.color,
			)
		case Ui_Cmd_Rect:
			rect := cmd.rect
			if rect.min.x > rect.max.x || rect.min.y > rect.max.y {
				break
			}

			append(&renderer.instance_buffer, Instance_Data {
				rect                = [4]f32{ f32(rect.min.x), f32(rect.min.y), f32(rect.max.x), f32(rect.max.y), },
				color               = cmd.color,
				border_color        = cmd.border.color,
				border_width_radius = [2]f32{ f32(cmd.border.width), f32(cmd.border.radius), } * settings.scale.y, // not correct when we are scaled non-uniformly, but do we really care?
			})

			min := la.array_cast(rect.min, f32)
			max := la.array_cast(rect.max, f32)
			draw_font_clear_quad(&renderer.font_draw_ctx, min, max)
		}
	}

	font_samples := 1 << uint(settings.font_quality)
	font_draw_context_draw(&renderer.font_draw_ctx, resolution, settings.scale, font_samples, settings.subpixel)

	glodin.enable(.Blend)
	defer glodin.disable(.Blend)

	mesh := glodin.create_instanced_mesh(renderer.quad, renderer.instance_buffer[:])
	defer glodin.destroy(mesh)

	font_mode := 0
	if settings.subpixel {
		font_mode = 1
	}

	glodin.set_uniforms(renderer.program, {
		{ "u_font_stencil", renderer.font_draw_ctx.stencil_texture, },
		{ "u_resolution",   la.array_cast(resolution, f32),         },
		{ "u_font_samples", i32(font_samples),                      },
		{ "u_font_mode",    i32(font_mode),                         },
		{ "u_scale",        settings.scale,                         },
	})

	glodin.draw({}, renderer.program, mesh)
}
