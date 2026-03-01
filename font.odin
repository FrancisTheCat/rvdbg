package rvdbg

import glm "core:math/linalg/glsl"

import stbtt "vendor:stb/truetype"

import "glodin"

ATLAS_RESOLUTION :: 512

FONT_PATHS :: [Ui_Font]string {
	.Interface = "/usr/share/fonts/inter/InterVariable.ttf",
	// .Interface = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	.Monospace = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
}

Font :: struct {
	characters: []stbtt.bakedchar,
	texture:    glodin.Texture,
}

draw_string :: proc(
	instance_buffer: ^[dynamic]Instance_Data,
	font:            Font,
	font_id:         i32,
	str:             string,
	position:        glm.vec2,
	color:           [4]f32,
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

		append(instance_buffer, Instance_Data {
			rect        = { quad.x0, quad.y0, quad.x1, quad.y1, },
			tex_rect    = { quad.s0, quad.t0, quad.s1, quad.t1, },
			color       = color,
			texture     = font_id,
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
