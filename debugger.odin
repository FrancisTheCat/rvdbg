package rvdbg

import "base:intrinsics"

import rb  "core:container/rbtree"
import     "core:fmt"
import la  "core:math/linalg"
import glm "core:math/linalg/glsl"
import     "core:mem"
import     "core:mem/virtual"
import     "core:os"
import     "core:slice"
import     "core:strings"
import     "core:terminal/ansi"
import     "core:time"
import     "core:unicode/utf8"

import "glodin"
import "input"

import       "vendor:glfw"
import stbtt "vendor:stb/truetype"

window :: proc(source: string) {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)

		defer for _, leak in track.allocation_map {
			fmt.printf("%v leaked %m\n", leak.location, leak.size)
		}
		defer for bad in track.bad_free_array {
			fmt.printf("bad free: %v", bad.location)
		}
	}
	
	sections, relocations, labels, errors := parse_assembly(source, context.temp_allocator, context.temp_allocator)
	linker_errors := resolve_relocations(sections, labels, relocations, context.temp_allocator)

	mem, err := virtual.reserve_and_commit(1 << 32 + 3)
	assert(err == nil)

	for section in sections {
		#partial switch section.type {
		case .Text:
			print_disassembly(section, assemble_instructions(section.data.?, context.temp_allocator), source, syntax_highlighting = true)
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

	debugger.focused_address = debugger.cpu.pc
	debugger.register_names  = true

	rb.init(&debugger.breakpoints)

	defer {
		strings.builder_destroy(&debugger.output_buffer)
		strings.builder_destroy(&debugger.memory_view.input)
		watch_window_destroy(&debugger.watch_window)
		rb.destroy(&debugger.breakpoints)
		delete(debugger.last_error)
	}

	ok := glfw.Init();
	assert(bool(ok), "glfw.Init")
	defer glfw.Terminate()

	window := glfw.CreateWindow(900, 600, "", nil, nil)
	defer glfw.DestroyWindow(window)

	input.init(window)

	glodin.init_glfw(window)
	defer glodin.uninit()

	CLEAR_COLOR :: UI_DEFAULT_THEME.colors[.Background]

	glodin.window_size_callback(900, 600)
	glodin.clear_color(0, CLEAR_COLOR)

	program := glodin.create_program_file("vertex.glsl", "fragment.glsl") or_else panic("Failed to compile program")
	defer glodin.destroy(program)

	atlas_pixels := make([]u8, ATLAS_RESOLUTION * ATLAS_RESOLUTION)
	defer delete(atlas_pixels)

	fonts: [Ui_Font]Font
	for &font in fonts {
		font.characters = make([]stbtt.bakedchar, 256)
	}

	defer for font in fonts {
		delete(font.characters)
		glodin.destroy(font.texture)
	}

	glodin.enable(.Blend)

	ui_ctx: Ui_Context
	ui_context_init(
		&ui_ctx,
		proc(font: Ui_Font, font_size: int, text: string, user_pointer: rawptr) -> f32 {
			return measure_text((^[Ui_Font]Font)(user_pointer)[font], text)
		},
		&fonts,
	)
	defer ui_context_destroy(&ui_ctx)

	quad := glodin.create_mesh(vertex_buffer[:])
	defer glodin.destroy_mesh(quad)

	instance_buffer := make([dynamic]Instance_Data, context.allocator)
	defer delete(instance_buffer)

	start_time := time.now()

	prev_time: f64
	prev_mouse_position: [2]int
	prev_text_height := -1

	for !glfw.WindowShouldClose(window) && !ui_ctx.should_close {
		if debugger.reset {
			virtual.release(raw_data(mem), len(mem))
			mem, err = virtual.reserve_and_commit(len(mem))
			assert(err == nil)

			cpu_init(&debugger.cpu, mem, sections, strings.to_writer(&debugger.output_buffer), start_label)
			strings.builder_reset(&debugger.output_buffer)
			debugger.reset = false
		}

		if ui_ctx.theme.text_height != prev_text_height {
			for font_path, font_id in FONT_PATHS {
				font_data := os.read_entire_file(font_path, context.temp_allocator) or_else panic("Failed to open font file")

				font_info: stbtt.fontinfo
				stbtt.InitFont(&font_info, raw_data(font_data), 0)

				ascent, descent: i32
				stbtt.GetFontVMetrics(&font_info, &ascent, &descent, nil)

				// This is the most accurate way to get glyph height to my knowledge and yes, that is insane
				cap_height: i32
				stbtt.GetCodepointBox(&font_info, 'H', nil, nil, nil, &cap_height)
				assert(cap_height > 0)

				scale        := f32(ui_ctx.theme.text_height) / f32(cap_height)
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

				if fonts[font_id].texture != 0 {
					glodin.destroy(fonts[font_id].texture)
				}
				fonts[font_id].texture = glodin.create_texture_with_data(
					ATLAS_RESOLUTION,
					ATLAS_RESOLUTION,
					atlas_pixels,
					mag_filter = .Nearest,
					min_filter = .Nearest,
				)
			}
			prev_text_height = ui_ctx.theme.text_height
		}

		mouse_position     := la.array_cast(input.get_mouse_position(), int)
		mouse_delta        := mouse_position - prev_mouse_position
		prev_mouse_position = mouse_position

		current_time := time.duration_seconds(time.since(start_time))
		delta_time   := current_time - prev_time
		prev_time     = current_time

		mouse_buttons: [2]Ui_Button_State
		for &button, i in mouse_buttons {
			state := input.get_mouse_button_raw(i32(i))
			switch state {
			case .Not_Pressed:
				button = .None
			case .Just_Released:
				button = .None
			case .Just_Pressed:
				button = .Just_Clicked
			case .Pressed:
				button = .Clicked
			}
		}

		keys_pressed: Ui_Key_Set
		keys_down:    Ui_Key_Set
		for key, state in input.keys {
			keys: ^Ui_Key_Set
			#partial switch state {
			case .Just_Pressed:
				keys = &keys_pressed
			case .Pressed:
				keys = &keys_down
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
			case .Left_Shift:    k = .Left_Shift
			case .Right_Shift:   k = .Right_Shift
			case:
				continue
			}

			keys^ |= { k, }
		}

		w, h := glfw.GetFramebufferSize(window)

		ui_begin_frame(
			&ui_ctx,
			int(w),
			int(h),
			mouse_position,
			mouse_delta,
			la.array_cast(input.get_scroll(), int),
			mouse_buttons,
			keys_pressed,
			keys_down,
			input.get_text_input(),
			current_time,
			delta_time,
		)

		debugger_ui(&ui_ctx, &debugger)

		glodin.clear_color(0, CLEAR_COLOR)

		glodin.set_uniforms(program, {
			{ "u_window_size",     glm.vec2{ f32(w), f32(h), }, },
			{ "u_atlas_interface", fonts[.Interface].texture,   },
			{ "u_atlas_monospace", fonts[.Monospace].texture,   },
		})

		for cmd in ui_get_draw_commands(ui_ctx) {
			switch cmd in cmd {
			case Ui_Cmd_Text:
				draw_string(
					&instance_buffer,
					fonts[cmd.font],
					i32(cmd.font),
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

		free_all(context.temp_allocator)
	}
}

Instance_Data :: struct {
	rect, tex_rect:      glm.vec4,
	color, border_color: glm.vec4,
	border_width_radius: glm.vec2,
	texture:             i32,
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
	watch_window:    Watch_Window,
	last_error:      string,
}

debugger_ui :: proc(ctx: ^Ui_Context, debugger: ^Debugger) {
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
			@(static)
			max_width: int
			last_max_width := max_width
			max_width       = 0

			named_slider :: proc(ctx: ^Ui_Context, name: string, value: ^int) {
				if ui_section(ctx, name, .Down, {}) {
					ctx.direction = .Right

					min_size: [2]int
					ui_label(ctx, name, min_size = &min_size)
					max_width = max(max_width, min_size.x)
					ctx.min_size.x = 0
					ui_slider(ctx, value, 0, 20)
				}
			}

			ctx.min_size.x = last_max_width
			named_slider(ctx, "Padding",       &ctx.theme.padding)
			named_slider(ctx, "Text Padding",  &ctx.theme.text_padding)
			named_slider(ctx, "Border Width",  &ctx.theme.border_width)
			named_slider(ctx, "Border Radius", &ctx.theme.border_radius)
			named_slider(ctx, "Text Height",   &ctx.theme.text_height)

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
		size := ctx.theme.text_height + ctx.theme.text_padding * 2
		if .Clicked in ui_color_button(ctx, size, CLOSE_COLOR) {
			ctx.should_close = true
		}
		if .Clicked in ui_color_button(ctx, size, MAXIMIZE_COLOR) {
			unimplemented()
		}
		if .Clicked in ui_color_button(ctx, size, MINIMIZE_COLOR) {
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
		ui_label(ctx, fmt.tprintf("Status: %v", debugger.state), font = .Monospace)
		if .Clicked in ui_button(ctx, fmt.tprintf("PC: 0x%08x", debugger.cpu.pc), font = .Monospace) {
			debugger.focused_address = debugger.cpu.pc
		}
		ctx.direction = .Right
		if debugger.last_error != "" {
			if .Clicked in ui_button(ctx, debugger.last_error, border = Ui_Border {
				radius = ctx.theme.border_radius,
				width  = ctx.theme.border_width,
				color  = CLOSE_COLOR,
			}) {
				debugger_set_last_error(debugger, "")
			}
		}
	}

	if ui_section(ctx, "Info Section", .Left, { .Separator, .Resizeable, }) {
		if ui_toggle_section(ctx, "Registers", .Down, { .Separator, }) {
			for i in 0 ..< 32 / 4 {
				ui_section(ctx, fmt.tprintf("Registers_%d", i), .Down, {}) or_continue
				ctx.direction = .Right
				for j in 0 ..< 4 {
					register := Register(i * 4 + j)
					border   := Ui_Border {
						radius = ctx.theme.border_radius,
					}
					if register in debugger.cpu.registers_read {
						border.color = { .384, .675, .933, 1, }
						border.width = ctx.theme.border_width
					}
					if register in debugger.cpu.registers_written {
						border.color = CLOSE_COLOR
						border.width = ctx.theme.border_width
					}
					if .Tooltip in ui_label(ctx, fmt.tprintf("0x%08x", debugger.cpu.registers[register]), border = border, font = .Monospace) {
						if ui_tooltip_popup(ctx, fmt.tprintf("Tooltip_Registers_%d", register)) {
							ui_label(ctx, register_names[register], font = .Monospace)
						}
					}
				}
			}
		}

		if ui_toggle_section(ctx, "Memory", .Down, { .Separator, }) {
			if .Submit in ui_textbox(ctx, &debugger.memory_view.input, "0x0", font = .Monospace) {
				address, _, error, ok := watch_expression_evaluate(
					strings.to_string(debugger.memory_view.input),
					debugger,
					context.temp_allocator,
				)
				if !ok {
					debugger_set_last_error(debugger, error)
				} else {
					debugger.memory_view.address = address
				}
			}

			value := &debugger.cpu.mem[debugger.memory_view.address]
			ui_label(
				ctx,
				fmt.tprintf(
					"0x%08x: 0x%08x",
					debugger.memory_view.address,
					intrinsics.unaligned_load((^u32)(value)),
				),
				font = .Monospace,
			)
		}

		if ui_toggle_section(ctx, "Watch", .Down, { .Separator, }) {
			watch_window_ui(ctx, debugger, &debugger.watch_window)
		}

		if ui_toggle_section(ctx, "Breakpoints", .Down, { .Separator, }) {
			iterator := rb.iterator(&debugger.breakpoints, .Forward)
			for node in rb.iterator_next(&iterator) {
				address :=  node.key
				enabled := &node.value

				ui_section(ctx, fmt.tprintf("Breakpoint_%x", address), .Down, {}) or_continue
				ctx.direction = .Right

				color := enabled^ ? MAXIMIZE_COLOR : CLOSE_COLOR
				if .Clicked in ui_color_button(ctx, ctx.theme.text_height + ctx.theme.text_padding * 2, color) {
					enabled^ ~= true
				}
				if .Clicked in ui_button(ctx, fmt.tprintf("0x%08x", address), font = .Monospace) {
					debugger.focused_address = address
				}
				if .Clicked in ui_color_button(ctx, ctx.theme.text_height + ctx.theme.text_padding * 2, CLOSE_COLOR) {
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
			ui_draw_rect(ctx, ctx.rect, ctx.theme.colors[.Dark], { radius = ctx.theme.border_radius, })
			str := strings.to_string(debugger.output_buffer)
			for len(str) != 0 {
				line := string_wrap(ctx, &str, ctx.max.x - ctx.min.x - ctx.theme.text_padding * 2, .Monospace, ctx.theme.text_height)
				if len(line) == 0 {
					break
				}
				ui_text(ctx, line, ctx.theme.colors[.Text], .Monospace)
			}
		}
	}

	ui_text :: proc(
		ctx:         ^Ui_Context,
		text:        string,
		color:       [4]f32,
		font:        Ui_Font    = .Interface,
		text_height: Maybe(int) = nil,
	) {
		text_height := text_height.? or_else ctx.theme.text_height
		width       := ctx.measure_text(.Interface, ctx.theme.text_height, text, ctx.user_pointer)
		ui_draw_text(ctx, text, ctx.min + [2]int{ ctx.theme.text_padding, ctx.theme.text_padding + ctx.theme.text_height, }, color, .Monospace, text_height)
		ctx.extents.max = la.max(
			ctx.extents.max,
			[2]int {
				ctx.min.x + int(width),
				ctx.min.y + ctx.theme.text_padding * 2 + ctx.theme.text_height,
			},
		)
		ctx.min.y += ctx.theme.text_padding * 2 + ctx.theme.text_height
	}

	ctx.space_width = ctx.measure_text(.Interface, ctx.theme.text_height, " ", ctx.user_pointer)

	ui_instruction :: proc(
		ctx:         ^Ui_Context,
		debugger:    ^Debugger,
		instruction: Instruction,
		address:     u32,
		active:      bool,
	) {
		ui_text :: proc(ctx: ^Ui_Context, text: string, color: [4]f32, text_height: Maybe(int) = nil) {
			text_height := text_height.? or_else ctx.theme.text_height
			width       := int(ctx.measure_text(.Monospace, text_height, text, ctx.user_pointer))
			ui_draw_text(ctx, text, ctx.min + ctx.theme.text_padding + [2]int{ 0, text_height, }, color, .Monospace, text_height)
			ctx.extents.max = la.max(
				ctx.extents.max,
				[2]int {
					ctx.min.x + ctx.theme.text_padding * 2 + width,
					ctx.min.y + ctx.theme.text_padding * 2 + text_height,
				},
			)
			ctx.min.x += width
		}

		id_str := fmt.tprint("Instruction_", address)
		state  := ui_state(ctx, id_str)^
		_       = ui_section(ctx, id_str, .Down, {})
		node   := rb.find(debugger.breakpoints, address)

		background_color: [4]f32
		border: Ui_Border = {
			radius = ctx.theme.border_radius,
		}

		background_rect      := Ui_Rect { ctx.min, ctx.min + state.size, }
		background_rect.max.x = ctx.max.x
		if ui_rect_contains(background_rect, ctx.mouse_position) {
			background_color = ctx.theme.colors[.Button_Clicked]

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
			background_color = ctx.theme.colors[.Button]
		}

		if node != nil {
			if node.value {
				border.color = CLOSE_COLOR
			} else {
				border.color = BREAK_COLOR
			}
			border.width = ctx.theme.border_width
		}

		ui_draw_rect(ctx, background_rect, background_color, border)

		info   := instruction_infos[instruction.mnemonic]
		offset := false

		ui_text(ctx, info.mnemonic, { .384, .675, .933, 1, })
		ctx.min.x += int(ctx.space_width * f32(MAX_MNEMONIC_LEN - len(info.mnemonic) + 1))

		for arg, i in info.args {
			if i != 0 && !offset {
				ui_text(ctx, ", ", ctx.theme.colors[.Text])
			}
			reg: Maybe(Register)
			switch arg {
			case .Imm12, .Imm20, .Uimm5, .Uimm20, .Rel12, .Rel20, .Addr:
				ui_text(ctx, fmt.tprintf("%#x", instruction.imm), CLOSE_COLOR)
			case .Off12:
				ui_text(ctx, fmt.tprintf("%#x", instruction.imm), CLOSE_COLOR)
				ui_text(ctx, "(", ctx.theme.colors[.Text])
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
					ui_text(ctx, register_names[reg], ctx.theme.colors[.Text])
				} else {
					ui_text(ctx, fmt.tprintf("x%d", int(reg)), ctx.theme.colors[.Text])
				}
			}

			if arg != .Off12 && offset {
				ui_text(ctx, ")", ctx.theme.colors[.Text])
				offset = false
			}
		}
	}

	debugger.focused_address -= u32(ctx.mouse_scroll.y * 4)
	instruction_height       := ctx.theme.text_height + ctx.theme.padding + ctx.theme.text_padding * 2
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

debugger_set_last_error :: proc(debugger: ^Debugger, error: string) {
	fmt.eprintln("Error:", error)
	delete(debugger.last_error, context.allocator)
	debugger.last_error = strings.clone(error, context.allocator)
}
