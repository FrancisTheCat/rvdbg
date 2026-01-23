package rvdbg

import "base:intrinsics"

import "core:hash"
import la "core:math/linalg"

Ui_Rect :: struct {
	min, max: [2]int,
}

Ui_Cmd_Text :: struct {
	position:  [2]int,
	text:      string,
	color:     [4]f32,
	z:         int,
	font:      Ui_Font,
	font_size: int,
}

Ui_Cmd_Rect :: struct {
	rect:   Ui_Rect,
	color:  [4]f32,
	border: Ui_Border,
	z:      int,
}

Ui_Border :: struct {
	color:  [4]f32,
	width:  int,
	radius: int,
}

Ui_Cmd :: union {
	Ui_Cmd_Text,
	Ui_Cmd_Rect,
}

Ui_Font :: enum {
	Interface,
	Monospace,
}

Ui_Button_State :: enum {
	None,
	Just_Clicked,
	Clicked,
}

Ui_State :: struct {
	size:        [2]int,
	manual_size: [2]int,
	scroll:      [2]int,
	dragged:     bool,
	active:      bool,
}

Ui_Direction :: enum {
	Down,
	Right,
	Up,
	Left,
}

Ui_Frame :: struct {
	using rect: Ui_Rect,
	extents:    Ui_Rect,
	direction:  Ui_Direction,
}

Ui_Context :: struct {
	// Input, set by the user
	mouse_position:       [2]int,
	mouse_delta:          [2]int,
	mouse_buttons:        [2]Ui_Button_State,
	mouse_last_move_time: f32, // Seconds since mouse last moved, should be zero when mouse_delta is non-zero

	// Output, read by the user
	should_close:         bool,
	cmds:                 [dynamic]Ui_Cmd,

	// Internal
	using frame:          Ui_Frame,

	popups:               [dynamic]Ui_Cmd,
	measure_text:         proc(
		font:             Ui_Font,
		font_size:        int,
		text:             string,
		user_pointer:     rawptr,
	) -> f32,
	user_pointer:         rawptr,
	space_width:          f32,

	stack:                [dynamic]Ui_Frame,
	state:                map[u64]^Ui_State,
	z:                    int,
}

Ui_Result :: bit_set[enum {
	Hovered,
	Clicked,
	Down,
}]

UI_TEXT_HEIGHT          :: 10
UI_PADDING              := 6
UI_TEXT_PADDING         := 8
UI_BORDER_RADIUS        := 2
UI_BORDER_WIDTH         := 1

// UI_BACKGROUND_COLOR     :: [4]f32 { .118, .129, .157, 1, }
// UI_BUTTON_COLOR         :: [4]f32 { .196, .212, .239, 1, }
// UI_BUTTON_CLICKED_COLOR :: [4]f32 { .118, .129, .157, 1, }
// UI_TEXT_COLOR           :: [4]f32 { .671, .698, .749, 1, }
// UI_BORDER_COLOR         :: [4]f32 { .314, .329, .357, 1, }

UI_BACKGROUND_COLOR     :: [4]f32 { 0.1,  0.1,  0.1,  1, }
UI_DARK_COLOR           :: [4]f32 { 0.15, 0.15, 0.15, 1, }
UI_BUTTON_COLOR         :: [4]f32 { 0.2,  0.2,  0.2,  1, }
UI_BUTTON_CLICKED_COLOR :: [4]f32 { 0.25, 0.25, 0.25, 1, }
UI_TEXT_COLOR           :: [4]f32 { 0.7,  0.7,  0.7,  1, }
UI_BORDER_COLOR         :: [4]f32 { 0.4,  0.4,  0.4,  1, }

rect_contains :: proc(rect: Ui_Rect, point: [2]int) -> bool {
	if point.x < rect.min.x || point.x > rect.max.x {
		return false
	}
	if point.y < rect.min.y || point.y > rect.max.y {
		return false
	}
	return true
}

rect_inflate :: proc(rect: Ui_Rect, delta: [2]int) -> Ui_Rect {
	return {
		min = rect.min - delta,
		max = rect.max + delta,
	}
}

rect_union :: proc(a, b: Ui_Rect) -> Ui_Rect {
	return {
		min = la.min(a.min, b.min),
		max = la.max(a.max, b.max),
	}
}

ui_hash_string :: proc(str: string) -> u64 {
	return hash.fnv64a(transmute([]byte)str)
}

ui_hash_int :: proc(val: $T) -> u64 where intrinsics.type_is_integer(T) {
	return u64(val)
}

ui_hash :: proc {
	ui_hash_int,
	ui_hash_string,
}

ui_state :: proc(ctx: ^Ui_Context, id_source: $T) -> (state: ^Ui_State) {
	hash           := ui_hash(id_source)
	state           = ctx.state[hash] or_else new(Ui_State)
	ctx.state[hash] = state
	return state
}

ui_insert_rect :: proc(ctx: ^Ui_Context, size: [2]int) -> (rect: Ui_Rect) {
	switch ctx.direction {
	case .Down, .Right:
		rect = {
			min = ctx.rect.min,
			max = { ctx.rect.min.x + size.x, ctx.rect.min.y + size.y, },
		}
	case .Left:
		rect = {
			min = { ctx.rect.max.x - size.x, ctx.rect.min.y           },
			max = { ctx.rect.max.x,          ctx.rect.min.y + size.y, },
		}
	case .Up:
		rect = {
			min = { ctx.rect.max.x - size.x, ctx.rect.max.y - size.y, },
			max = ctx.rect.max,
		}
	}
	
	switch ctx.direction {
	case .Down:
		ctx.min.y += size.y + UI_PADDING
	case .Up:
		ctx.max.y -= size.y + UI_PADDING
	case .Right:
		ctx.min.x += size.x  + UI_PADDING
	case .Left:
		ctx.max.x -= size.x  + UI_PADDING
	}

	ctx.extents.max = la.max(ctx.extents.max, rect.max)
	ctx.extents.min = la.min(ctx.extents.min, rect.min)
	return
}

ui_rect_result :: proc(ctx: ^Ui_Context, rect: Ui_Rect) -> (result: Ui_Result) {
	if rect_contains(rect, ctx.mouse_position) {
		result |= { .Hovered, }
		#partial switch ctx.mouse_buttons[0]{
		case .Just_Clicked:
			result |= { .Clicked, }
		case .Clicked:
			result |= { .Down, }
		}
	}
	return
}

@(require_results)
ui_toggle :: proc(ctx: ^Ui_Context, text: string, out_rect: ^Ui_Rect = nil) -> bool {
	state := ui_state(ctx, text)

	if .Clicked in ui_button(ctx, text, out_rect) {
		state.active ~= true
	}

	return state.active
}

@(require_results)
ui_button :: proc(ctx: ^Ui_Context, text: string, out_rect: ^Ui_Rect = nil) -> (result: Ui_Result) {
	width  := int(ctx.measure_text(.Interface, UI_TEXT_HEIGHT, text, ctx.user_pointer)) + UI_TEXT_PADDING * 2
	height := UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2
	rect   := ui_insert_rect(ctx, { width, height, })
	result  = ui_rect_result(ctx, rect)

	if ctx.direction == .Down {
		rect.max.x = ctx.max.x
	}

	if out_rect != nil {
		out_rect^ = rect
	}

	border_width := 0
	color        := UI_BUTTON_COLOR
	if rect_contains(rect, ctx.mouse_position) {
		result      |= { .Hovered, }
		border_width = UI_BORDER_WIDTH
		#partial switch ctx.mouse_buttons[0] {
		case .Just_Clicked:
			result |= { .Clicked, }
			color   = UI_BUTTON_CLICKED_COLOR
		case .Clicked:
			color  = UI_BUTTON_CLICKED_COLOR
		}
	}

	ui_draw_rect(ctx, rect, color, {
		color  = UI_BORDER_COLOR,
		width  = border_width,
		radius = UI_BORDER_RADIUS,
	})
	ui_draw_text(ctx, text, {
		rect.min.x + UI_TEXT_PADDING,
		rect.min.y + UI_TEXT_PADDING + UI_TEXT_HEIGHT,
	}, UI_TEXT_COLOR)

	return
}

ui_label :: proc(
	ctx:      ^Ui_Context,
	text:     string,
	color:    [4]f32   = UI_BUTTON_COLOR,
	out_rect: ^Ui_Rect = nil,
) -> (result: Ui_Result) {
	width  := int(ctx.measure_text(.Interface, UI_TEXT_HEIGHT, text, ctx.user_pointer)) + UI_TEXT_PADDING * 2
	height := UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2
	rect   := ui_insert_rect(ctx, { width, height, })
	result  = ui_rect_result(ctx, rect)

	if out_rect != nil {
		out_rect^ = rect
	}

	ui_draw_rect(ctx, rect, color, {
		color  = UI_BORDER_COLOR,
		radius = UI_BORDER_RADIUS,
	})
	ui_draw_text(ctx, text, {
		rect.min.x + UI_TEXT_PADDING,
		rect.min.y + UI_TEXT_PADDING + UI_TEXT_HEIGHT,
	}, UI_TEXT_COLOR)

	return
}

ui_color_button :: proc(ctx: ^Ui_Context, size: [2]int, color: [4]f32, border: Ui_Border = {}) -> Ui_Result {
	rect := ui_insert_rect(ctx, size)
	ui_draw_rect(ctx, rect, color, border)
	return ui_rect_result(ctx, rect)
}

ui_draw_rect :: proc(ctx: ^Ui_Context, rect: Ui_Rect, color: [4]f32, border: Ui_Border = {}) {
	append(&ctx.cmds, Ui_Cmd_Rect {
		rect   = rect,
		color  = color,
		border = border,
		z      = ctx.z,
	})
}

ui_draw_text :: proc(
	ctx:       ^Ui_Context,
	text:      string,
	position:  [2]int,
	color:     [4]f32,
	font:      Ui_Font = .Interface,
	font_size: int     = UI_TEXT_HEIGHT,
) {
	append(&ctx.cmds, Ui_Cmd_Text {
		position = position,
		text     = text,
		color    = color,
		z        = ctx.z,
		font      = font,
		font_size = font_size,
	})
}

Ui_Section_Flag :: enum {
	Separator,
	Resizeable,
	Toggleable,
}
Ui_Section_Flags :: bit_set[Ui_Section_Flag]

@(require_results, deferred_in_out = ui_section_end)
ui_section :: proc(ctx: ^Ui_Context, id: string, direction: Ui_Direction, flags: Ui_Section_Flags) -> bool {
	return _ui_section(ctx, id, direction, flags)
}

@(require_results)
_ui_section :: proc(ctx: ^Ui_Context, id: string, direction: Ui_Direction, flags: Ui_Section_Flags) -> bool {
	state := ui_state(ctx, id)
	frame := ctx.frame

	size := state.size
	if .Resizeable in flags {
		assert(.Separator in flags, "resizable sections must have a separator")
		// this is fine, we only use the manual_size for the adjustable coordinate anyway
		size = la.max(size, state.manual_size)
	}
	
	separator_rect: Ui_Rect
	switch direction {
	case .Down:
		frame.rect.min.y += size.y + UI_PADDING
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.min.x, frame.rect.min.y,                   },
				max = { frame.rect.max.x, frame.rect.min.y + UI_BORDER_WIDTH, },
			} 
			frame.rect.min.y += UI_PADDING + UI_BORDER_WIDTH
		}
		ctx.frame.rect.max.y = ctx.frame.rect.min.y + size.y
	case .Up:
		frame.rect.max.y -= size.y + UI_PADDING
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.min.x, frame.rect.max.y - UI_BORDER_WIDTH, },
				max = { frame.rect.max.x, frame.rect.max.y,                   },
			}
			frame.rect.max.y -= UI_PADDING + UI_BORDER_WIDTH
		}
		ctx.frame.rect.min.y = ctx.frame.rect.max.y - size.y
	case .Right:
		frame.rect.min.x += size.x + UI_PADDING
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.min.x,                   frame.rect.min.y, },
				max = { frame.rect.min.x + UI_BORDER_WIDTH, frame.rect.max.y, },
			}
			frame.rect.min.x += UI_PADDING + UI_BORDER_WIDTH
		}
		ctx.frame.rect.max.x = ctx.frame.rect.min.x + size.x
	case .Left:
		frame.rect.max.x -= size.x + UI_PADDING
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.max.x,                   frame.rect.min.y, },
				max = { frame.rect.max.x + UI_BORDER_WIDTH, frame.rect.max.y, },
			}
			frame.rect.max.x -= UI_PADDING + UI_BORDER_WIDTH
		}
		ctx.frame.rect.min.x = ctx.frame.rect.max.x - size.x
	}

	append(&ctx.stack, frame)
	ctx.extents = { ctx.frame.min, ctx.frame.min, }

	separator_color := UI_BORDER_COLOR
	if .Resizeable in flags {
		if state.dragged {
			separator_color = UI_TEXT_COLOR
			switch direction {
			case .Left:
				state.manual_size.x -= ctx.mouse_delta.x
			case .Right:
				state.manual_size.x += ctx.mouse_delta.x
			case .Up:
				state.manual_size.y -= ctx.mouse_delta.y
			case .Down:
				state.manual_size.y += ctx.mouse_delta.y
			}
			if ctx.mouse_buttons[0] == .None {
				state.dragged     = false
				state.manual_size = la.max(state.manual_size, state.size)
			}
		} else {
			if state.manual_size == 0 {
				state.manual_size = state.size
			}
			
			if rect_contains(rect_inflate(separator_rect, 4), ctx.mouse_position) {
				separator_color = { 0.55, 0.55, 0.55, 1, }
				if ctx.mouse_buttons[0] == .Just_Clicked {
					state.dragged     = true
					state.manual_size = la.max(state.manual_size, state.size)
				}
			}
		}
	}

	ui_draw_rect(ctx, separator_rect, separator_color)

	return true
}

ui_section_end :: proc(ctx: ^Ui_Context, id: string, direction: Ui_Direction, flags: Ui_Section_Flags, show: bool) {
	if !show {
		return
	}

	state     := ui_state(ctx, id)
	state.size = ctx.extents.max - ctx.extents.min

	extents  := ctx.extents
	frame    := pop(&ctx.stack)
	ctx.frame = frame
	ctx.extents = {
		la.min(ctx.extents.min, extents.min),
		la.max(ctx.extents.max, extents.max),
	}
}

@(require_results, deferred_in_out = ui_popup_end)
ui_popup_toggle :: proc(ctx: ^Ui_Context, text: string) -> bool {
	state := ui_state(ctx, text)
	button_rect:    Ui_Rect
	button_clicked: bool
	if .Clicked in ui_button(ctx, text, out_rect = &button_rect) {
		state.active  ~= true
		button_clicked = true
	}

	if !state.active {
		return false
	}

	rect: Ui_Rect = {
		min = { button_rect.min.x, button_rect.max.y, },
	}
	rect.max = rect.min + state.size + UI_PADDING * 2
	if !button_clicked && ctx.mouse_buttons[0] == .Just_Clicked && !rect_contains(rect, ctx.mouse_position) {
		// the user just clicked somewhere else, so we should close the popup
		// note that this does not work for nested popups and will need to be handled differently
		state.active = false
		return false
	}

	append(&ctx.stack, ctx.frame)

	ctx.z += 1
	ui_draw_rect(ctx, rect, { 0.15, 0.15, 0.15, 1, }, {
		radius = UI_BORDER_RADIUS,
		width  = UI_BORDER_WIDTH,
		color  = { 0.2, 0.2, 0.2, 1, },
	})
	rect.min      += UI_PADDING
	rect.max      -= UI_PADDING
	ctx.frame.rect = rect
	ctx.extents    = { rect.min, rect.min, }
	ctx.direction  = .Down

	return true
}

ui_popup_end :: proc(ctx: ^Ui_Context, text: string, show: bool) {
	if !show {
		return
	}

	state     := ui_state(ctx, text)
	state.size = ctx.extents.max - ctx.extents.min

	frame    := pop(&ctx.stack)
	ctx.frame = frame
	ctx.z    -= 1
}
