package rvdbg

import "base:intrinsics"
import "core:fmt"
import "core:io"
import "core:os"
import "core:math/rand"
import "core:strings"
import "core:terminal/ansi"
import "core:time"
import "core:unicode/utf8"

unicode_text_width :: proc(str: string) -> (width: int) {
	_, _, width = #force_inline utf8.grapheme_count(str)
	return
}

print_disassembly :: proc(
	section:   Section,
	assembled: []u32,
	source:    string,
	register_names      := true,
	syntax_highlighting := false,
) {
	fmt.printfln(".%v:", section_type_names[section.type])
	fmt.printfln("offset: %#x", section.offset)
	fmt.printfln("size:   %#x", section.len)
	fmt.print(   "flags:  ")
	{
		first := true
		for flag in section.flags {
			if !first {
				fmt.print(", ")
			}
			fmt.print(flag)
			first = false
		}
	}
	fmt.println("\n")

	if section.type != .Text {
		data := section.data.([]byte)
		for i in 0 ..< len(data) / 8 {
			i := i * 8
			for i in i ..< i + 8 {
				fmt.printf("%02x ", data[i])
			}
			fmt.print("| ")

			for i in i ..< i + 8 {
				v := '.'
				color: string
				switch data[i] {
				case 0x20 ..< 0x7F:
					color = ansi.FG_GREEN
					v = rune(data[i])
				case 0:
					color = ansi.FG_BLACK
				case:
					color = ansi.FG_YELLOW
				}
				fmt.printf(ansi.CSI + "%s" + ansi.SGR + "%c", color, v)
			}
			fmt.println(ansi.CSI + ansi.RESET + ansi.SGR)
		}
		defer fmt.println()

		if len(data) & 7 == 0 {
			return
		}

		for i in 8 * (len(data) / 8) ..< 8 * ((7 + len(data)) / 8) {
			if i < len(data) {
				fmt.printf("%02x ", data[i])
			} else {
				fmt.printf("   ")
			}
		}
		fmt.print("| ")
		for i in 8 * (len(data) / 8) ..< 8 * ((7 + len(data)) / 8) {
			if i >= len(data) {
				fmt.print(" ")
				continue
			}
			v := '.'
			color: string
			switch data[i] {
			case 0x20 ..< 0x7F:
				color = ansi.FG_GREEN
				v = rune(data[i])
			case 0:
				color = ansi.FG_BLACK
			case:
				color = ansi.FG_YELLOW
			}
			fmt.printf(ansi.CSI + "%s" + ansi.SGR + "%c", color, v)
		}
		fmt.println(ansi.CSI + ansi.RESET + ansi.SGR)

		return
	}

	lines := strings.split_lines(source, context.temp_allocator)

	max_line_len: int
	for line in lines[section.line_start:section.line_end - 1] {
		max_line_len = max(max_line_len, unicode_text_width(line))
	}

	instructions := section.data.([]Instruction)

	scratch_builder := strings.builder_make(context.temp_allocator)
	max_inst_len: int
	for inst in instructions {
		print_instruction(strings.to_writer(&scratch_builder), inst, register_names)
		max_inst_len = max(max_inst_len, unicode_text_width(strings.to_string(scratch_builder)))
		strings.builder_reset(&scratch_builder)
	}

	inst_cursor := 0
	for line, i in lines {
		if i < section.line_start - 1 {
			continue
		}
		if i > section.line_end - 1 {
			break
		}

		fmt.print(line)
		l := unicode_text_width(line)
		for _ in l ..< max_line_len {
			fmt.print(" ", flush = false)
		}

		fmt.print(" | ", flush = false)

		first := true
		for inst_cursor < len(instructions) && instructions[inst_cursor].line <= i + 1 {
			if !first {
				l = fmt.print("...")
				for _ in l ..< max_line_len {
					fmt.print(" ", flush = false)
				}
				fmt.print(" | ", flush = false)
			}

			print_instruction(strings.to_writer(&scratch_builder), instructions[inst_cursor], register_names, syntax_highlighting)
			fmt.print(strings.to_string(scratch_builder))
			strings.builder_reset(&scratch_builder)
			print_instruction(strings.to_writer(&scratch_builder), instructions[inst_cursor], register_names)
			for _ in unicode_text_width(strings.to_string(scratch_builder)) ..< max_inst_len {
				fmt.print(" ", flush = false)
			}
			strings.builder_reset(&scratch_builder)
			fmt.printfln(" | %#8x | %#8x", assembled[inst_cursor], u32(inst_cursor * 4) + section.offset)

			inst_cursor += 1
			first        = false
		}
		if first {
			for _ in 0 ..< max_inst_len {
				fmt.print(" ", flush = false)
			}
			fmt.println(" |            |")
		}
	}
}

main :: proc() {
	source_bytes, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	source_builder: strings.Builder
	line_len: int
	for b in source_bytes {
		if b == '\t' {
			line_len += 1
			strings.write_byte(&source_builder, ' ')
			for line_len % 4 != 0 {
				strings.write_byte(&source_builder, ' ')
				line_len += 1
			}
			continue
		}
		line_len += 1
		if b == '\n' {
			line_len = 0
		}
		strings.write_byte(&source_builder, b)
	}
	source := strings.to_string(source_builder)

	window(source)
}

fuzz :: proc() {
	fmt.println("Fuzzing:")

	N :: 1 << 10

	start := time.now()

	instructions := make([]Instruction, N)
	for &inst in instructions {
		inst.mnemonic = rand.choice_enum(Mnemonic)
		switch instruction_infos[inst.mnemonic].type {
		case .R:
			inst.rd  = rand.choice_enum(Register)
			inst.rs1 = rand.choice_enum(Register)
			inst.rs2 = rand.choice_enum(Register)
		case .I:
			inst.rd  = rand.choice_enum(Register)
			inst.rs1 = rand.choice_enum(Register)
			inst.imm = rand.int31() & 0xFFF - (1 << 11)
		case .T:
			inst.rd  = rand.choice_enum(Register)
			inst.rs1 = rand.choice_enum(Register)
			inst.imm = i32(rand.uint32() & 0x1F)
		case .S:
			inst.rs1 = rand.choice_enum(Register)
			inst.rs2 = rand.choice_enum(Register)
			inst.imm = rand.int31() & 0xFFF - (1 << 11)
		case .B:
			inst.rs1 = rand.choice_enum(Register)
			inst.rs2 = rand.choice_enum(Register)
			inst.imm = (rand.int31() & 0xFFF - (1 << 11)) << 1
		case .U:
			inst.rd  = rand.choice_enum(Register)
			inst.imm = rand.int31() & 0xFFFFF
		case .J:
			inst.rd  = rand.choice_enum(Register)
			inst.imm = (rand.int31() & 0xFFFFF - (1 << 19)) << 1
		case .E:
		}
	}

	fmt.println("\tgenerate: ", time.since(start))
	start = time.now()

	encoded := assemble_instructions(instructions)

	fmt.println("\tassemble: ", time.since(start))
	start = time.now()

	for e, i in encoded {
		inst, ok := disassemble_instruction(e)
		if !ok {
			fmt.printfln("%#8x", e)
			fmt.println(instructions[i])
			panic("")
		}
		if inst != instructions[i] {
			fmt.printfln("%#8x", e)
			fmt.println(instructions[i])
			fmt.println(inst)
			panic("")
		}
	}

	fmt.println("\tcheck:    ", time.since(start))
	start = time.now()

	b := strings.builder_make()
	w := strings.to_writer(&b)

	for inst in instructions {
		print_instruction(w, inst)
		io.write_byte(w, '\n')
	}

	fmt.println("\tto_string:", time.since(start))
	start = time.now()

	sections, relocations, labels, errors := parse_assembly(strings.to_string(b))
	assert(len(errors) == 0)

	linker_errors := resolve_relocations(sections, labels, relocations)
	assert(len(linker_errors) == 0)

	fmt.println("\tparse:    ", time.since(start))
	start = time.now()

	parsed_instructions := sections[0].data.([]Instruction)
	for inst, i in instructions {
		parsed_instructions[i].line = 0
		if inst != parsed_instructions[i] {
			fmt.println(inst)
			fmt.println(parsed_instructions[i])
		}
		assert(inst == parsed_instructions[i])
	}

	fmt.println("\tcheck:    ", time.since(start))
	start = time.now()

	fmt.println()
}
