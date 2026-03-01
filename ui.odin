package rvdbg

import "base:intrinsics"

import "core:fmt"
import "core:hash"
import la "core:math/linalg"
import "core:strings"

UI_HOVER_THRESHOLD      :: 0.5 // In Seconds
UI_RESIZE_MARGIN        :: 4
UI_SLIDER_DEFAULT_WIDTH :: 50

Ui_Rect :: struct {
	min, max: [2]int,
}

Ui_Cmd_Text :: struct {
	position:    [2]int,
	text:        string,
	color:       [4]f32,
	z:           int,
	font:        Ui_Font,
	text_height: int,
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
	Interface = 1,
	Monospace = 2,
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
	_0,
	_1,
	_2,
	_3,
	_4,
	_5,
	_6,
	_7,
	_8,
	_9,

	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,

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
		return "Backspace"

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

UI_DEFAULT_THEME :: Ui_Theme {
	text_padding  = 6,
	border_radius = 4,
	border_width  = 1,
	text_height   = 10,
	padding       = 4,
	colors        = {
		.Background     = [4]f32 { 0.1,  0.1,  0.1,  1, },
		.Dark           = [4]f32 { 0.15, 0.15, 0.15, 1, },
		.Label          = [4]f32 { 0.2,  0.2,  0.2,  1, },
		.Button         = [4]f32 { 0.2,  0.2,  0.2,  1, },
		.Button_Clicked = [4]f32 { 0.25, 0.25, 0.25, 1, },
		.Text           = [4]f32 { 0.7,  0.7,  0.7,  1, },
		.Border         = [4]f32 { 0.4,  0.4,  0.4,  1, },
	},
}

Ui_Widget_Theme :: struct {
	border: Ui_Border,
	color:  [4]f32,
}

Ui_Theme :: struct {
	border_radius: int,
	border_width:  int,
	text_padding:  int,
	text_height:   int,
	padding:       int,

	colors:        [enum{
		Background,
		Dark,
		Label,
		Button,
		Button_Clicked,
		Text,
		Border,
	}][4]f32,
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
	widget_height:        int,

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

ui_rect_contains :: proc(rect: Ui_Rect, point: [2]int) -> bool {
	if point.x < rect.min.x || point.x > rect.max.x {
		return false
	}
	if point.y < rect.min.y || point.y > rect.max.y {
		return false
	}
	return true
}

ui_rect_inflate :: proc(rect: Ui_Rect, delta: [2]int) -> Ui_Rect {
	return {
		min = rect.min - delta,
		max = rect.max + delta,
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
		ctx.min.y += size.y + ctx.theme.padding
	case .Up:
		ctx.max.y -= size.y + ctx.theme.padding
	case .Right:
		ctx.min.x += size.x + ctx.theme.padding
	case .Left:
		ctx.max.x -= size.x + ctx.theme.padding
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
	if ui_rect_contains(rect, ctx.mouse_position) {
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
	font:     Ui_Font          = .Interface,
	out_rect: ^Ui_Rect         = nil,
) -> (result: Ui_Result) {
	width  := int(ctx.measure_text(font, ctx.theme.text_height, text, ctx.user_pointer)) + ctx.theme.text_padding * 2
	height := ctx.widget_height
	rect   := ui_insert_rect(ctx, { width, height, })
	result  = ui_rect_result(ctx, rect)

	if out_rect != nil {
		out_rect^ = rect
	}

	border := border.? or_else { radius = ctx.theme.border_radius, }
	color  := ctx.theme.colors[.Button]

	if .Hovered in result {
		border.width = ctx.theme.border_width
		border.color = ctx.theme.colors[.Border]
	}

	if .Clicked in result {
		color = ctx.theme.colors[.Button_Clicked]
	} else if .Down in result {
		color = ctx.theme.colors[.Button_Clicked]
	}

	ui_draw_rect(ctx, rect, color, border)
	ui_draw_text(ctx, text, {
		rect.min.x + ctx.theme.text_padding,
		rect.min.y + ctx.theme.text_padding + ctx.theme.text_height,
	}, ctx.theme.colors[.Text], font, ctx.theme.text_height)

	return
}

@(require_results)
ui_textbox :: proc(
	ctx:          ^Ui_Context,
	text:         ^strings.Builder,
	initial_text: string         = "",
	max_length:   int            = -1,
	font:         Ui_Font        = .Interface,
	out_rect:     ^Ui_Rect       = nil,
	min_size:     ^[2]int        = nil,
) -> (result: Ui_Result) {
	width := int(ctx.measure_text(font, ctx.theme.text_height, strings.to_string(text^), ctx.user_pointer)) + ctx.theme.text_padding * 2
	rect  := ui_insert_rect(ctx, { width, ctx.widget_height, })
	result = ui_rect_result(ctx, rect)
	id    := ui_hash(text)

	if id not_in ctx.state {
		if strings.builder_len(text^) == 0 {
			strings.write_string(text, initial_text)
		}
		ctx.state[id] = nil
	}

	if min_size != nil {
		min_size^ = { width, ctx.widget_height, }
	}

	if out_rect != nil {
		out_rect^ = rect
	}

	border_width := 0
	color        := ctx.theme.colors[.Button]
	if .Hovered in result {
		border_width = ctx.theme.border_width
	}
	if .Clicked in result {
		color         = ctx.theme.colors[.Button_Clicked]
		ctx.active_id = id
	} else if .Down in result {
		color = ctx.theme.colors[.Button_Clicked]
	}

	if ctx.active_id == id {
		color        = ctx.theme.colors[.Background]
		border_width = ctx.theme.border_width

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
		color  = ctx.theme.colors[.Border],
		width  = border_width,
		radius = ctx.theme.border_radius,
	})
	ui_draw_text(ctx, strings.to_string(text^), {
		rect.min.x + ctx.theme.text_padding,
		rect.min.y + ctx.theme.text_padding + ctx.theme.text_height,
	}, ctx.theme.colors[.Text], font, ctx.theme.text_height)

	return
}

ui_label :: proc(
	ctx:      ^Ui_Context,
	text:     string,
	color:    Maybe([4]f32)    = nil,
	border:   Maybe(Ui_Border) = nil,
	font:     Ui_Font          = .Interface,
	out_rect: ^Ui_Rect         = nil,
	min_size: ^[2]int          = nil,
) -> (result: Ui_Result) {
	border := border.? or_else { radius = ctx.theme.border_radius, }
	width  := int(ctx.measure_text(font, ctx.theme.text_height, text, ctx.user_pointer)) + ctx.theme.text_padding * 2
	rect   := ui_insert_rect(ctx, { width, ctx.widget_height, })
	result  = ui_rect_result(ctx, rect)

	if .Hovered in result && ctx.current_time - ctx.mouse_last_move_time > UI_HOVER_THRESHOLD {
		result |= { .Tooltip, }
	}

	if min_size != nil {
		min_size^ = { width, ctx.widget_height, }
	}

	if out_rect != nil {
		out_rect^ = rect
	}

	ui_draw_rect(ctx, rect, color.? or_else ctx.theme.colors[.Label], border)
	ui_draw_text(ctx, text, {
		rect.min.x + ctx.theme.text_padding,
		rect.min.y + ctx.theme.text_padding + ctx.theme.text_height,
	}, ctx.theme.colors[.Text], font, ctx.theme.text_height)

	return
}

ui_color_button :: proc(ctx: ^Ui_Context, size: [2]int, color: [4]f32, border: Maybe(Ui_Border) = nil) -> Ui_Result {
	border := border.? or_else { radius = ctx.theme.border_radius, }

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
	ctx:         ^Ui_Context,
	text:        string,
	position:    [2]int,
	color:       [4]f32,
	font:        Ui_Font,
	text_height: int,
) {
	append(&ctx.cmds, Ui_Cmd_Text {
		position    = position,
		text        = text,
		color       = color,
		z           = ctx.z,
		font        = font,
		text_height = text_height,
	})
}

Ui_Section_Flag :: enum {
	Separator,
	Resizeable,
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
		frame.rect.min.y += size.y + ctx.theme.padding
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.min.x, frame.rect.min.y,                          },
				max = { frame.rect.max.x, frame.rect.min.y + ctx.theme.border_width, },
			} 
			frame.rect.min.y += ctx.theme.padding + ctx.theme.border_width
		}
		ctx.frame.rect.max.y = ctx.frame.rect.min.y + size.y
	case .Up:
		frame.rect.max.y -= size.y + ctx.theme.padding
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.min.x, frame.rect.max.y - ctx.theme.border_width, },
				max = { frame.rect.max.x, frame.rect.max.y,                          },
			}
			frame.rect.max.y -= ctx.theme.padding + ctx.theme.border_width
		}
		ctx.frame.rect.min.y = ctx.frame.rect.max.y - size.y
	case .Right:
		frame.rect.min.x += size.x + ctx.theme.padding
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.min.x,                          frame.rect.min.y, },
				max = { frame.rect.min.x + ctx.theme.border_width, frame.rect.max.y, },
			}
			frame.rect.min.x += ctx.theme.padding + ctx.theme.border_width
		}
		ctx.frame.rect.max.x = ctx.frame.rect.min.x + size.x
	case .Left:
		frame.rect.max.x -= size.x + ctx.theme.padding
		if .Separator in flags {
			separator_rect = {
				min = { frame.rect.max.x - ctx.theme.border_width, frame.rect.min.y, },
				max = { frame.rect.max.x,                          frame.rect.max.y, },
			}
			frame.rect.max.x -= ctx.theme.padding + ctx.theme.border_width
		}
		ctx.frame.rect.min.x = ctx.frame.rect.max.x - size.x
	}

	append(&ctx.stack, frame)
	ctx.extents = { ctx.frame.min, ctx.frame.min, }

	separator_color := ctx.theme.colors[.Border]
	if .Resizeable in flags {
		if state.dragged {
			separator_color = ctx.theme.colors[.Text]
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
			
			if ui_rect_contains(ui_rect_inflate(separator_rect, UI_RESIZE_MARGIN), ctx.mouse_position) {
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
	rect.max = rect.min + state.size + ctx.theme.padding * 2

	append(&ctx.stack, ctx.frame)

	ctx.z += 1
	ui_draw_rect(ctx, rect, { 0.15, 0.15, 0.15, 1, }, {
		radius = ctx.theme.border_radius,
		width  = ctx.theme.border_width,
		color  = { 0.2, 0.2, 0.2, 1, },
	})
	rect.min      += ctx.theme.padding
	rect.max      -= ctx.theme.padding
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
	rect.max = rect.min + state.size + ctx.theme.padding * 2
	if !button_clicked && ctx.mouse_buttons[0] == .Just_Clicked && !ui_rect_contains(rect, ctx.mouse_position) {
		// the user just clicked somewhere else, so we should close the popup
		// note that this does not work for nested popups and will need to be handled differently
		state.active = false
		return false
	}

	append(&ctx.stack, ctx.frame)

	ctx.z += 1
	ui_draw_rect(ctx, rect, { 0.15, 0.15, 0.15, 1, }, {
		radius = ctx.theme.border_radius,
		width  = ctx.theme.border_width,
		color  = { 0.2, 0.2, 0.2, 1, },
	})
	rect.min      += ctx.theme.padding
	rect.max      -= ctx.theme.padding
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

	if ui_rect_contains(ctx.extents, ctx.mouse_position) {
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

	border := border.? or_else { radius = ctx.theme.border_radius, }
	height := ctx.widget_height
	rect   := ui_insert_rect(ctx, { width, height, })
	result  = ui_rect_result(ctx, rect)
	id     := ui_hash(value)

	if out_rect != nil {
		out_rect^ = rect
	}

	if .Clicked in result {
		ctx.active_id = id
	}

	outer_color: [4]f32 = ctx.theme.colors[.Button]
	inner_color: [4]f32 = ctx.theme.colors[.Button_Clicked]
	if ctx.active_id == id {
		if ctx.mouse_buttons[0] != .None {
			inner_color = ctx.theme.colors[.Border]
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
	rect           = ui_rect_inflate(rect, -inset)
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
	font:      Ui_Font          = .Interface,
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
		out_rect.min.x + ctx.theme.text_padding,
		out_rect.min.y + ctx.theme.text_padding + ctx.theme.text_height,
	}, ctx.theme.colors[.Text], font, ctx.theme.text_height)
	return
}

ui_begin_frame :: proc(ctx: ^Ui_Context) {
	if ctx.mouse_delta != 0 {
		ctx.mouse_last_move_time = ctx.current_time
	}
	ctx.frame_id += 1
	clear(&ctx.cmds)
	clear(&ctx.popups)
	ctx.min  = ctx.theme.padding
	ctx.max -= ctx.theme.padding
	if ctx.mouse_buttons[0] == .Just_Clicked {
		ctx.active_id = 0
	}
	ctx.widget_height = ctx.theme.text_height + ctx.theme.text_padding * 2
}

@(require_results, deferred_in_out = ui_section_end)
ui_toggle_section :: proc(
	ctx:       ^Ui_Context,
	text:      string,
	direction: Ui_Direction,
	flags:     Ui_Section_Flags,
) -> bool {
	if !ui_toggle(ctx, text) {
		return false
	}

	return _ui_section(ctx, text, direction, flags)
}
