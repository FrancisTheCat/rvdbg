package rvdbg

import la "core:math/linalg"

import "glodin"
import ttf "odin-ttf"

@(rodata)
FONT_PATHS := [Ui_Font]string {
	.Interface = "/usr/share/fonts/TTF/IBMPlexSans-Regular.ttf",
	// .Interface = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	.Monospace = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
}

Font :: struct {
	font_height: f32,
	scale:       f32,
	font:        ttf.Font,
	data:        []byte,
}

Glyph_Cache_Entry :: struct {
	draw_command: glodin.Draw_Arrays_Indirect_Command,
	min, max:     [2]f32,
	x_advance:    f32,
}

Glyph_Cache_Key :: struct {
	char:  rune,
	font: ^Font,
}

Glyph_Cache :: struct {
	glyphs:        map[Glyph_Cache_Key]Glyph_Cache_Entry,
	mesh:          glodin.Mesh,
	count:         int,
	vertex_buffer: [dynamic]Font_Vertex,
}

Glyph_Draw_Command :: struct  {
	using draw_command: glodin.Draw_Arrays_Indirect_Command,
	offset: [2]f32,
	scale:  [2]f32,
}

Font_Draw_Context :: struct {
	glyph_cache:     Glyph_Cache,
	draw_buffer:     [dynamic]Glyph_Draw_Command,
	stencil_texture: glodin.Texture,
	color_texture:   glodin.Texture,
	fb:              glodin.Framebuffer,
	program:         glodin.Program,
	indirect_buffer: glodin.Indirect_Buffer,

	resolution: [2]int,
	scale:      [2]f32,
	samples:    int,
	subpixel:   bool,
}

font_draw_context_init :: proc(
	ctx: ^Font_Draw_Context,
	glyph_cache_size  := 1 << 20, // Max number of distinct glyphs in cache
	glyph_buffer_size := 1 << 20, // Max number of (non-distinct) glyphs drawn in one frame
	allocator         := context.allocator,
) {
	ctx.glyph_cache = {
		glyphs = make(map[Glyph_Cache_Key]Glyph_Cache_Entry, allocator),
		mesh   = glodin.create_mesh((([^]Font_Vertex)(nil))[:glyph_cache_size]),
	}

	ctx.glyph_cache.glyphs[{}] = {
		draw_command = {
			count          = 6,
			instance_count = 1,
			first_vertex   = 0,
		},
	}
	ctx.glyph_cache.count = 6

	clear_quad := []Font_Vertex {
		{ position = { 0, 0, }, },
		{ position = { 1, 0, }, },
		{ position = { 0, 1, }, },

		{ position = { 1, 1, }, },
		{ position = { 0, 1, }, },
		{ position = { 1, 0, }, },
	}
	glodin.set_mesh_data(ctx.glyph_cache.mesh, clear_quad)

	ctx.program = glodin.create_program_source(#load("font_vertex.glsl"), #load("font_fragment.glsl")) or_else panic("Failed to compile program")

	ctx.indirect_buffer = glodin.create_indirect_buffer(glyph_buffer_size, size_of(Glyph_Draw_Command))
}

font_draw_context_destroy :: proc(ctx: Font_Draw_Context) {
	delete(ctx.draw_buffer)

	delete(ctx.glyph_cache.glyphs)
	delete(ctx.glyph_cache.vertex_buffer)
	glodin.destroy(ctx.glyph_cache.mesh)

	glodin.destroy(ctx.stencil_texture)
	glodin.destroy(ctx.color_texture)
	glodin.destroy(ctx.fb)

	glodin.destroy(ctx.program)
	glodin.destroy(ctx.indirect_buffer)
}

font_draw_context_draw :: proc(
	ctx:       ^Font_Draw_Context,
	resolution: [2]int,
	scale:      [2]f32,
	samples  := 4,
	subpixel := false,
) {
	if resolution != ctx.resolution || scale != ctx.scale || samples != ctx.samples || subpixel != ctx.subpixel {
		ctx.resolution = resolution
		ctx.scale      = scale
		ctx.samples    = samples
		ctx.subpixel   = subpixel

		if ctx.fb != 0 {
			glodin.destroy(ctx.stencil_texture)
			glodin.destroy(ctx.color_texture)
			glodin.destroy(ctx.fb)
		}

		render_width := resolution.x
		if subpixel {
			render_width *= 3
		}

		ctx.stencil_texture = glodin.create_texture(render_width, resolution.y, format = .Stencil8, samples = samples)
		ctx.color_texture   = glodin.create_texture(render_width, resolution.y, format = .RGBA8,    samples = samples)
		ctx.fb              = glodin.create_framebuffer({ ctx.color_texture, } when ODIN_DEBUG else {}, stencil_texture = ctx.stencil_texture)
	}

	glodin.enable(.Stencil_Test)
	defer glodin.disable(.Stencil_Test)

	glodin.enable(.Sample_Shading)
	defer glodin.disable(.Sample_Shading)

	glodin.set_color_mask(false)
	defer glodin.set_color_mask(true)

	glodin.set_indirect_buffer_data(ctx.indirect_buffer, ctx.draw_buffer[:])

	glodin.set_uniforms(ctx.program, {
		{ "draw_command_ssbo", ctx.indirect_buffer,                },
		{ "u_resolution",      la.array_cast(ctx.resolution, f32), },
		{ "u_scale",           ctx.scale,                          },
	})

	glodin.clear_stencil(ctx.fb, 0)

	glodin.draw(ctx.fb, ctx.program, ctx.glyph_cache.mesh, indirect = ctx.indirect_buffer, count = len(ctx.draw_buffer))
	clear(&ctx.draw_buffer)
}

Font_Vertex :: struct {
	position: [2]f32,
	bezier:   i32,
}

draw_string :: proc(
	ctx:             ^Font_Draw_Context,
	instance_buffer: ^[dynamic]Instance_Data,
	font:            ^Font,
	text:             string,
	position, scale:  [2]f32,
	color:            [4]f32,
) {
	position := position

	space_advance, _ := ttf.get_glyph_horizontal_metrics(font.font, ttf.get_codepoint_glyph(font.font, ' '))

	chars_in_line: int
	for char in text {
		switch char {
		case '\t':
			position.x    += scale.x * f32(space_advance * (4 - chars_in_line % 4))
			chars_in_line += 4 - chars_in_line % 4
			continue
		case:
			chars_in_line += 1
		}

		glyph := get_cached_glyph(&ctx.glyph_cache, font, char)

		offset     := position
		position.x += scale.x * f32(glyph.x_advance)

		append(&ctx.draw_buffer, Glyph_Draw_Command {
			draw_command = glyph.draw_command,
			offset       = offset,
			scale        = scale,
		})

		min := offset + (scale * la.array_cast(glyph.min, f32) - 1) * [2]f32{ 1, -1, }
		max := offset + (scale * la.array_cast(glyph.max, f32) + 1) * [2]f32{ 1, -1, }
		append(instance_buffer, Instance_Data {
			rect     = [4]f32{ min.x, min.y, max.x, max.y, },
			color    = color,
			has_font = 1,
		})
	}
}

@(require_results)
measure_text :: proc(font: Font, text: string) -> f32 {
	width: int

	space_advance, _ := ttf.get_glyph_horizontal_metrics(font.font, ttf.get_codepoint_glyph(font.font, ' '))

	chars_in_line: int
	for char in text {
		switch char {
		case '\t':
			width         += space_advance * (4 - chars_in_line % 4)
			chars_in_line += 4 - chars_in_line % 4
			continue
		case:
			chars_in_line += 1
		}

		glyph        := ttf.get_codepoint_glyph(font.font, char)
		x_advance, _ := ttf.get_glyph_horizontal_metrics(font.font, glyph)
		width        += x_advance
	}

	return f32(width) * font.scale
}

@(require_results)
get_cached_glyph :: proc(
	glyph_cache: ^Glyph_Cache,
	font:        ^Font,
	char:         rune,
) -> Glyph_Cache_Entry {
	if cached, ok := glyph_cache.glyphs[{char, font}]; ok {
		return cached
	}

	glyph := ttf.get_codepoint_glyph(font.font, char)
	shape := ttf.get_glyph_shape(font.font, glyph, context.temp_allocator)

	center := (shape.min + shape.max) * 0.5

	for linear in shape.linears {
		a := linear.a
		b := linear.b

		if la.cross(a - center, b - center) < 0 {
			a, b = b, a
		}

		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * center, })
		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * a,      })
		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * b,      })
	}

	for bezier in shape.beziers {
		a := bezier.p0
		b := bezier.p2

		if la.cross(a - center, b - center) < 0 {
			a, b = b, a
		}

		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * center, })
		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * a,      })
		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * b,      })
	}

	for bezier in shape.beziers {
		p0 := bezier.p0
		p1 := bezier.p1
		p2 := bezier.p2

		if la.cross(p1 - p0, p2 - p0) < 0 {
			p0, p2 = p2, p0
		}

		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * p0, bezier = 1, })
		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * p1, bezier = 1, })
		append(&glyph_cache.vertex_buffer, Font_Vertex { position = [2]f32{ 1, -1, } * p2, bezier = 1, })
	}

	glodin.set_mesh_data(glyph_cache.mesh, glyph_cache.vertex_buffer[:], glyph_cache.count * size_of(Font_Vertex))

	advance, _ := ttf.get_glyph_horizontal_metrics(font.font, glyph)

	glyph_cache.glyphs[{char, font}] = {
		draw_command = {
			count          = u32(len(glyph_cache.vertex_buffer)),
			instance_count = 1,
			first_vertex   = u32(glyph_cache.count),
		},
		min       = shape.min,
		max       = shape.max,
		x_advance = f32(advance),
	}
	glyph_cache.count += len(glyph_cache.vertex_buffer)
	clear(&glyph_cache.vertex_buffer)

	return glyph_cache.glyphs[{char, font}]
}

draw_font_clear_quad :: proc(ctx: ^Font_Draw_Context, min, max: [2]f32) {
	append(&ctx.draw_buffer, Glyph_Draw_Command {
		draw_command = ctx.glyph_cache.glyphs[{}].draw_command,
		offset       = min,
		scale        = max - min,
	})
}
