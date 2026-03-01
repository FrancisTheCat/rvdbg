package rvdbg

import "base:intrinsics"

import "core:fmt"
import "core:hash"
import la "core:math/linalg"
import "core:strings"

// In Seconds
HOVER_THRESHOLD :: 0.5

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
	size:         [2]int,
	manual_size:  [2]int,
	scroll:       [2]int,
	position:     [2]int,
	dragged:      bool,
	active:       bool,
	last_shown:   int,
	slider_value: f32,
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
	min_size:   [2]int,
}

Ui_Key :: enum {
	/** Printable keys **/
	Space,
	Apostrophe,
	Comma,
	Minus,
	Period,
	Slash,
	Semicolon,
	Equal,
	Left_Bracket,
	Backslash,
	Right_Bracket,
	Grave_Accent,
	Backspace,

	/* Alphanumeric characters */
	_0,//             = 48 + 0,
	_1,//             = _0 + 1,
	_2,//             = _0 + 2,
	_3,//             = _0 + 3,
	_4,//             = _0 + 4,
	_5,//             = _0 + 5,
	_6,//             = _0 + 6,
	_7,//             = _0 + 7,
	_8,//             = _0 + 8,
	_9,//             = _0 + 9,

	A,//              = 65 + 0,
	B,//              = A  + 1,
	C,//              = A  + 2,
	D,//              = A  + 3,
	E,//              = A  + 4,
	F,//              = A  + 5,
	G,//              = A  + 6,
	H,//              = A  + 7,
	I,//              = A  + 8,
	J,//              = A  + 9,
	K,//              = A  + 10,
	L,//              = A  + 11,
	M,//              = A  + 12,
	N,//              = A  + 13,
	O,//              = A  + 14,
	P,//              = A  + 15,
	Q,//              = A  + 16,
	R,//              = A  + 17,
	S,//              = A  + 18,
	T,//              = A  + 19,
	U,//              = A  + 20,
	V,//              = A  + 21,
	W,//              = A  + 22,
	X,//              = A  + 23,
	Y,//              = A  + 24,
	Z,//              = A  + 25,

	/** Function keys **/

	/* Named non-printable keys */

	Non_Printable_Start = Z + 1,
	Escape,
	Enter,
	Tab,
	Insert,
	Delete,
	Right,
	Left,
	Down,
	Up,
	Page_Up,
	Page_Down,
	Home,
	End,
	Caps_Lock,
	Scroll_Lock,
	Num_Lock,
	Print_Screen,
	Pause,

	/* Function keys */
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	F13,
	F14,
	F15,
	F16,
	F17,
	F18,
	F19,
	F20,
	F21,
	F22,
	F23,
	F24,
	F25,

	/* Keypad numbers */
	KP_0,
	KP_1,
	KP_2,
	KP_3,
	KP_4,
	KP_5,
	KP_6,
	KP_7,
	KP_8,
	KP_9,

	/* Keypad named function keys */
	KP_Decimal,
	KP_Divide,
	KP_Multiply,
	KP_Subtract,
	KP_Add,
	KP_Enter,
	KP_Equal,

	/* Modifier keys */
	Left_Shift,
	Left_Control,
	Left_Alt,
	Left_Super,
	Right_Shift,
	Right_Control,
	Right_Alt,
	Right_Super,
	Menu,
}

ui_key_to_text :: proc(key: Ui_Key) -> string {
	#partial switch key {
	case .Space:
		return " "
	case .Apostrophe:
		return "'"
	case .Comma:
		return ","
	case .Minus:
		return "-"
	case .Period:
		return "."
	case .Slash:
		return "/"
	case .Semicolon:
		return ";"
	case .Equal:
		return "="
	case .Left_Bracket:
		return "["
	case .Backslash:
		return "\\"
	case .Right_Bracket:
		return "]"
	case .Grave_Accent:
		return "`"
	case .Backspace:
		return "<backspace>"

	case ._0:
		return "0"
	case ._1:
		return "1"
	case ._2:
		return "2"
	case ._3:
		return "3"
	case ._4:
		return "4"
	case ._5:
		return "5"
	case ._6:
		return "6"
	case ._7:
		return "7"
	case ._8:
		return "8"
	case ._9:
		return "9"

	case .A:
		return "a"
	case .B:
		return "b"
	case .C:
		return "c"
	case .D:
		return "d"
	case .E:
		return "e"
	case .F:
		return "f"
	case .G:
		return "g"
	case .H:
		return "h"
	case .I:
		return "i"
	case .J:
		return "j"
	case .K:
		return "k"
	case .L:
		return "l"
	case .M:
		return "m"
	case .N:
		return "n"
	case .O:
		return "o"
	case .P:
		return "p"
	case .Q:
		return "q"
	case .R:
		return "r"
	case .S:
		return "s"
	case .T:
		return "t"
	case .U:
		return "u"
	case .V:
		return "v"
	case .W:
		return "w"
	case .X:
		return "x"
	case .Y:
		return "y"
	case .Z:
		return "z"
	}

	return ""
}

Ui_Key_Set :: bit_set[Ui_Key]

Ui_Theme :: struct {
	border: Ui_Border,
}

Ui_Context :: struct {
	// Input, set by the user
	mouse_position:       [2]int,
	mouse_delta:          [2]int,
	mouse_scroll:         [2]int,
	mouse_buttons:        [2]Ui_Button_State,
	keys_pressed:         Ui_Key_Set,
	keys_down:            Ui_Key_Set,
	text_input:           string,
	current_time:         f64,
	delta_time:           f64,

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
	mouse_last_move_time: f64,
	frame_id:             int,
	active_id:            u64,

	theme:                Ui_Theme,

	stack:                [dynamic]Ui_Frame,
	state:                map[u64]^Ui_State,
	z:                    int,
}

Ui_Result :: bit_set[enum {
	Hovered,
	Clicked,
	Down,
	Tooltip,
	Submit,
}]

UI_TEXT_HEIGHT          := 10
UI_BORDER_RADIUS        := 4
UI_PADDING              := 4
UI_TEXT_PADDING         := 6
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

ui_saturate_hash :: proc(h: u64) -> u64 {
	if h == 0 {
		return 1
	} else {
		return h
	}
}

ui_hash_string :: proc(str: string) -> u64 {
	return ui_saturate_hash(hash.fnv64a(transmute([]byte)str))
}

ui_hash_int :: proc(val: $T) -> u64 where intrinsics.type_is_integer(T) {
	return ui_saturate_hash(u64(val))
}

ui_hash_pointer :: proc(val: $T) -> u64 where intrinsics.type_is_pointer(T) {
	return ui_saturate_hash(u64(uintptr(val)))
}

ui_hash :: proc {
	ui_hash_int,
	ui_hash_pointer,
	ui_hash_string,
}

ui_state :: proc(ctx: ^Ui_Context, id_source: $T) -> (state: ^Ui_State) {
	hash           := ui_hash(id_source)
	state           = ctx.state[hash] or_else new(Ui_State) // TODO: should go onto an arena
	ctx.state[hash] = state
	return state
}

ui_insert_rect :: proc(ctx: ^Ui_Context, size: [2]int) -> (rect: Ui_Rect) {
	size := la.max(size, ctx.min_size)

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
		ctx.min.x += size.x + UI_PADDING
	case .Left:
		ctx.max.x -= size.x + UI_PADDING
	}

	ctx.extents.max = la.max(ctx.extents.max, rect.max)
	ctx.extents.min = la.min(ctx.extents.min, rect.min)

	if ctx.direction == .Down || ctx.direction == .Up {
		rect.max.x = max(rect.max.x, ctx.max.x)
	}

	if ctx.direction == .Left || ctx.direction == .Right {
		rect.max.y = max(rect.max.y, ctx.max.y)
	}

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

	if .Clicked in ui_button(ctx, text, out_rect = out_rect) {
		state.active ~= true
	}

	return state.active
}

@(require_results)
ui_button :: proc(
	ctx:      ^Ui_Context,
	text:     string,
	border:   Maybe(Ui_Border) = nil,
	out_rect: ^Ui_Rect         = nil,
) -> (result: Ui_Result) {
	width  := int(ctx.measure_text(.Interface, UI_TEXT_HEIGHT, text, ctx.user_pointer)) + UI_TEXT_PADDING * 2
	height := UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2
	rect   := ui_insert_rect(ctx, { width, height, })
	result  = ui_rect_result(ctx, rect)

	if out_rect != nil {
		out_rect^ = rect
	}

	border := border.? or_else ctx.theme.border
	color  := UI_BUTTON_COLOR
	if rect_contains(rect, ctx.mouse_position) {
		result      |= { .Hovered, }
		border.width = UI_BORDER_WIDTH
		border.color = UI_BORDER_COLOR
		#partial switch ctx.mouse_buttons[0] {
		case .Just_Clicked:
			result |= { .Clicked, }
			color   = UI_BUTTON_CLICKED_COLOR
		case .Clicked:
			color  = UI_BUTTON_CLICKED_COLOR
		}
	}

	ui_draw_rect(ctx, rect, color, border)
	ui_draw_text(ctx, text, {
		rect.min.x + UI_TEXT_PADDING,
		rect.min.y + UI_TEXT_PADDING + UI_TEXT_HEIGHT,
	}, UI_TEXT_COLOR)

	return
}

@(require_results)
ui_textbox :: proc(
	ctx:          ^Ui_Context,
	text:         ^strings.Builder,
	initial_text: string   = "",
	max_length:   int      = -1,
	out_rect:     ^Ui_Rect = nil,
	min_size:     ^[2]int  = nil,
) -> (result: Ui_Result) {
	width := int(ctx.measure_text(.Interface, UI_TEXT_HEIGHT, strings.to_string(text^), ctx.user_pointer)) + UI_TEXT_PADDING * 2
	rect  := ui_insert_rect(ctx, { width, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, })
	result = ui_rect_result(ctx, rect)
	id    := ui_hash(text)

	if id not_in ctx.state {
		if strings.builder_len(text^) == 0 {
			strings.write_string(text, initial_text)
		}
		ctx.state[id] = nil
	}

	if min_size != nil {
		min_size^ = { width, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, }
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

			ctx.active_id = id
		case .Clicked:
			color = UI_BUTTON_CLICKED_COLOR
		}
	}

	if ctx.active_id == id {
		color        = UI_BACKGROUND_COLOR
		border_width = UI_BORDER_WIDTH

		max_length   := max_length < 0 ? max(int) : max_length
		input_length := min(len(ctx.text_input), max_length - strings.builder_len(text^))
		strings.write_string(text, ctx.text_input[:input_length])
		for key in ctx.keys_pressed {
			#partial switch key {
			case .Backspace:
				strings.pop_rune(text)
			case .Escape:
				ctx.active_id = 0
			case .Enter:
				ctx.active_id = 0
				result       |= { .Submit, }
			}
		}
	}

	ui_draw_rect(ctx, rect, color, {
		color  = UI_BORDER_COLOR,
		width  = border_width,
		radius = UI_BORDER_RADIUS,
	})
	ui_draw_text(ctx, strings.to_string(text^), {
		rect.min.x + UI_TEXT_PADDING,
		rect.min.y + UI_TEXT_PADDING + UI_TEXT_HEIGHT,
	}, UI_TEXT_COLOR)

	return
}

ui_label :: proc(
	ctx:      ^Ui_Context,
	text:     string,
	color:    [4]f32           = UI_BUTTON_COLOR,
	border:   Maybe(Ui_Border) = nil,
	out_rect: ^Ui_Rect         = nil,
	min_size: ^[2]int          = nil,
) -> (result: Ui_Result) {
	border := border.? or_else ctx.theme.border
	width  := int(ctx.measure_text(.Interface, UI_TEXT_HEIGHT, text, ctx.user_pointer)) + UI_TEXT_PADDING * 2
	rect   := ui_insert_rect(ctx, { width, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, })
	result  = ui_rect_result(ctx, rect)

	if .Hovered in result && ctx.current_time - ctx.mouse_last_move_time > HOVER_THRESHOLD {
		result |= { .Tooltip, }
	}

	if min_size != nil {
		min_size^ = { width, UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2, }
	}

	if out_rect != nil {
		out_rect^ = rect
	}

	ui_draw_rect(ctx, rect, color, border)
	ui_draw_text(ctx, text, {
		rect.min.x + UI_TEXT_PADDING,
		rect.min.y + UI_TEXT_PADDING + UI_TEXT_HEIGHT,
	}, UI_TEXT_COLOR)

	return
}

ui_color_button :: proc(ctx: ^Ui_Context, size: [2]int, color: [4]f32, border: Maybe(Ui_Border) = nil) -> Ui_Result {
	border := border.? or_else ctx.theme.border

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
	hash  := ui_hash(id)
	state := ui_state(ctx, hash)
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
				min = { frame.rect.max.x - UI_BORDER_WIDTH, frame.rect.min.y, },
				max = { frame.rect.max.x,                   frame.rect.max.y, },
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
ui_tooltip_popup :: proc(ctx: ^Ui_Context, id: string) -> bool {
	state := ui_state(ctx, id)
	if state.last_shown != ctx.frame_id - 1 { // if this wasn't shown last frame move it to the cursor
		state.position = ctx.mouse_position + { 0, 15, }
	}

	rect: Ui_Rect = { min = state.position, }
	rect.max = rect.min + state.size + UI_PADDING * 2

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

	if rect_contains(ctx.extents, ctx.mouse_position) {
		ctx.mouse_position = min(int)
		ctx.mouse_delta    = {}
		ctx.mouse_scroll   = {}
		ctx.mouse_buttons  = {}
		ctx.keys_pressed   = {}
		ctx.keys_down      = {}
		ctx.text_input     = {}
	}

	frame    := pop(&ctx.stack)
	ctx.frame = frame
	ctx.z    -= 1
}

UI_SLIDER_DEFAULT_WIDTH :: 50

_ui_slider :: proc(
	ctx:      ^Ui_Context,
	value:    ^f32,
	min_value: f32 = 0,
	max_value: f32 = 1,
	width:     int              = UI_SLIDER_DEFAULT_WIDTH,
	border:    Maybe(Ui_Border) = nil,
	out_rect: ^Ui_Rect          = nil,
) -> (result: Ui_Result) {
	assert(max_value > min_value)

	border := border.? or_else ctx.theme.border
	height := UI_TEXT_HEIGHT + UI_TEXT_PADDING * 2
	rect   := ui_insert_rect(ctx, { width, height, })
	result  = ui_rect_result(ctx, rect)
	id     := ui_hash(value)

	if out_rect != nil {
		out_rect^ = rect
	}

	if .Clicked in result {
		ctx.active_id = id
	}

	outer_color: [4]f32 = UI_BUTTON_COLOR
	inner_color: [4]f32 = UI_BUTTON_CLICKED_COLOR
	if ctx.active_id == id {
		if ctx.mouse_buttons[0] != .None {
			inner_color = UI_BORDER_COLOR
			step := f32(max_value - min_value) / f32(width)
			if ctx.keys_down & { .Left_Shift, .Right_Shift} != {} {
				step *= 0.1
			}
			value^ = clamp(value^ + step * f32(ctx.mouse_delta.x), min_value, max_value)
		} else {
			ctx.active_id = 0
		}
	}

	ui_draw_rect(ctx, rect, outer_color, border)
	inset         := 2
	rect           = rect_inflate(rect, -inset)
	rect.max.x     = rect.min.x + int(f32(rect.max.x - rect.min.x) * f32(value^) / f32(max_value - min_value))
	border.radius -= inset
	ui_draw_rect(ctx, rect, inner_color, border)

	return
}

ui_slider :: proc(
	ctx:      ^Ui_Context,
	value:    ^$T,
	min_value: T,
	max_value: T,
	width:     int              = UI_SLIDER_DEFAULT_WIDTH,
	border:    Maybe(Ui_Border) = nil,
) -> (result: Ui_Result) {
	id    := ui_hash(value)
	init  := id not_in ctx.state
	state := ui_state(ctx, id)
	if init {
		state.slider_value = f32(value^ - min_value) / f32(max_value - min_value)
	}
	out_rect: Ui_Rect
	result = _ui_slider(ctx, &state.slider_value, border = border, out_rect = &out_rect)
	value^ = T(f32(min_value) + state.slider_value * f32(max_value - min_value))
	ui_draw_text(ctx, fmt.tprint(value^), {
		out_rect.min.x + UI_TEXT_PADDING,
		out_rect.min.y + UI_TEXT_PADDING + UI_TEXT_HEIGHT,
	}, UI_TEXT_COLOR)
	return
}
