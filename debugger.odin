package rvdbg

import "base:intrinsics"

import     "core:fmt"
import glm "core:math/linalg/glsl"
import la  "core:math/linalg"
import     "core:os"
import rb  "core:container/rbtree"
import     "core:reflect"
import     "core:slice"
import     "core:strconv"
import     "core:strings"
import     "core:time"
import     "core:terminal/ansi"
import     "core:unicode/utf8"
import     "core:mem/virtual"

import "glodin"
import "input"

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

	rb.init(&debugger.breakpoints)
	debugger.focused_address = debugger.cpu.pc
	debugger.register_names  = true

	ok := glfw.Init();
	assert(bool(ok), "glfw.Init")
	window := glfw.CreateWindow(900, 600, "", nil, nil)

	input.init(window)

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

	instance_buffer: [dynamic]Instance_Data

	start_time := time.now()

	for !glfw.WindowShouldClose(window) && !ui_ctx.should_close {
		if debugger.reset {
			virtual.release(raw_data(mem), len(mem))
			mem, err = virtual.reserve_and_commit(len(mem))
			assert(err == nil)

			cpu_init(&debugger.cpu, mem, sections, strings.to_writer(&debugger.output_buffer), start_label)
			strings.builder_reset(&debugger.output_buffer)
			debugger.reset = false
		}

		w, h        := glfw.GetFramebufferSize(window)
		ui_ctx.max.x = int(w)
		ui_ctx.max.y = int(h)

		mouse_position       := la.array_cast(input.get_mouse_position(), int)
		ui_ctx.mouse_delta    = mouse_position - ui_ctx.mouse_position
		ui_ctx.mouse_position = mouse_position
		ui_ctx.mouse_scroll   = la.array_cast(input.get_scroll(), int)

		current_time       := time.duration_seconds(time.since(start_time))
		ui_ctx.delta_time   = current_time - ui_ctx.current_time
		ui_ctx.current_time = current_time

		for &button, i in ui_ctx.mouse_buttons {
			pressed := input.get_mouse_button(i32(i))
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

		ui_ctx.keys_pressed = {}
		ui_ctx.keys_down    = {}
		for key, state in input.keys {
			keys: ^Ui_Key_Set
			#partial switch state {
			case .Just_Pressed:
				keys = &ui_ctx.keys_pressed
			case .Pressed:
				keys = &ui_ctx.keys_down
			case:
				continue
			}

			k: Ui_Key
			#partial switch key {
			case .Key_0 ..= .Key_9:
				k = ._0 + Ui_Key(key - .Key_0)
			case .F1 ..= .F24:
				k = .F1 + Ui_Key(key - .F1)
			case .A ..= .Z:
				k = .A  + Ui_Key(key - .A)
			case .Space:         k = .Space
			case .Apostrophe:    k = .Apostrophe
			case .Comma:         k = .Comma
			case .Minus:         k = .Minus
			case .Period:        k = .Period
			case .Slash:         k = .Slash
			case .Semicolon:     k = .Semicolon
			case .Equal:         k = .Equal
			case .Left_Bracket:  k = .Left_Bracket
			case .Backslash:     k = .Backslash
			case .Right_Bracket: k = .Right_Bracket
			case .Grave_Accent:  k = .Grave_Accent
			case .Backspace:     k = .Backspace
			case .Escape:        k = .Escape
			case .Enter:         k = .Enter
			case:
				continue
			}

			keys^ |= { k, }
		}

		debugger_ui(&ui_ctx, &debugger)

		glodin.clear_color(0, CLEAR_COLOR)

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
				draw_string(
					&instance_buffer,
					fonts[.Interface],
					cmd.text,
					{ f32(cmd.position.x), f32(cmd.position.y), },
					cmd.color,
				)
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

		glodin.draw({}, program, mesh)

		clear(&instance_buffer)

		glfw.SwapBuffers(window)

		input.poll()
		glfw.PollEvents()
	}
}

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
	cpu:             CPU,
	state:           CPU_State,
	output_buffer:   strings.Builder,
	running:         bool,
	breakpoints:     rb.Tree(u32, bool),
	focused_address: u32,
	register_names:  bool,
	reset:           bool,
	memory_view:     struct {
		input:   strings.Builder,
		address: u32,
	},
	last_error:      string,
}

debugger_ui :: proc(ctx: ^Ui_Context, debugger: ^Debugger) {
	if ctx.mouse_delta != 0 {
		ctx.mouse_last_move_time = ctx.current_time
	}
	ctx.frame_id += 1
	clear(&ctx.cmds)
	clear(&ctx.popups)
	ctx.min  = UI_PADDING
	ctx.max -= UI_PADDING
	if ctx.mouse_buttons[0] == .Just_Clicked {
		ctx.active_id = 0
	}

	BREAK_COLOR    :: [4]f32{ .5,   .3,   .3,   1, }
	CLOSE_COLOR    :: [4]f32{ .878, .42,  .455, 1, }
	MAXIMIZE_COLOR :: [4]f32{ .596, .765, .475, 1, }
	MINIMIZE_COLOR :: [4]f32{ .898, .753, .478, 1, }

	step := .F10 in ctx.keys_pressed
	run  := .F5  in ctx.keys_pressed

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

			ui_slider(ctx, "Padding",      &UI_PADDING)
			ui_slider(ctx, "Text Padding", &UI_TEXT_PADDING)
			ui_slider(ctx, "Border Width", &UI_BORDER_WIDTH)
			if .Clicked in ui_button(ctx, "Register Names") {
				debugger.register_names ~= true
			}
		}

		if ui_popup_toggle(ctx, "Run") {
			if .Clicked in ui_button(ctx, "Run") {
				run = true
			}
			if .Clicked in ui_button(ctx, "Step") {
				step = true
			}
			if .Clicked in ui_button(ctx, "Reset") {
				debugger.reset = true
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
			unimplemented()
		}
		if .Clicked in ui_color_button(ctx, size, MINIMIZE_COLOR, { radius = UI_BORDER_RADIUS, }) {
			unimplemented()
		}
	}

	debugger_execute_instruction :: proc(debugger: ^Debugger) {
		debugger.state = execute_instruction(&debugger.cpu)
		if node := rb.find(debugger.breakpoints, debugger.cpu.pc); node != nil && node.value {
			debugger.state = .Debugger_Breakpoint
		}
	}

	if run {
		debugger.state = .Running
		for debugger.state == .Running {
			debugger_execute_instruction(debugger)
		}
	}
	if step {
		debugger_execute_instruction(debugger)
	}

	if ui_section(ctx, "Footer", .Up, { .Separator, }) {
		ctx.direction = .Left
		ui_label(ctx, fmt.tprintf("Status: %v", debugger.state))
		if .Clicked in ui_button(ctx, fmt.tprintf("PC: 0x%08x", debugger.cpu.pc)) {
			debugger.focused_address = debugger.cpu.pc
		}
		ctx.direction = .Right
		if debugger.last_error != "" {
			if .Clicked in ui_button(ctx, debugger.last_error, border = {
				radius = UI_BORDER_RADIUS,
				width  = UI_BORDER_WIDTH,
				color  = CLOSE_COLOR,
			}) {
				debugger.last_error = ""
			}
		}
	}

	if ui_section(ctx, "Info Section", .Left, { .Separator, .Resizeable, }) {
		if ui_toggle(ctx, "Registers") {
			_ = ui_section(ctx, "Registers_Section", .Down, { .Separator, })
			for i in 0 ..< 32 / 4 {
				ui_section(ctx, fmt.tprintf("Registers_%d", i), .Down, {}) or_continue
				ctx.direction = .Right
				for j in 0 ..< 4 {
					register := Register(i * 4 + j)
					border: Ui_Border = {
						radius = UI_BORDER_RADIUS,
					}
					if register in debugger.cpu.registers_read {
						border.color = { .384, .675, .933, 1, }
						border.width = UI_BORDER_WIDTH
					}
					if register in debugger.cpu.registers_written {
						border.color = CLOSE_COLOR
						border.width = UI_BORDER_WIDTH
					}
					if .Tooltip in ui_label(ctx, fmt.tprintf("0x%08x", debugger.cpu.registers[register]), border = border) {
						if ui_tooltip_popup(ctx, fmt.tprintf("Tooltip_Registers_%d", register)) {
							ui_label(ctx, strings.to_lower(reflect.enum_name_from_value(register) or_else "---", context.temp_allocator))
						}
					}
				}
			}
		}

		if ui_toggle(ctx, "Memory") {
			_ = ui_section(ctx, "Memory_Section", .Down, { .Separator, })

			if .Submit in ui_textbox(ctx, &debugger.memory_view.input, "0x") {
				address, ok := strconv.parse_u64(strings.to_string(debugger.memory_view.input))
				if !ok && address < 1 << 32 {
					debugger.last_error = "Failed to parse memory address"
				} else {
					debugger.memory_view.address = u32(address)
				}
			}

			value := &debugger.cpu.mem[debugger.memory_view.address]
			ui_label(ctx, fmt.tprintf("0x%08x", intrinsics.unaligned_load((^u32)(value))))
		}

		if ui_toggle(ctx, "Breakpoints") {
			_ = ui_section(ctx, "Breakpoints_Section", .Down, { .Separator, })
			iterator := rb.iterator(&debugger.breakpoints, .Forward)
			for node in rb.iterator_next(&iterator) {
				address :=  node.key
				enabled := &node.value

				ui_section(ctx, fmt.tprintf("Breakpoint_%x", address), .Down, {}) or_continue
				ctx.direction = .Right

				color := enabled^ ? MAXIMIZE_COLOR : CLOSE_COLOR
				if .Clicked in ui_color_button(ctx, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, color, border = { radius = UI_BORDER_RADIUS, }) {
					enabled^ ~= true
				}
				if .Clicked in ui_button(ctx, fmt.tprintf("0x%08x", address)) {
					debugger.focused_address = address
				}
				if .Clicked in ui_color_button(ctx, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, CLOSE_COLOR, border = { radius = UI_BORDER_RADIUS, }) {
					rb.remove(&debugger.breakpoints, address)
				}
			}
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

			_ = ui_button(ctx, "Output")
			ui_draw_rect(ctx, ctx.rect, UI_DARK_COLOR, { radius = UI_BORDER_RADIUS, })
			str := strings.to_string(debugger.output_buffer)
			for len(str) != 0 {
				line := string_wrap(ctx, &str, ctx.max.x - ctx.min.x - UI_TEXT_PADDING * 2, .Interface, UI_TEXT_HEIGHT)
				if len(line) == 0 {
					break
				}
				ui_text(ctx, line, UI_TEXT_COLOR)
			}
		}
	}

	ui_text :: proc(ctx: ^Ui_Context, text: string, color: [4]f32, font: Ui_Font = .Interface, font_size := UI_TEXT_HEIGHT) {
		width := ctx.measure_text(.Interface, UI_TEXT_HEIGHT, text, ctx.user_pointer)
		ui_draw_text(ctx, text, ctx.min + [2]int{ UI_TEXT_PADDING, UI_TEXT_PADDING + UI_TEXT_HEIGHT, }, color, .Monospace)
		ctx.extents.max = la.max(
			ctx.extents.max,
			[2]int {
				ctx.min.x + int(width),
				ctx.min.y + UI_TEXT_PADDING * 2 + UI_TEXT_HEIGHT,
			},
		)
		ctx.min.y += UI_TEXT_PADDING * 2 + UI_TEXT_HEIGHT
	}

	ctx.space_width = ctx.measure_text(.Interface, UI_TEXT_HEIGHT, " ", ctx.user_pointer)

	ui_instruction :: proc(
		ctx:         ^Ui_Context,
		debugger:    ^Debugger,
		instruction: Instruction,
		address:     u32,
		active:      bool,
	) {
		ui_text :: proc(ctx: ^Ui_Context, text: string, color: [4]f32, font: Ui_Font = .Interface, font_size := UI_TEXT_HEIGHT) {
			width := int(ctx.measure_text(font, font_size, text, ctx.user_pointer))
			ui_draw_text(ctx, text, ctx.min + UI_TEXT_PADDING + [2]int{ 0, font_size, }, color, .Monospace)
			ctx.extents.max = la.max(
				ctx.extents.max,
				[2]int {
					ctx.min.x + UI_TEXT_PADDING * 2 + width,
					ctx.min.y + UI_TEXT_PADDING * 2 + font_size,
				},
			)
			ctx.min.x += width
		}

		id_str := fmt.tprint("Instruction_", address)
		state  := ui_state(ctx, id_str)^
		_       = ui_section(ctx, id_str, .Down, {})
		node   := rb.find(debugger.breakpoints, address)

		background_color: [4]f32
		border_color:     [4]f32
		border_width:     int

		background_rect      := Ui_Rect { ctx.min, ctx.min + state.size, }
		background_rect.max.x = ctx.max.x
		if rect_contains(background_rect, ctx.mouse_position) {
			background_color = UI_BUTTON_CLICKED_COLOR

			if ctx.mouse_buttons[0] == .Just_Clicked {
				if node != nil {
					node.value ~= true
				} else {
					rb.find_or_insert(&debugger.breakpoints, address, true)
				}
			}

			if ctx.mouse_buttons[1] == .Just_Clicked {
				node = nil
				rb.remove(&debugger.breakpoints, address)
			}
		} else if active {
			background_color = UI_BUTTON_COLOR
		}

		if node != nil {
			if node.value {
				border_color = CLOSE_COLOR
			} else {
				border_color = BREAK_COLOR
			}
			border_width = UI_BORDER_WIDTH
		}

		ui_draw_rect(ctx, background_rect, background_color, { radius = UI_BORDER_RADIUS, color = border_color, width = border_width, })

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
				if debugger.register_names {
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

	debugger.focused_address -= u32(ctx.mouse_scroll.y * 4)
	instruction_height       := UI_TEXT_HEIGHT + UI_PADDING + UI_TEXT_PADDING * 2
	visible_instructions     := max((ctx.max.y - ctx.min.y) / instruction_height, 0)
	instructions             := slice.reinterpret([]u32, debugger.cpu.mem[debugger.focused_address:])[:visible_instructions]

	pc_visible: bool
	for inst, i in instructions {
		disassembled, ok := disassemble_instruction(inst)
		if !ok {
			ui_text(ctx, "---", CLOSE_COLOR)
			continue
		}
		address := debugger.focused_address + u32(i) * 4
		ui_instruction(
			ctx,
			debugger,
			disassembled,
			debugger.focused_address + u32(i) * 4,
			address == debugger.cpu.pc,
		)

		pc_visible ||= address == debugger.cpu.pc
	}

	if !pc_visible && step {
		debugger.focused_address = debugger.cpu.pc
	}
}
