package rvdbg

import "base:intrinsics"

import "core:fmt"
import "core:strconv"
import "core:strings"

Watch :: struct {
	input: strings.Builder,
}

Watch_Window :: struct {
	watches: [dynamic]Watch,
	input:   strings.Builder,
}

Watch_Token_Kind :: enum {
	Invalid = 0,

	Mul   = '*',
	Add   = '+',
	Sub   = '-',
	Div   = '/',
	Mod   = '%',
	Xor   = '~',
	Or    = '|',
	And   = '&',

	Dot           = '.',
	Hashtag       = '#',
	Caret         = '^',
	Open_Paren    = '(',
	Close_Paren   = ')',
	Open_Bracket  = '[',
	Close_Bracket = ']',

	Ident = 128,
	Literal,

	EOF,
}

Watch_Token :: struct {
	kind:   Watch_Token_Kind,
	lexeme: string,
	offset: int,
}

watch_expression_tokenize :: proc(
	expression: string,
	allocator := context.allocator,
) -> (tokens: [dynamic]Watch_Token, error: string, ok: bool) {
	tokens.allocator = allocator

	current: int
	for current < len(expression) {
		start := current

		token := Watch_Token {
			offset = current,
		}

		base := 10

		char    := expression[current]
		current += 1
		switch char {
		case '*', '+', '-', '/', '%', '~', '.', '#', '^', '(', ')', '[', ']', '|', '&':
			token.kind = Watch_Token_Kind(char)
		case '0':
			if current < len(expression) {
				switch expression[current] {
				case 'b':
					base     = 2
					current += 1
				case 'o':
					base     = 8
					current += 1
				case 'x':
					base     = 16
					current += 1
				}
			}
			fallthrough
		case '1' ..= '9':
			token.kind = .Literal

			valid_chars: bit_set[0 ..< rune(128)]
			switch base {
			case 2:
				valid_chars = { '0', '1', }
			case 8:
				for char in '0' ..= '7' {
					valid_chars |= { char, }
				}
			case 16:
				for char in 'a' ..= 'f' {
					valid_chars |= { char, char + 'A' - 'a', }
				}
				fallthrough
			case 10:
				for char in '0' ..= '9' {
					valid_chars |= { char, }
				}
			}
			valid_chars |= { '_', }

			for current < len(expression) {
				if rune(expression[current]) not_in valid_chars {
					break
				}
				current += 1
			}

			value, number_ok := strconv.parse_u64(expression[start:current])
			if !number_ok || value >= 1 << 32 {
				error = fmt.aprintf("Failed to parse integer literal: '%s'", expression[start:current], allocator = allocator)
				return
			}
		case 'a' ..= 'z', 'A' ..= 'Z', '_':
			token.kind = .Ident

			for current < len(expression) {
				switch expression[current] {
				case 'a' ..= 'z', 'A' ..= 'Z', '_', '0' ..= '9':
					current += 1
					continue
				}
				break
			}
		case ' ', '\t', '\n':
			continue
		case:
			error = fmt.aprintf("Unexpected character: '%c'", char, allocator = allocator)
			return
		}

		token.lexeme = expression[start:current]
		append(&tokens, token)
	}

	append(&tokens, Watch_Token {
		kind   = .EOF,
		offset = current,
	})

	ok = true
	return
}

watch_expression_format :: proc(
	value:      u32,
	format:     Watch_Format,
	debugger:  ^Debugger,
	allocator := context.allocator,
) -> (str: string, truncated: bool) {
	format_string :: proc(str: string, address: u32, allocator := context.allocator) -> (string, bool) {
		if len(str) < 50 { // TODO: make this configurable
			return fmt.aprintf("\"%s\" (0x%08x)", str, address, allocator = allocator), false
		} else {
			return fmt.aprintf("\"%s...\" (0x%08x)", str[:50], address, allocator = allocator), true
		}
	}
	
	switch format {
	case .Hex:
		return fmt.aprintf("0x%08x", value, allocator = allocator), false
	case .Decimal:
		return fmt.aprintf("%d", value, allocator = allocator), false
	case .CString:
		return format_string(string(cstring(&debugger.cpu.mem[value])), value, allocator)
	case .PString:
		return format_string(string(([^]byte)(&debugger.cpu.mem[value + 1])[:debugger.cpu.mem[value]]), value, allocator)
	case .Unicode:
		return fmt.aprintf("'%c' (0x%08x)", value, value, allocator = allocator), false
	case .Instruction:
		instruction, ok := disassemble_instruction(value)
		if !ok {
			return fmt.aprintf("<Invalid Instruction> (0x%08x)", value, allocator = allocator), false
		}
		b := strings.builder_make(allocator)
		strings.write_byte(&b, '`')
		print_instruction(strings.to_writer(&b), instruction, true)
		fmt.sbprintf(&b, "` (0x%08x)", value)
		return strings.to_string(b), false
	}
	return fmt.aprintf("0x%08x", value, allocator = allocator), false
}

Watch_Format :: enum {
	Hex = 0,
	Decimal,
	CString,
	PString,
	Unicode,
	Instruction,
	// Float,
	// Fixed,
}

@(rodata)
format_names: [Watch_Format]string = {
	.Hex         = "hex",
	.Decimal     = "dec",
	.CString     = "cstring",
	.PString     = "pstring",
	.Unicode     = "unicode",
	.Instruction = "instruction",
}

watch_expression_evaluate :: proc(
	expression: string,
	debugger:  ^Debugger,
	allocator := context.allocator,
) -> (value: u32, format: Watch_Format, error: string, ok: bool) {
	tokens: [dynamic]Watch_Token
	tokens, error, ok = watch_expression_tokenize(expression, context.temp_allocator)
	if !ok || len(tokens) == 0 {
		return
	}

	Parser :: struct {
		tokens:   []Watch_Token,
		current:  int,
		debugger: ^Debugger,
	}

	parser := Parser {
		tokens   = tokens[:],
		debugger = debugger,
	}

	@(require_results)
	token_peek :: proc(parser: ^Parser) -> Watch_Token {
		return parser.tokens[min(parser.current, len(parser.tokens) - 1)]
	}

	token_advance :: proc(parser: ^Parser) -> Watch_Token {
		defer parser.current += 1
		return parser.tokens[min(parser.current, len(parser.tokens) - 1)]
	}

	token_expect :: proc(parser: ^Parser, kind: Watch_Token_Kind) -> (token: Watch_Token, ok: bool) {
		if token_peek(parser).kind == kind {
			return token_advance(parser), true
		}
		return
	}

	evaluate_atom :: proc(parser: ^Parser) -> u32 {
		#partial switch token := token_advance(parser); token.kind {
		case .Mul:
			address := evaluate_atom(parser)

			value := &parser.debugger.cpu.mem[address]
			return intrinsics.unaligned_load((^u32)(value))
		case .Add:
			return evaluate_atom(parser)
		case .Sub:
			return -evaluate_atom(parser)
		case .Xor:
			return ~evaluate_atom(parser)
		case .Literal:
			return u32(strconv.parse_u64(token.lexeme) or_else panic("Failed to parse number"))
		case .Ident:
			for name, register in register_names {
				if name == token.lexeme {
					return parser.debugger.cpu.registers[register]
				}
			}
		case .Open_Paren:
			value := evaluate_expression(parser)
			token_expect(parser, .Close_Paren)
			return value
		}

		return ~u32{}
	}

	@(static, rodata)
	binding_powers: #sparse [Watch_Token_Kind]int = #partial {
		.And       = 6,
		.Or        = 6,
		.Xor       = 6,
		.Add       = 6,
		.Sub       = 6,

		.Mul       = 7,
		.Div       = 7,
		.Mod       = 7,
	}

	evaluate_expression :: proc(parser: ^Parser, min_power := 0) -> u32 {
		lhs := evaluate_atom(parser)
		for {
			op    := token_peek(parser)
			power := binding_powers[op.kind]

			if power == 0 || power <= min_power {
				break
			}

			token_advance(parser)

			rhs := evaluate_expression(parser, power)

			#partial switch op.kind {
			case .Add:
				lhs = lhs + rhs
			case .Sub:
				lhs = lhs - rhs
			case .Mul:
				lhs = lhs * rhs
			case .Div:
				if rhs != 0 {
					lhs = lhs / rhs
				}
				lhs = ~u32{}
			case .Mod:
				if rhs != 0 {
					lhs = lhs % rhs
				}
				lhs = ~u32{}
			case .Xor:
				lhs = lhs ~ rhs
			case .Or:
				lhs = lhs | rhs
			case .And:
				lhs = lhs & rhs
			}
		}
		return lhs
	}

	value = evaluate_expression(&parser)

	if token_peek(&parser).kind == .Hashtag {
		token_advance(&parser)
		t, ok := token_expect(&parser, .Ident)
		if ok {
			for name, f in format_names {
				if name == t.lexeme || (len(t.lexeme) == 1 && t.lexeme[0] == name[0]) {
					format = f
					break
				}
			}
		}
	}

	ok = true
	return
}

watch_window_ui :: proc(ctx: ^Ui_Context, debugger: ^Debugger, watch_window: ^Watch_Window) {
	@(static)
	max_widths: [2]int
	last_max_widths := max_widths
	max_widths       = 0

	min_size: [2]int
	to_be_removed := -1
	for &watch, i in watch_window.watches {
		ui_section(ctx, fmt.tprintf("Watch_%d", i), .Down, {}) or_continue
		ctx.direction  = .Right
		ctx.min_size.x = last_max_widths[0]

		if .Submit in ui_textbox(ctx, &watch.input, "0x0", min_size = &min_size, font = .Monospace) {
			if strings.builder_len(watch.input) == 0 {
				to_be_removed = i
				continue
			}

			_, _, error, ok := watch_expression_evaluate(strings.to_string(watch.input), debugger, context.temp_allocator)
			if !ok {
				debugger_set_last_error(debugger, error)
			}
		}
		max_widths[0] = max(max_widths[0], min_size.x)

		ctx.min_size.x = last_max_widths[1]
		value, format, error, ok := watch_expression_evaluate(strings.to_string(watch.input), debugger, context.temp_allocator)
		if ok {
			str, truncated := watch_expression_format(value, format, debugger, context.temp_allocator)
			if .Tooltip in ui_label(ctx, str, min_size = &min_size, font = .Monospace) && truncated {
				if ui_tooltip_popup(ctx, fmt.tprintf("Tooltip_Watch_%d", i)) {
					ctx.min_size = {}
					ui_label(ctx, "truncated")
				}
			}
		} else {
			ui_label(ctx, error, min_size = &min_size, font = .Monospace)
		}
		max_widths[1] = max(max_widths[1], min_size.x)
	}

	if to_be_removed != -1 {
		strings.builder_destroy(&watch_window.watches[to_be_removed].input)
		ordered_remove(&watch_window.watches, to_be_removed)
	}

	if .Submit in ui_textbox(ctx, &watch_window.input, "0x0", font = .Monospace) {
		_, _, error, ok := watch_expression_evaluate(strings.to_string(watch_window.input), debugger, context.temp_allocator)
		if !ok {
			debugger_set_last_error(debugger, error)
		} else {
			append(&watch_window.watches, Watch {
				input = watch_window.input,
			})
			watch_window.input = {}
			strings.write_string(&watch_window.input, "0x0")
		}
	}
}

watch_window_destroy :: proc(watch_window: ^Watch_Window) {
	for &watch in watch_window.watches {
		strings.builder_destroy(&watch.input)
	}
	delete(watch_window.watches)
	strings.builder_destroy(&watch_window.input)
}
