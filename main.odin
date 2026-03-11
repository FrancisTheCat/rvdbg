package rvdbg

import "base:intrinsics"
import "base:runtime"

import rb  "core:container/rbtree"
import     "core:fmt"
import la  "core:math/linalg"
import glm "core:math/linalg/glsl"
import     "core:mem"
import     "core:mem/virtual"
import     "core:os"
import     "core:slice"
import     "core:strings"
import     "core:time"
import     "core:terminal/ansi"
import     "core:unicode/utf8"
import     "core:prof/spall"

import     "glodin"
import     "input"
import ttf "odin-ttf"

import "vendor:glfw"

string_replace_tabs :: proc(input: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	line_len: int
	for b in transmute([]byte)input {
		if b == '\t' {
			line_len += 1
			strings.write_byte(&builder, ' ')
			for line_len % 4 != 0 {
				strings.write_byte(&builder, ' ')
				line_len += 1
			}
			continue
		}
		line_len += 1
		if b == '\n' {
			line_len = 0
		}
		strings.write_byte(&builder, b)
	}
	return strings.to_string(builder)
}

debugger_load_file :: proc(debugger: ^Debugger, path: string) -> (ok: bool) {
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil {
		if debugger.file_path != path {
			delete(debugger.file_path)
			debugger.file_path = strings.clone(path)
		}

		debugger_reset(debugger)
		debugger_load_program(debugger, string(source))
	} else {
		delete(debugger.last_error)
		debugger.last_error = fmt.aprintf("Failed to open file: %s", path)
	}

	return err == nil
}

debugger_load_program :: proc(debugger: ^Debugger, source: string) {
	sections, relocations, labels, errors := parse_assembly(source, context.temp_allocator, context.temp_allocator)

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

	if error {
		return
	}

	linker_errors := resolve_relocations(sections, labels, relocations, context.temp_allocator)

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

	start_label, start_label_found := labels["_start"]
	if !start_label_found {
		fmt.println("No `_start` label found, starting at PC = 0")
	}

	debugger.cpu.pc = u32(sections[start_label.section].offset + start_label.offset)
	debugger.state  = .Debugger_Paused

	cpu_load_sections(&debugger.cpu, sections)
}

ENABLE_SPALL :: #config(ENABLE_SPALL, false)

when ENABLE_SPALL {
	spall_ctx:    spall.Context
	spall_buffer: spall.Buffer

	@(instrumentation_enter)
	spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}
}


main :: proc() {
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

	when ENABLE_SPALL {
		spall_ctx = spall.context_create("trace.spall")
		defer spall.context_destroy(&spall_ctx)

		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing)
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
	}

	mem, err := virtual.reserve_and_commit(1 << 32 + 3)
	assert(err == nil)

	debugger: Debugger
	cpu_init(&debugger.cpu, mem, strings.to_writer(&debugger.output_buffer))

	debugger.focused_address = debugger.cpu.pc
	debugger.register_names  = true
	debugger.subpixel        = true
	debugger.state           = .Debugger_Paused
	debugger.font_quality    = 2

	rb.init(&debugger.breakpoints)

	defer {
		strings.builder_destroy(&debugger.output_buffer)
		strings.builder_destroy(&debugger.memory_view.input)
		watch_window_destroy(&debugger.watch_window)
		rb.destroy(&debugger.breakpoints)
		delete(debugger.last_error)
		delete(debugger.file_path)
	}

	ok := glfw.Init();
	assert(bool(ok), "glfw.Init")
	defer glfw.Terminate()

	window: struct {
		size:         [2]int, // actual framebuffer size
		virtual_size: [2]int, // "virtual" window size, before scaling
		handle:       glfw.WindowHandle,
	} = {
		virtual_size = { 900, 600, },
	}

	window.handle = glfw.CreateWindow(i32(window.virtual_size.x), i32(window.virtual_size.y), "", nil, nil)
	defer glfw.DestroyWindow(window.handle)

	{
		w, h       := glfw.GetFramebufferSize(window.handle)
		window.size = { int(w), int(h), }
	}

	input.init(window.handle)

	glodin.init_glfw(window.handle)
	defer glodin.uninit()

	// glfw.SwapInterval(0)

	glodin.window_size_callback(window.size.x, window.size.y)

	program := glodin.create_program_source(#load("vertex.glsl"), #load("fragment.glsl")) or_else panic("Failed to compile program")
	defer glodin.destroy(program)

	fonts: [Ui_Font]Font
	defer for font in fonts {
		delete(font.data)
	}
	for &font, font_id in fonts {
		font.data = os.read_entire_file(FONT_PATHS[font_id], context.allocator) or_else panic("Failed to open font file")
		font.font = ttf.load(font.data) or_else panic("Failed to load font")
	}

	ui_ctx: Ui_Context
	ui_context_init(
		&ui_ctx,
		proc(font: Ui_Font, font_size: int, text: string, user_pointer: rawptr) -> f32 {
			return measure_text((^[Ui_Font]Font)(user_pointer)[font], text)
		},
		&fonts,
	)
	defer ui_context_destroy(&ui_ctx)

	glodin.clear_color({}, ui_ctx.theme.colors[.Background])

	Vertex_2D :: struct {
		position: glm.vec2,
	}

	quad_vertex_buffer: []Vertex_2D = {
		{ position = { 0, 0, }, },
		{ position = { 0, 1, }, },
		{ position = { 1, 0, }, },

		{ position = { 1, 1, }, },
		{ position = { 0, 1, }, },
		{ position = { 1, 0, }, },
	}

	quad := glodin.create_mesh(quad_vertex_buffer[:])
	defer glodin.destroy_mesh(quad)

	instance_buffer := make([dynamic]Instance_Data, context.allocator)
	defer delete(instance_buffer)

	glodin.disable(.Cull_Face)
	glodin.set_stencil_op(.Keep, .Keep, .Incr_Wrap, .Front)
	glodin.set_stencil_op(.Keep, .Keep, .Zero, .Back)
	glodin.set_min_sample_shading(1)

	font_draw_ctx: Font_Draw_Context
	font_draw_context_init(&font_draw_ctx)
	defer font_draw_context_destroy(font_draw_ctx)

	last_print_time    := time.now()
	frames_since_print := 0

	prev_time: f64
	prev_mouse_position: [2]int

	start_time := time.now()

	for !glfw.WindowShouldClose(window.handle) && !debugger.should_close {
		frames_since_print += 1
		if time.since(last_print_time) > time.Second {
			glfw.SetWindowTitle(window.handle, fmt.ctprintf("%v", frames_since_print))
			frames_since_print = 0
			last_print_time    = time.now()
		}

		@(static)
		prev_text_height := -1
		if ui_ctx.theme.text_height != prev_text_height {
			for &font in fonts {
				font.font_height = f32(ui_ctx.theme.text_height)
				font.scale       = ttf.font_height_to_scale(font.font, font.font_height)
			}
			prev_text_height = ui_ctx.theme.text_height
		}

		{
			fx, fy     := glfw.GetFramebufferSize(window.handle)
			window.size = { int(fx), int(fy), }

			ww, wh             := glfw.GetWindowSize(window.handle)
			window.virtual_size = { int(ww), int(wh), }
		}

		scale := la.array_cast(window.size, f32) / la.array_cast(window.virtual_size, f32)

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

		ui_begin_frame(
			&ui_ctx,
			window.virtual_size.x,
			window.virtual_size.y,
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

		clear(&instance_buffer)

		for cmd in ui_get_draw_commands(ui_ctx) {
			switch cmd in cmd {
			case Ui_Cmd_Text:
				draw_string(
					&font_draw_ctx,
					&instance_buffer,
					&fonts[cmd.font],
					cmd.text,
					{ f32(cmd.position.x), f32(cmd.position.y), },
					fonts[cmd.font].scale,
					cmd.color,
				)
			case Ui_Cmd_Rect:
				rect := cmd.rect
				if rect.min.x > rect.max.x || rect.min.y > rect.max.y {
					break
				}

				append(&instance_buffer, Instance_Data {
					rect                = [4]f32{ f32(rect.min.x), f32(rect.min.y), f32(rect.max.x), f32(rect.max.y), },
					color               = cmd.color,
					border_color        = cmd.border.color,
					border_width_radius = [2]f32{ f32(cmd.border.width), f32(cmd.border.radius), } * scale.y, // not correct when we are scaled non-uniformly, but do we really care?
				})

				min := la.array_cast(rect.min, f32)
				max := la.array_cast(rect.max, f32)
				draw_font_clear_quad(&font_draw_ctx, min, max)
			}
		}

		font_samples := 1 << uint(debugger.font_quality)
		font_draw_context_draw(&font_draw_ctx, window.size, scale, font_samples, debugger.subpixel)

		{
			glodin.enable(.Blend)
			defer glodin.disable(.Blend)

			glodin.clear_color({}, ui_ctx.theme.colors[.Background])

			mesh := glodin.create_instanced_mesh(quad, instance_buffer[:])
			defer glodin.destroy(mesh)

			glodin.set_uniforms(program, {
				{ "u_font_stencil",  font_draw_ctx.stencil_texture,   },
				{ "u_resolution",    la.array_cast(window.size, f32), },
				{ "u_font_samples",  u32(font_samples),               },
				{ "u_font_subpixel", debugger.subpixel,               },
				{ "u_scale" ,        scale,                           },
			})

			glodin.draw({}, program, mesh)
		}

		glfw.SwapBuffers(window.handle)

		input.poll()
		glfw.PollEvents()

		free_all(context.temp_allocator)
	}
}

Instance_Data :: struct {
	rect, tex_rect:      glm.vec4,
	color, border_color: glm.vec4,
	border_width_radius: glm.vec2,
	has_font:            i32,
}

Debugger :: struct {
	cpu:             CPU,
	state:           CPU_State,
	output_buffer:   strings.Builder,
	breakpoints:     rb.Tree(u32, bool),
	focused_address: u32,
	register_names:  bool,
	memory_view:     struct {
		input:   strings.Builder,
		address: u32,
	},
	watch_window:    Watch_Window,
	last_error:      string,
	file_path:       string,
	should_close:    bool,
	subpixel:        bool,
	font_quality:    int,
	glyph_count:     int,
}

debugger_ui :: proc(ctx: ^Ui_Context, debugger: ^Debugger) {
	BREAK_COLOR    :: [4]f32{ .5,   .3,   .3,   1, }
	CLOSE_COLOR    :: [4]f32{ .878, .42,  .455, 1, }
	PAUSE_COLOR    :: [4]f32{ .384, .675, .933, 1, }
	MAXIMIZE_COLOR :: [4]f32{ .596, .765, .475, 1, }
	MINIMIZE_COLOR :: [4]f32{ .898, .753, .478, 1, }

	step := .F10 in ctx.keys_pressed
	if .F8 in ctx.keys_pressed {
		debugger.state = .Debugger_Paused
	}
	if .F5 in ctx.keys_pressed {
		debugger.state = .Running
	}

	warp_focus := step

	if ui_section(ctx, "Menu Bar", .Down, { .Separator, }) {
		ctx.direction = .Right
		if ui_popup_toggle(ctx, "File") {
			if .Clicked in ui_button(ctx, "Open") {
				path, ok := dialog_file_open()
				if ok && debugger_load_file(debugger, path) {
					warp_focus = true
				}
				ui_popup_close(ctx)
			}
			if .Clicked in ui_button(ctx, "Open Directory") {
				file, ok := dialog_file_open(true)
				if ok {
					fmt.println(file)
				}
				ui_popup_close(ctx)
			}
			if .Clicked in ui_button(ctx, "Save") {
				file, ok := dialog_file_save()
				if ok {
					fmt.println(file)
				}
				ui_popup_close(ctx)
			}
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

			named_slider :: proc(ctx: ^Ui_Context, name: string, value: ^int, min_value, max_value: int) {
				if ui_section(ctx, name, .Down, {}) {
					ctx.direction = .Right

					min_size: [2]int
					ui_label(ctx, name, min_size = &min_size)
					max_width = max(max_width, min_size.x)
					ctx.min_size.x = 0
					ui_slider(ctx, value, min_value, max_value)
				}
			}

			ctx.min_size.x = last_max_width
			named_slider(ctx, "Padding",       &ctx.theme.padding,       0, 20)
			named_slider(ctx, "Text Padding",  &ctx.theme.text_padding,  0, 20)
			named_slider(ctx, "Border Width",  &ctx.theme.border_width,  1, 10)
			named_slider(ctx, "Border Radius", &ctx.theme.border_radius, 0, 20)
			named_slider(ctx, "Text Height",   &ctx.theme.text_height,   0, 20)
			named_slider(ctx, "Font Quality",  &debugger.font_quality,   1,  3)

			if .Clicked in ui_button(ctx, "Reset Theme") {
				ctx.theme = UI_DEFAULT_THEME
			}
			debugger.register_names ~= .Clicked in ui_button(ctx, "Register Names")
			debugger.subpixel       ~= .Clicked in ui_button(ctx, "Subpixel Rendering")
		}

		if ui_popup_toggle(ctx, "Run") {
			if .Clicked in ui_button(ctx, "Run") {
				debugger.state = .Running
				ui_popup_close(ctx)
			}
			if .Clicked in ui_button(ctx, "Step") {
				step = true
			}
			if .Clicked in ui_button(ctx, "Pause") {
				debugger.state = .Debugger_Paused
				ui_popup_close(ctx)
			}
			if .Clicked in ui_button(ctx, "Reset") {
				if debugger_load_file(debugger, debugger.file_path) {
					warp_focus = true
				}
				ui_popup_close(ctx)
			}
		}

		if ui_popup_toggle(ctx, "Help") {
			ui_label(ctx, "Skill issue")
		}

		ctx.direction = .Left
		size := ctx.theme.text_height + ctx.theme.text_padding * 2
		if .Clicked in ui_color_button(ctx, size, CLOSE_COLOR) {
			debugger.should_close = true
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

	if debugger.state == .Running {
		start_running := time.now()
		for debugger.state == .Running && time.since(start_running) < time.Millisecond {
			for i := 0; i < 1000 && debugger.state == .Running; i += 1 {
				debugger_execute_instruction(debugger)
			}
		}
	}

	if step {
		debugger_execute_instruction(debugger)
		if debugger.state == .Running {
			debugger.state = .Debugger_Paused
		}
	}

	if ui_section(ctx, "Footer", .Up, { .Separator, }) {
		ctx.direction = .Left

		@(rodata, static)
		debugger_status_colors := [CPU_State][4]f32 {
			.Running             = MAXIMIZE_COLOR,
			.Ebreak              = MINIMIZE_COLOR,
			.Invalid_Instruction = CLOSE_COLOR,
			.Trivial_Loop        = CLOSE_COLOR,
			.Debugger_Breakpoint = PAUSE_COLOR,
			.Debugger_Paused     = PAUSE_COLOR,
		}

		ui_label(
			ctx,
			fmt.tprintf("Status: %v", debugger.state),
			font   = .Monospace,
			border = Ui_Border {
				radius = ctx.theme.border_radius,
				width  = ctx.theme.border_width,
				color  = debugger_status_colors[debugger.state],
			},
		)

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

		if debugger.file_path != {} {
			ui_label(ctx, debugger.file_path)
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
						border.color = PAUSE_COLOR
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
		width       := ctx.measure_text(font, ctx.theme.text_height, text, ctx.user_pointer)
		ui_draw_text(ctx, text, ctx.min + [2]int{ ctx.theme.text_padding, ctx.theme.text_padding + ctx.theme.text_height, }, color, font, text_height)
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
		instruction: u32,
		address:     u32,
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

		instruction, ok := disassemble_instruction(instruction)
		if !ok {
			ui_text(ctx, "---", CLOSE_COLOR)
			return
		}

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
		} else if address == debugger.cpu.pc {
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

	debugger.focused_address = cast(u32)clamp(int(debugger.focused_address) - ctx.mouse_scroll.y * 4, 0, 1 << 32 - 1)
	instruction_height      := ctx.theme.text_height + ctx.theme.padding + ctx.theme.text_padding * 2
	instructions            := slice.reinterpret([]u32, debugger.cpu.mem[debugger.focused_address:])
	visible_instructions    := clamp((ctx.max.y - ctx.min.y) / instruction_height, 0, len(instructions) - 1)
	instructions             = instructions[:visible_instructions]

	pc_visible: bool
	for inst, i in instructions {
		address := debugger.focused_address + u32(i) * 4
		ui_instruction(
			ctx,
			debugger,
			inst,
			address,
		)

		pc_visible ||= address == debugger.cpu.pc
	}

	if !pc_visible && warp_focus {
		debugger.focused_address = debugger.cpu.pc
	}
}

debugger_set_last_error :: proc(debugger: ^Debugger, error: string) {
	fmt.eprintln("Error:", error)
	delete(debugger.last_error, context.allocator)
	debugger.last_error = strings.clone(error, context.allocator)
}

debugger_reset :: proc(debugger: ^Debugger) {
	virtual.release(raw_data(debugger.cpu.mem), len(debugger.cpu.mem))
	err: mem.Allocator_Error
	debugger.cpu.mem, err = virtual.reserve_and_commit(len(debugger.cpu.mem))
	assert(err == nil)

	cpu_init(&debugger.cpu, debugger.cpu.mem, strings.to_writer(&debugger.output_buffer))
	strings.builder_reset(&debugger.output_buffer)
}
