// The font rendering algorithm used here is not particularly good, at very least at lot more stuff should be cached, ideally on the gpu:
// We should probably store shape data per glyph on the gpu and then do a MultiDrawElementsIndirect to instance those glyph meshes
// At least we trivially support fractional scaling, font size changes and subpixel rendering and positioning
package rvdbg

import la "core:math/linalg"

import "glodin"
import ttf "odin-ttf"

ATLAS_RESOLUTION :: 512

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

Glyph_Cache :: struct {
	glyphs:        map[struct{ rune, ^Font, }]Glyph_Cache_Entry,
	mesh:          glodin.Mesh,
	count:         int,
	vertex_buffer: [dynamic]Font_Vertex,
}

Font_Vertex :: struct {
	position: [2]f32,
	clear:    f32,
	bezier:   i32,
}

draw_string :: proc(
	instance_buffer: ^[dynamic]Instance_Data,
	glyph_cache:     ^Glyph_Cache,
	draw_buffer:     ^[dynamic]glodin.Draw_Arrays_Indirect_Command,
	draw_data:       ^[dynamic]Glyph_Draw_Data,
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
			position.x    += font.scale * f32(space_advance * (4 - chars_in_line % 4))
			chars_in_line += 4 - chars_in_line % 4
			continue
		case:
			chars_in_line += 1
		}

		glyph := get_cached_glyph(glyph_cache, font, char)

		offset     := position
		position.x += font.scale * f32(glyph.x_advance)

		append(draw_buffer, glyph.draw_command)
		append(draw_data, Glyph_Draw_Data {
			offset = offset,
			scale  = scale,
		})

		min := la.floor(offset + (scale * la.array_cast(glyph.min, f32) - 1) * [2]f32{ 1, -1, })
		max := la.ceil (offset + (scale * la.array_cast(glyph.max, f32) + 1) * [2]f32{ 1, -1, })
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

Glyph_Draw_Data :: struct {
	offset, scale: [2]f32,
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
