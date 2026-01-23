package rvdbg

import     "core:fmt"
import glm "core:math/linalg/glsl"
import la  "core:math/linalg"
import os  "core:os/os2"
import     "core:reflect"
import     "core:slice"
import     "core:strings"
import     "core:mem/virtual"
import     "core:terminal/ansi"
import     "core:unicode/utf8"

import "glodin"

import       "vendor:glfw"
import stbtt "vendor:stb/truetype"

CLEAR_COLOR :: UI_BACKGROUND_COLOR

window_x, window_y: i32

window :: proc(source: string) {
	sections, relocations, labels, errors := parse_assembly(source)
	linker_errors := resolve_relocations(sections, labels, relocations)

	mem, err := virtual.reserve_and_commit(1 << 32 + 3)
	assert(err == nil)

	for section in sections {
		#partial switch section.type {
		case .Text:
			print_disassembly(section, assemble_instructions(section.data.?), source, syntax_highlighting = true)
		case .Data, .Rodata:
			print_disassembly(section, {}, source)
		}
	}

	start_label, start_label_found := labels["_start"]
	if !start_label_found {
		fmt.println("No `_start` label found, starting at PC = 0")
	}

	error: bool
	for e in errors {
		switch e.severity {
		case .Error:
			fmt.print(ansi.CSI + ansi.FG_RED + ansi.SGR)
			error = true
		case .Warning:
			fmt.print(ansi.CSI + ansi.FG_YELLOW + ansi.SGR)
		}
		fmt.printfln("%d: %s", e.line, e.message)
		fmt.print(ansi.CSI + ansi.RESET + ansi.SGR)
	}

	for e in linker_errors {
		switch e.severity {
		case .Error:
			fmt.print(ansi.CSI + ansi.FG_RED + ansi.SGR)
			error = true
		case .Warning:
			fmt.print(ansi.CSI + ansi.FG_YELLOW + ansi.SGR)
		}
		fmt.printfln("%d: %s", e.line, e.message)
		fmt.print(ansi.CSI + ansi.RESET + ansi.SGR)
	}

	if error {
		return
	}

	debugger: Debugger
	cpu_init(&debugger.cpu, mem, sections, strings.to_writer(&debugger.output_buffer), start_label)

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
		font_data := os.read_entire_file(font_path, context.allocator) or_else panic("Failed to open font file")
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
	ui_ctx.measure_text = proc(font: Ui_Font, font_size: int, text: string, user_pointer: rawptr) -> f32 {
		return measure_text((^[Ui_Font]Font)(user_pointer)[font], text)
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
		mouse_position       := [2]int{ int(x), int(y), }
		ui_ctx.mouse_delta    = mouse_position - ui_ctx.mouse_position
		ui_ctx.mouse_position = mouse_position

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

		debugger_ui(&ui_ctx, &debugger)

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

Debugger :: struct {
	cpu:           CPU,
	state:         CPU_State,
	output_buffer: strings.Builder,
	running:       bool,
}

debugger_ui :: proc(ctx: ^Ui_Context, debugger: ^Debugger) {
	clear(&ctx.cmds)
	clear(&ctx.popups)
	ctx.min  = UI_PADDING
	ctx.max -= UI_PADDING

	CLOSE_COLOR    :: [4]f32{ .878, .42,  .455, 1, }
	MAXIMIZE_COLOR :: [4]f32{ .596, .765, .475, 1, }
	MINIMIZE_COLOR :: [4]f32{ .898, .753, .478, 1, }

	if ui_section(ctx, "Menu Bar", .Down, { .Separator, }) {
		ctx.direction = .Right
		if ui_popup_toggle(ctx, "File") {
			_ = ui_button(ctx, "Open")
			_ = ui_button(ctx, "Save")
			_ = ui_button(ctx, "Close")
		}
		if ui_popup_toggle(ctx, "Edit") {
			_ = ui_button(ctx, "Undo")
			_ = ui_button(ctx, "Redo")
		}
		if ui_popup_toggle(ctx, "Settings") {
			ui_slider :: proc(ctx: ^Ui_Context, name: string, value: ^int) {
				if ui_section(ctx, name, .Down, {}) {
					ctx.direction = .Right
					if .Clicked in ui_color_button(ctx, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, MAXIMIZE_COLOR, { radius = UI_BORDER_RADIUS}) {
						value^ += 1
					}
					if .Clicked in ui_color_button(ctx, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, CLOSE_COLOR,    { radius = UI_BORDER_RADIUS}) {
						value^ -= 1
					}
					_ = ui_button(ctx, name)
				}
			}

			ui_slider(ctx, "Padding",       &UI_PADDING)
			ui_slider(ctx, "Text Padding",  &UI_TEXT_PADDING)
			ui_slider(ctx, "Border Radius", &UI_BORDER_RADIUS)
			ui_slider(ctx, "Border Width",  &UI_BORDER_WIDTH)
		}

		if ui_popup_toggle(ctx, "Run") {
			if .Clicked in ui_button(ctx, "Run") {
				for debugger.state == .Running {
					debugger.state = execute_instruction(&debugger.cpu)
				}
			}
			_ = ui_button(ctx, "Start")
			if .Clicked in ui_button(ctx, "Step") {
				debugger.state = execute_instruction(&debugger.cpu)
			}
		}

		if ui_popup_toggle(ctx, "Help") {
			ui_label(ctx, "Skill issue")
		}

		ctx.direction = .Left
		size := UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2
		if .Clicked in ui_color_button(ctx, size, CLOSE_COLOR,    { radius = UI_BORDER_RADIUS, }) {
			ctx.should_close = true
		}
		if .Clicked in ui_color_button(ctx, size, MAXIMIZE_COLOR, { radius = UI_BORDER_RADIUS, }) {
			
		}
		if .Clicked in ui_color_button(ctx, size, MINIMIZE_COLOR, { radius = UI_BORDER_RADIUS, }) {
			
		}
	}

	if ui_section(ctx, "Footer", .Up, { .Separator, }) {
		ctx.direction = .Left
		ui_label(ctx, fmt.tprintf("Status: %v", debugger.state))
		ui_label(ctx, fmt.tprintf("PC: 0x%08x", debugger.cpu.pc))
	}

	if ui_section(ctx, "Info Section", .Left, { .Separator, .Resizeable, }) {
		if ui_toggle(ctx, "Registers") {
			_ = ui_section(ctx, "Registers_Section", .Down, { .Separator, })
			for i in 0 ..< 32 / 4 {
				ui_section(ctx, fmt.tprintf("Registers_%d", i), .Down, {}) or_continue
				ctx.direction = .Right
				for j in 0 ..< 4 {
					ui_label(ctx, fmt.tprintf("0x%08x", debugger.cpu.registers[Register(i * 4 + j)]))
				}
			}
		}

		if ui_toggle(ctx, "Callstack") {
			_ = ui_section(ctx, "Callstack_Section", .Down, { .Separator, })
			for i in 0 ..< 4 {
				_ = ui_button(ctx, fmt.tprintf("0x%08x", i))
			}
		}

		if ui_toggle(ctx, "Memory") {
			_ = ui_section(ctx, "Memroy_Section", .Down, { .Separator, })
			ui_label(ctx, "...")
		}
	}

	if ui_section(ctx, "Output", .Up, { .Separator, .Resizeable, }) {
		if ctx.max.x > ctx.min.x {
			string_wrap :: proc(ctx: ^Ui_Context, str: ^string, max_width: int, font: Ui_Font, font_size: int) -> string {
				n: int
				w: f32
				for w < f32(max_width) && n < len(str) {
					_, rune_len := utf8.decode_rune(str[n:])
					rune_width  := ctx.measure_text(font, font_size, str[n:][:rune_len], ctx.user_pointer)
					if w + rune_width > f32(max_width) {
						break
					}
					w += rune_width
					n += rune_len
				}

				defer str^ = str[n:]
				return str[:n]
			}

			ui_text :: proc(ctx: ^Ui_Context, text: string, color: [4]f32, font: Ui_Font = .Interface, font_size := UI_TEXT_HEIGHT) {
				width := ctx.measure_text(.Interface, UI_TEXT_HEIGHT, text, ctx.user_pointer)
				ui_draw_text(ctx, text, ctx.min + [2]int{ 0, UI_TEXT_PADDING + UI_TEXT_HEIGHT, }, color, .Monospace)
				ctx.extents.max = la.max(
					ctx.extents.max,
					[2]int {
						ctx.min.x + int(width),
						ctx.min.y + UI_TEXT_PADDING * 2 + UI_TEXT_HEIGHT,
					},
				)
				ctx.min.y += UI_TEXT_PADDING * 2 + UI_TEXT_HEIGHT
			}

			_ = ui_button(ctx, "Output")
			ui_draw_rect(ctx, ctx.rect, UI_DARK_COLOR, { radius = UI_BORDER_RADIUS, })
			ctx.min.x += UI_TEXT_PADDING
			str := strings.to_string(debugger.output_buffer)
			for len(str) != 0 {
				line := string_wrap(ctx, &str, ctx.max.x - ctx.min.x - UI_TEXT_PADDING, .Interface, UI_TEXT_HEIGHT)
				if len(line) == 0 {
					break
				}
				ui_text(ctx, line, UI_TEXT_COLOR)
			}
		}
	}

	instructions := []u32 {
		0xfff50513,
		0xfff60513,
		0xfff70513,
		0x00100137,
		0x00012083,
	}

	ctx.space_width = ctx.measure_text(.Interface, UI_TEXT_HEIGHT, " ", ctx.user_pointer)

	ui_instruction :: proc(ctx: ^Ui_Context, instruction: Instruction, id: int, active: bool, register_names := false) {
		ui_text :: proc(ctx: ^Ui_Context, text: string, color: [4]f32, font: Ui_Font = .Interface, font_size := UI_TEXT_HEIGHT) {
			width := int(ctx.measure_text(.Interface, UI_TEXT_HEIGHT, text, ctx.user_pointer))
			ui_draw_text(ctx, text, ctx.min + UI_TEXT_PADDING + [2]int{ 0, UI_TEXT_HEIGHT, }, color, .Monospace)
			ctx.extents.max = la.max(
				ctx.extents.max,
				[2]int {
					ctx.min.x + UI_TEXT_PADDING * 2 + width,
					ctx.min.y + UI_TEXT_PADDING * 2 + UI_TEXT_HEIGHT,
				},
			)
			ctx.min.x += width
		}

		id_str := fmt.tprint("Instruction_", id)
		state  := ui_state(ctx, id_str)^
		_       = ui_section(ctx, id_str, .Down, {})

		background_color: [4]f32
		background_rect := Ui_Rect { ctx.min, ctx.min + state.size, }
		if rect_contains(background_rect, ctx.mouse_position) {
			background_color = UI_BUTTON_CLICKED_COLOR
		} else if active {
			background_color = UI_BUTTON_COLOR
		}
		if background_color != 0 {
			ui_draw_rect(ctx, background_rect, background_color, { radius = UI_BORDER_RADIUS, })
		}

		info   := instruction_infos[instruction.mnemonic]
		offset := false

		ui_text(ctx, info.mnemonic, { .384, .675, .933, 1, })
		ctx.min.x += int(ctx.space_width * f32(MAX_MNEMONIC_LEN - len(info.mnemonic) + 1))

		for arg, i in info.args {
			if i != 0 && !offset {
				ui_text(ctx, ", ", UI_TEXT_COLOR)
			}
			reg: Maybe(Register)
			switch arg {
			case .Imm12, .Imm20, .Uimm5, .Uimm20, .Rel12, .Rel20, .Addr:
				ui_text(ctx, fmt.tprintf("%#x", instruction.imm), CLOSE_COLOR)
			case .Off12:
				ui_text(ctx, fmt.tprintf("%#x", instruction.imm), CLOSE_COLOR)
				ui_text(ctx, "(", UI_TEXT_COLOR)
				offset = true
			case .Rd:
				reg = instruction.rd
			case .Rs1:
				reg = instruction.rs1
			case .Rs2:
				reg = instruction.rs2
			case .Imm, .Rel:
				unreachable()
			}

			if reg, ok := reg.?; ok {
				if register_names {
					ui_text(ctx, strings.to_lower(reflect.enum_name_from_value(reg) or_else panic("")), UI_TEXT_COLOR)
				} else {
					ui_text(ctx, fmt.tprintf("x%d", int(reg)), UI_TEXT_COLOR)
				}
			}

			if arg != .Off12 && offset {
				ui_text(ctx, ")", UI_TEXT_COLOR)
				offset = false
			}
		}
	}

	for inst, i in instructions {
		ui_instruction(ctx, disassemble_instruction(inst) or_continue, i, i == 2)
	}
}
