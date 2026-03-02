package rvdbg

import "base:intrinsics"
import "base:runtime"

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:terminal/ansi"
import "core:time"
import "core:unicode/utf8"

Register :: enum u8 {
	Zero = 0,
	Ra   = 1,
	Sp   = 2,
	Gp   = 3,
	Tp   = 4,

	T0   = 5,
	T1   = 6,
	T2   = 7,

	S0   = 8,
	Fp   = 8,
	S1   = 9,

	A0   = 10,
	A1   = 11,
	A2   = 12,
	A3   = 13,
	A4   = 14,
	A5   = 15,
	A6   = 16,
	A7   = 17,

	S2   = 18,
	S3   = 19,
	S4   = 20,
	S5   = 21,
	S6   = 22,
	S7   = 23,
	S8   = 24,
	S9   = 25,
	S10  = 26,
	S11  = 27,

	T3   = 28,
	T4   = 29,
	T5   = 30,
	T6   = 31,
}

Instruction_Type :: enum {
	R,
	I,
	S, // store
	B,
	U,
	J,

	E, // ebreak, ecall
	T, // Pseudo instruction type for shifts, basically just I-Type
}

Instruction_Arg :: enum {
	Rel12,
	Imm12,
	Imm20,
	Rel20,
	Uimm20,
	Uimm5,
	Off12,
	Rd,
	Rs1,
	Rs2,

	Imm,
	Rel,
	Addr,
}

Instruction_Info :: struct {
	mnemonic: string,
	args:     []Instruction_Arg,
	type:     Instruction_Type,
	funct3:   u8,
	funct7:   u8,
	funct12:  u16,
	opcode:   u8,
}

Mnemonic :: enum {
	Addi,
	Slti,
	Sltiu,
	Andi,
	Ori,
	Xori,
	Slli,
	Srli,
	Srai,

	Lui,
	Auipc,

	Add,
	Sub,
	Slt,
	Sltu,
	And,
	Or,
	Xor,
	Sll,
	Srl,
	Sra,

	Jal,
	Jalr,
	Beq,
	Bne,
	Blt,
	Bltu,
	Bge,
	Bgeu,

	Lw,
	Lh,
	Lhu,
	Lb,
	Lbu,

	Sw,
	Sh,
	Sb,

	Ecall,
	Ebreak,

	Mul,
	Mulh,
	Mulhu,
	Mulhsu,

	Div,
	Divu,
	Rem,
	Remu,
}

@(rodata)
instruction_infos := [Mnemonic]Instruction_Info {
	.Addi   = { mnemonic = "addi",   args = { .Rd,  .Rs1,    .Imm12, }, type = .I, funct3 = 0b000,                      opcode = 0b001_0011, },
	.Slti   = { mnemonic = "slti",   args = { .Rd,  .Rs1,    .Imm12, }, type = .I, funct3 = 0b010,                      opcode = 0b001_0011, },
	.Sltiu  = { mnemonic = "sltiu",  args = { .Rd,  .Rs1,    .Imm12, }, type = .I, funct3 = 0b011,                      opcode = 0b001_0011, },
	.Andi   = { mnemonic = "andi",   args = { .Rd,  .Rs1,    .Imm12, }, type = .I, funct3 = 0b111,                      opcode = 0b001_0011, },
	.Ori    = { mnemonic = "ori",    args = { .Rd,  .Rs1,    .Imm12, }, type = .I, funct3 = 0b110,                      opcode = 0b001_0011, },
	.Xori   = { mnemonic = "xori",   args = { .Rd,  .Rs1,    .Imm12, }, type = .I, funct3 = 0b100,                      opcode = 0b001_0011, },

	.Slli   = { mnemonic = "slli",   args = { .Rd,  .Rs1,    .Uimm5, }, type = .T, funct3 = 0b001, funct7 = 0b000_0000, opcode = 0b001_0011, },
	.Srli   = { mnemonic = "srli",   args = { .Rd,  .Rs1,    .Uimm5, }, type = .T, funct3 = 0b101, funct7 = 0b000_0000, opcode = 0b001_0011, },
	.Srai   = { mnemonic = "srai",   args = { .Rd,  .Rs1,    .Uimm5, }, type = .T, funct3 = 0b101, funct7 = 0b010_0000, opcode = 0b001_0011, },

	.Lui    = { mnemonic = "lui",    args = { .Rd,  .Uimm20,         }, type = .U, funct3 = 0b000, funct7 = 0b000_0000, opcode = 0b011_0111, },
	.Auipc  = { mnemonic = "auipc",  args = { .Rd,  .Uimm20,         }, type = .U, funct3 = 0b000, funct7 = 0b000_0000, opcode = 0b001_0111, },

	.Add    = { mnemonic = "add",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b000, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.Sub    = { mnemonic = "sub",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b000, funct7 = 0b010_0000, opcode = 0b011_0011, },
	.Slt    = { mnemonic = "slt",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b010, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.Sltu   = { mnemonic = "sltu",   args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b011, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.And    = { mnemonic = "and",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b111, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.Or     = { mnemonic = "or",     args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b110, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.Xor    = { mnemonic = "xor",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b100, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.Sll    = { mnemonic = "sll",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b001, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.Srl    = { mnemonic = "srl",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b101, funct7 = 0b000_0000, opcode = 0b011_0011, },
	.Sra    = { mnemonic = "sra",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b101, funct7 = 0b010_0000, opcode = 0b011_0011, },

	.Jal    = { mnemonic = "jal",    args = { .Rd,  .Rel20,          }, type = .J, funct3 = 0b000,                      opcode = 0b110_1111, },
	.Jalr   = { mnemonic = "jalr",   args = { .Rd,  .Rs1,    .Rel12, }, type = .I, funct3 = 0b000,                      opcode = 0b110_0111, },

	.Beq    = { mnemonic = "beq",    args = { .Rs1, .Rs2,    .Rel12, }, type = .B, funct3 = 0b000,                      opcode = 0b110_0011, },
	.Bne    = { mnemonic = "bne",    args = { .Rs1, .Rs2,    .Rel12, }, type = .B, funct3 = 0b001,                      opcode = 0b110_0011, },
	.Blt    = { mnemonic = "blt",    args = { .Rs1, .Rs2,    .Rel12, }, type = .B, funct3 = 0b100,                      opcode = 0b110_0011, },
	.Bge    = { mnemonic = "bge",    args = { .Rs1, .Rs2,    .Rel12, }, type = .B, funct3 = 0b101,                      opcode = 0b110_0011, },
	.Bltu   = { mnemonic = "bltu",   args = { .Rs1, .Rs2,    .Rel12, }, type = .B, funct3 = 0b110,                      opcode = 0b110_0011, },
	.Bgeu   = { mnemonic = "bgeu",   args = { .Rs1, .Rs2,    .Rel12, }, type = .B, funct3 = 0b111,                      opcode = 0b110_0011, },

	.Lw     = { mnemonic = "lw",     args = { .Rd,  .Off12,  .Rs1,   }, type = .I, funct3 = 0b010,                      opcode = 0b000_0011, },
	.Lh     = { mnemonic = "lh",     args = { .Rd,  .Off12,  .Rs1,   }, type = .I, funct3 = 0b001,                      opcode = 0b000_0011, },
	.Lhu    = { mnemonic = "lhu",    args = { .Rd,  .Off12,  .Rs1,   }, type = .I, funct3 = 0b101,                      opcode = 0b000_0011, },
	.Lb     = { mnemonic = "lb",     args = { .Rd,  .Off12,  .Rs1,   }, type = .I, funct3 = 0b000,                      opcode = 0b000_0011, },
	.Lbu    = { mnemonic = "lbu",    args = { .Rd,  .Off12,  .Rs1,   }, type = .I, funct3 = 0b100,                      opcode = 0b000_0011, },

	.Sw     = { mnemonic = "sw",     args = { .Rs2, .Off12,  .Rs1,   }, type = .S, funct3 = 0b010,                      opcode = 0b100_0011, },
	.Sh     = { mnemonic = "sh",     args = { .Rs2, .Off12,  .Rs1,   }, type = .S, funct3 = 0b001,                      opcode = 0b100_0011, },
	.Sb     = { mnemonic = "sb",     args = { .Rs2, .Off12,  .Rs1,   }, type = .S, funct3 = 0b000,                      opcode = 0b100_0011, },

	.Ecall  = { mnemonic = "ecall",  args = {                        }, type = .E, funct12 = 0,                         opcode = 0b111_0011, },
	.Ebreak = { mnemonic = "ebreak", args = {                        }, type = .E, funct12 = 1,                         opcode = 0b111_0011, },

	.Mul    = { mnemonic = "mul",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b000, funct7 = 0b000_0001, opcode = 0b011_0011, },
	.Mulh   = { mnemonic = "mulh",   args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b001, funct7 = 0b000_0001, opcode = 0b011_0011, },
	.Mulhu  = { mnemonic = "mulhu",  args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b011, funct7 = 0b000_0001, opcode = 0b011_0011, },
	.Mulhsu = { mnemonic = "mulhsu", args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b010, funct7 = 0b000_0001, opcode = 0b011_0011, },

	.Div    = { mnemonic = "div",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b100, funct7 = 0b000_0001, opcode = 0b011_0011, },
	.Divu   = { mnemonic = "divu",   args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b101, funct7 = 0b000_0001, opcode = 0b011_0011, },
	.Rem    = { mnemonic = "rem",    args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b110, funct7 = 0b000_0001, opcode = 0b011_0011, },
	.Remu   = { mnemonic = "remu",   args = { .Rd,  .Rs1,    .Rs2,   }, type = .R, funct3 = 0b111, funct7 = 0b000_0001, opcode = 0b011_0011, },
}

MAX_MNEMONIC_LEN :: 6

R_Type_Instruction :: bit_field u32 {
	opcode: u8       | 7,
	rd:     Register | 5,
	funct3: u8       | 3,
	rs1:    Register | 5,
	rs2:    Register | 5,
	funct7: u8       | 7,
}

S_Type_Instruction :: bit_field u32 {
	opcode:   u8       | 7,
	imm_0_4:  u8       | 5,
	funct3:   u8       | 3,
	rs1:      Register | 5,
	rs2:      Register | 5,
	imm_5_11: i8       | 7,
}

B_Type_Instruction :: bit_field u32 {
	opcode:   u8       | 7,
	imm_11:   u8       | 1,
	imm_1_4:  u8       | 4,
	funct3:   u8       | 3,
	rs1:      Register | 5,
	rs2:      Register | 5,
	imm_5_10: u8       | 6,
	imm_12:   i8       | 1,
}

J_Type_Instruction :: bit_field u32 {
	opcode:    u8        | 7,
	rd:        Register  | 5,
	imm_12_19: u32       | 8,
	imm_11:    u32       | 1,
	imm_1_10:  u32       | 10,
	imm_20:    i32       | 1,
}

register_names: [Register]string
register_aliases: map[string]Register

@(init)
register_tables_init :: proc "contextless" () {
	context = runtime.default_context()
	for r in Register {
		name := strings.to_lower(reflect.enum_name_from_value(r) or_else panic(""))
		register_names[r]      = name
		register_aliases[name] = r
	}
}

Pseudo_Instruction_Mnemonic :: enum {
	La,
	Li,
	Mv,
	Not,
	Nop,

	J,
	Jr,

	Ret,
	Call,

	Bgt,
	Bgtu,
	Ble,
	Bleu,

	Beqz,
	Bnez,
}

Pseudo_Instruction_Info :: struct {
	mnemonic: string,
	args:     []Instruction_Arg,
}

@(rodata)
pseudo_instruction_infos := [Pseudo_Instruction_Mnemonic]Pseudo_Instruction_Info{
	.La   = { mnemonic = "la",   args = { .Rd,    .Addr,          }, },
	.Li   = { mnemonic = "li",   args = { .Rd,    .Imm,           }, },
	.Mv   = { mnemonic = "mv",   args = { .Rd,    .Rs1,           }, },
	.Not  = { mnemonic = "not",  args = { .Rd,    .Rs1,           }, },
	.J    = { mnemonic = "j",    args = { .Rel20,                 }, },
	.Jr   = { mnemonic = "jr",   args = { .Off12, .Rs1,           }, },
	.Call = { mnemonic = "call", args = { .Rel12,                 }, },
	.Ret  = { mnemonic = "ret",  args = {                         }, },
	.Nop  = { mnemonic = "nop",  args = {                         }, },

	.Bgt  = { mnemonic = "bgt",  args = { .Rs1,   .Rs2,   .Rel12, }, },
	.Bgtu = { mnemonic = "bgtu", args = { .Rs1,   .Rs2,   .Rel12, }, },
	.Ble  = { mnemonic = "ble",  args = { .Rs1,   .Rs2,   .Rel12, }, },
	.Bleu = { mnemonic = "bleu", args = { .Rs1,   .Rs2,   .Rel12, }, },

	.Bnez = { mnemonic = "bnez", args = { .Rs1,   .Rel12,         }, },
	.Beqz = { mnemonic = "beqz", args = { .Rs1,   .Rel12,         }, },
}

Instruction_Args :: struct {
	rd, rs1, rs2: Register,
	imm:          i32,
}

Instruction :: struct {
	mnemonic:   Mnemonic,
	using args: Instruction_Args,
	type:       Instruction_Type,

	line:       int,
}

Error_Severity :: enum {
	Warning,
	Error,
}

Error :: struct {
	line, column: int,
	message:      string,
	severity:     Error_Severity,
}

Location :: struct {
	section: int,
	offset:  u32,
}

Relocation_Type :: enum {
	Relative_20_12,
	Relative_20,
	Relative_12,

	Absolute_32,
	Absolute_20_12,
	Absolute_20,
	Absolute_12,
}

Relocation :: struct {
	label:    string,
	location: Location,
	type:     Relocation_Type,
	line:     int,
}

resolve_relocations :: proc(
	sections:     []Section,
	labels:       map[string]Location,
	relocations:  []Relocation,
	error_allocator := context.allocator,
) -> (errors: []Error) {
	Linking_Context :: struct {
		errors:          [dynamic]Error,
		error_allocator: runtime.Allocator,
	}

	ctx := &Linking_Context {
		error_allocator = error_allocator,
	}

	error :: proc(ctx: ^Linking_Context, line: int, message: string, severity := Error_Severity.Error) {
		append(&ctx.errors, Error {
			line     = line,
			message  = message,
			severity = severity,
		})
	}

	errorf :: proc(ctx: ^Linking_Context, line: int, format: string, args: ..any, severity := Error_Severity.Error) {
		append(&ctx.errors, Error {
			line     = line,
			message  = fmt.aprintf(format, ..args, allocator = ctx.error_allocator),
			severity = severity,
		})
	}

	for rel in relocations {
		label, ok := labels[rel.label]
		if !ok {
			errorf(ctx, rel.line, "Unresolved label: `%s`", rel.label)
			continue
		}

		ref_offset := sections[rel.location.section].offset + rel.location.offset

		value: i32
		switch rel.type {
		case .Relative_20_12, .Relative_20, .Relative_12:
			value = i32(sections[label.section].offset + label.offset - ref_offset)
		case .Absolute_20_12, .Absolute_20, .Absolute_12, .Absolute_32:
			value = i32(sections[label.section].offset + label.offset)
		}

		if rel.type == .Absolute_32 {
			data := sections[rel.location.section].data.([]byte)
			intrinsics.unaligned_store(cast(^u32)&data[rel.location.offset], u32(value))
			continue
		}

		instructions := sections[rel.location.section].data.([]Instruction)
		#partial switch rel.type {
		case .Relative_20_12, .Absolute_20_12:
			assert(instructions[rel.location.offset / 4 + 0].mnemonic == .Lui)
			assert(
				instructions[rel.location.offset / 4 + 1].mnemonic == .Addi ||
				instructions[rel.location.offset / 4 + 1].mnemonic == .Jalr,
			)

			instructions[rel.location.offset / 4 + 0].imm = (value + 0x800) >> 12
			instructions[rel.location.offset / 4 + 1].imm =  value & 0xFFF

			continue
		}

		min_value, max_value: i32
		#partial switch rel.type {
		case .Relative_12:
			max_value = ( (1 << 11) - 1) << 1
			min_value = (-(1 << 11)    ) << 1
		case .Absolute_12:
			max_value =  (1 << 11) - 1
			min_value = -(1 << 11)
		case .Relative_20:
			max_value = ( (1 << 19) - 1) << 1
			min_value = (-(1 << 19)    ) << 1
		case .Absolute_20:
			max_value =  (1 << 19) - 1
			min_value = -(1 << 19)
		}

		if value < min_value || value > max_value {
			errorf(ctx, rel.line, "Relocation out of range for label `%s`: %d (%d ..= %d)", rel.label, value, min_value, max_value)
			continue
		}
		instructions[rel.location.offset / 4].imm = value
	}

	return ctx.errors[:]
}

Section_Type :: enum {
	Text = 0,
	Data,
	Rodata,
}

@(rodata)
section_type_names := [Section_Type]string{
	.Text   = "text",
	.Data   = "data",
	.Rodata = "rodata",
}

Section_Flag :: enum {
	Write,
	Execute,
}

Section :: struct {
	type:   Section_Type,
	offset: u32,
	len:    int,
	flags:  bit_set[Section_Flag],
	data:   union {
		[]Instruction,
		[]byte,
	},
	line_start, line_end: int,
}

// TODO: rewrite with tokenization
@(require_results)
parse_assembly :: proc(
	data: string,
	data_allocator  := context.allocator,
	error_allocator := context.allocator,
) -> (
	sections:    []Section,
	relocations: []Relocation,
	labels:      map[string]Location,
	errors:      []Error,
) {
	data := data
	
	Parsing_Context :: struct {
		line, offset:       int,
		section_offset:     int,
		section_start_line: int,
		section_end_line:   int,
		section_type:       Section_Type,
		labels:             map[string]Location,
		constants:          map[string]int,
		relocations:        [dynamic]Relocation,
		instructions:       [dynamic]Instruction,
		data_buffer:        bytes.Buffer,
		sections:           [dynamic]Section,
		errors:             [dynamic]Error,
		error_allocator:    runtime.Allocator,
		data_allocator:     runtime.Allocator,
	}

	error :: proc(ctx: ^Parsing_Context, message: string, severity := Error_Severity.Error) {
		append(&ctx.errors, Error {
			line     = ctx.line,
			message  = message,
			severity = severity,
		})
	}

	errorf :: proc(ctx: ^Parsing_Context, format: string, args: ..any, severity := Error_Severity.Error) {
		append(&ctx.errors, Error {
			line     = ctx.line,
			message  = fmt.aprintf(format, ..args, allocator = ctx.error_allocator),
			severity = severity,
		})
	}

	write_instruction :: proc(ctx: ^Parsing_Context, instruction: Instruction) {
		instruction     := instruction
		instruction.line = ctx.line
		ctx.offset      += 4
		append(&ctx.instructions, instruction)
	}

	end_section :: proc(ctx: ^Parsing_Context) {
		if ctx.offset != 0 {
			section: Section = {
				type       = ctx.section_type,
				offset     = u32(ctx.section_offset),
				line_end   = ctx.line - 1,
				line_start = ctx.section_start_line,
			}
			switch ctx.section_type {
			case .Data:
				section.flags = { .Write, }
				section.data  = ctx.data_buffer.buf[:]
				section.len   = len(ctx.data_buffer.buf[:])
			case .Rodata:
				section.flags = {}
				section.data  = ctx.data_buffer.buf[:]
				section.len   = len(ctx.data_buffer.buf[:])
			case .Text:
				section.flags = { .Execute, }
				section.data  = ctx.instructions[:]
				section.len   = len(ctx.instructions[:]) * 4
			}
			append(&ctx.sections, section)
			ctx.section_start_line = ctx.line
		}

		ctx.offset         = 0
		ctx.section_offset = 0
		ctx.instructions   = make([dynamic]Instruction, ctx.data_allocator)
		ctx.data_buffer    = {}
		bytes.buffer_init_allocator(&ctx.data_buffer, 0, 0, ctx.data_allocator)
	}

	ctx := &Parsing_Context {
		errors          = make([dynamic]Error,       error_allocator),
		instructions    = make([dynamic]Instruction, data_allocator),
		sections        = make([dynamic]Section,     data_allocator),
		relocations     = make([dynamic]Relocation,  data_allocator),
		labels          = make(map[string]Location,  data_allocator),
		error_allocator = error_allocator,
		data_allocator  = data_allocator,
	}
	bytes.buffer_init_allocator(&ctx.data_buffer, 0, 0, ctx.data_allocator)

	defer {
		delete(ctx.constants)
		delete(ctx.instructions)
		delete(ctx.data_buffer.buf)
	}

	lines_loop: for line in strings.split_lines_iterator(&data) {
		ctx.line += 1

		line := strings.trim_left_space(line)
		line  = strings.truncate_to_byte(line, '#')
		line  = strings.truncate_to_byte(line, ';')
		line  = strings.truncate_to_byte(line, '/')

		// TODO: verify label
		parse_label: if colon_index := strings.index_byte(line, ':'); colon_index != -1 {
			if uint(strings.index_byte(line, '"')) < uint(colon_index) {
				break parse_label
			}

			if line[:colon_index] in ctx.labels {
				errorf(ctx, "Duplicate label declaration: `%s`", line[:colon_index], severity = .Warning)
			}
			ctx.labels[line[:colon_index]] = {
				section = len(ctx.sections),
				offset  = u32(ctx.offset),
			}

			line = strings.trim_left_space(line[colon_index + 1:])
		}

		if len(line) == 0 {
			continue
		}

		// handle directives
		if line[0] == '.' {
			line = line[1:]
			if len(line) == 0 {
				error(ctx, "Expected directive following '.'")
				continue
			}

			directive_len := min(
				uint(strings.index_byte(line, ' ')),
				uint(strings.index_byte(line, '\t')),
				uint(len(line)),
			)
			directive := line[:directive_len]
			line      := strings.trim_left_space(line[directive_len:])

			parse_integers_to_data_section :: proc(ctx: ^Parsing_Context, line, directive: string, bits: uint) {
				if ctx.section_type == .Text {
					errorf(ctx, ".%s directive can not be used in .text section", directive)
					return
				}

				line := strings.trim_right_space(line)
				for {
					arg_len := min(
						uint(strings.index_byte(line, ' ')),
						uint(strings.index_byte(line, ',')),
						uint(strings.index_byte(line, '\t')),
						uint(len(line)),
					)
					arg := line[:arg_len]
					line = strings.trim_left_space(line[arg_len:])
					if ('a' <= arg[0] && arg[0] <= 'z') || ('A' <= arg[0] && arg[0] <= 'Z') || arg[0] == '_' {
						// TODO: verify label
						append(&ctx.relocations, Relocation {
							location = {
								offset  = u32(ctx.offset),
								section = len(ctx.sections),
							},
							label    = arg,
							line     = ctx.line,
							type     = .Absolute_32,
						})

						zero: u32
						bytes.buffer_write_ptr(&ctx.data_buffer, &zero, size_of(zero))
						ctx.offset += 4
					} else {
						val, ok := strconv.parse_i128(arg)
						if !ok || val > (1 << bits - 1) || val < -(1 << (bits - 1)) {
							errorf(ctx, "Failed to parse argument to %s directive as %d bit integer: `%s`", directive, bits, arg)
							break
						}

						n:   int
						err: io.Error
						switch bits {
						case 8:
							val_i8  := i8(val)
							n, err   = bytes.buffer_write_ptr(&ctx.data_buffer, &val_i8,  size_of(val_i8))
						case 16:
							val_i16 := i16(val)
							n, err   = bytes.buffer_write_ptr(&ctx.data_buffer, &val_i16, size_of(val_i16))
						case 32:
							val_i32 := i32(val)
							n, err   = bytes.buffer_write_ptr(&ctx.data_buffer, &val_i32, size_of(val_i32))
						case 64:
							val_i64 := i64(val)
							n, err   = bytes.buffer_write_ptr(&ctx.data_buffer, &val_i64, size_of(val_i64))
						case:
							unreachable()
						}
						assert(err == nil)
						ctx.offset += n
					}

					if len(line) == 0 {
						break
					}
					if line[0] != ',' {
						errorf(ctx, "Expected comma after argument got: %s", line[0])
						break
					}
					line = line[1:]
					line = strings.trim_left_space(line)
				}
			}

			new_section_type: Maybe(Section_Type)
			switch directive {
			case "globl":
			case "org":
				arg        := strings.trim_right_space(line)
				offset, ok := strconv.parse_uint(arg)
				if ok {
					ctx.section_offset = int(offset)
				} else {
					errorf(ctx, "Failed to parse argument to .org directive: `%s`", arg)
				}

			case "equ":
				name_len  := strings.index_byte(line, ',')
				if name_len == -1 {
					errorf(ctx, "Expected .equ to be of the form `.equ NAME, VALUE`, but got: `%s`", line)
					break
				}
				name      := strings.trim_right_space(line[:name_len])
				line      := strings.trim_space(line[name_len + 1:])
				value, ok := strconv.parse_int(line)
				if ok {
					if name in ctx.constants {
						errorf(ctx, "Redifinition of constant `%s` shadows previous definition", name, severity = .Warning)
					}
					ctx.constants[name] = value
				} else {
					errorf(ctx, "Failed to parse value in .equ directive: `%s`", line)
				}

			case "text":
				new_section_type = .Text
			case "data":
				new_section_type = .Data
			case "rodata":
				new_section_type = .Rodata

			case "string", "ascii", "asciz":
				if ctx.section_type == .Text {
					errorf(ctx, ".%s directive can not be used in .text section", directive)
					continue
				}
				arg := strings.trim_space(line)
				if len(arg) < 2 {
					errorf(ctx, "Invalid argument to .ascii directive: `%s`", arg)
					continue
				}

				if arg[0] != '"' || arg[len(arg) - 1] != '"' {
					errorf(ctx, "Invalid argument to .ascii directive: `%s`", arg)
					continue
				}

				n: int
				for i := 1; i < len(arg) - 1; i += 1 {
					switch arg[i] {
					case '\\':
						i += 1
						value: u8
						switch arg[i] {
						case '\\':
							value = '\\'
						case 'n':
							value = '\n'
						case 'r':
							value = '\r'
						case 't':
							value = '\t'
						case '0':
							value = 0
						case:
							errorf(ctx, "Unknown escape character: `%v`", arg[i])
							continue lines_loop
						}
						bytes.buffer_write_byte(&ctx.data_buffer, value)
						n += 1
					case '"':
						errorf(ctx, "Invalid argument to .ascii directive: `%s`", arg)
						continue lines_loop
					case:
						bytes.buffer_write_byte(&ctx.data_buffer, arg[i])
						n += 1
					}
				}

				if directive != "ascii" {
					bytes.buffer_write_byte(&ctx.data_buffer, 0)
					n += 1
				}
				ctx.offset += n

			case "quad", "8byte", "dword":
				parse_integers_to_data_section(ctx, line, directive, 64)
			case "word", "4byte", "long":
				parse_integers_to_data_section(ctx, line, directive, 32)
			case "half", "2byte", "short":
				parse_integers_to_data_section(ctx, line, directive, 16)
			case "byte":
				parse_integers_to_data_section(ctx, line, directive,  8)

			case "zero":
				if ctx.section_type == .Text {
					errorf(ctx, ".%s directive can not be used in .text section", directive)
				}

				arg   := strings.trim_right_space(line)
				n, ok := strconv.parse_uint(arg)
				if ok {
					for _ in 0 ..< n {
						bytes.buffer_write_byte(&ctx.data_buffer, 0)
					}
					ctx.offset += int(n)
				} else {
					errorf(ctx, "Failed to parse argument to .zero directive: `%s`", arg)
				}

			case:
				errorf(ctx, "Unknown directive: '.%s'", directive)
			}

			if new_section_type, ok := new_section_type.?; ok {
				end_section(ctx)
				ctx.section_type = new_section_type
			}
			
			continue
		}

		if ctx.section_type != .Text {
			errorf(
				ctx,
				"Expected label or directive in .%s section, got: `%s`",
				section_type_names[ctx.section_type],
				line,
			)
			continue
		}

		mnemonic_len := strings.index_any(line, " \t")
		if mnemonic_len == -1 {
			mnemonic_len = len(line)
		}

		mnemonic := line[:mnemonic_len]
		line      = line[mnemonic_len:]
		line      = strings.trim_left_space(line)

		instruction_info: ^Instruction_Info
		mnemonic_enum:     Mnemonic
		for &info, m in instruction_infos {
			if info.mnemonic == mnemonic {
				instruction_info = &info
				mnemonic_enum    = m
				break
			}
		}

		if instruction_info != nil {
			write_instruction(ctx, {
				mnemonic = mnemonic_enum,
				args     = parse_args(ctx, line, instruction_info.args),
			})
			continue
		}

		pseudo:         ^Pseudo_Instruction_Info
		pseudo_mnemonic: Pseudo_Instruction_Mnemonic
		for &pi, p in pseudo_instruction_infos {
			if pi.mnemonic == mnemonic {
				pseudo_mnemonic = p
				pseudo          = &pi
				break
			}
		}

		if pseudo != nil {
			args := parse_args(ctx, line, pseudo.args)

			switch pseudo_mnemonic {
			case .Nop:
				write_instruction(ctx, {
					mnemonic = .Add,
					args     = {
						rd  = .Zero,
						rs1 = .Zero,
						rs2 = .Zero,
					},
				})
			case .La:
				write_instruction(ctx, {
					mnemonic = .Lui,
					args     = {
						rd  = args.rd,
						rs1 = .Zero,
						imm = 0,
					},
				})
				write_instruction(ctx, {
					mnemonic = .Addi,
					args     = {
						rd  = args.rd,
						rs1 = args.rd,
						imm = 0,
					},
				})
			case .Li:
				if args.imm == (args.imm << 20) >> 20 {
					write_instruction(ctx, {
						mnemonic = .Addi,
						args     = {
							rd  = args.rd,
							rs1 = .Zero,
							imm = args.imm,
						},
					})
				} else {
					write_instruction(ctx, {
						mnemonic = .Lui,
						args     = {
							rd  = args.rd,
							imm = (args.imm + 0x800) >> 12,
						},
					})
					write_instruction(ctx, {
						mnemonic = .Addi,
						args     = {
							rd  = args.rd,
							rs1 = args.rd,
							imm = args.imm & 0xFFF,
						},
					})
				}
			case .Jr:
				write_instruction(ctx, {
					mnemonic = .Jalr,
					args     = {
						rd  = .Zero,
						rs1 = args.rs1,
						imm = args.imm,
					},
				})
			case .Mv:
				// add rd, rs1, x0
				write_instruction(ctx, {
					mnemonic = .Add,
					args     = {
						rd  = args.rd,
						rs1 = args.rs1,
						rs2 = .Zero,
					},
				})
			case .Not:
				// xori rd, rs1, -1
				write_instruction(ctx, {
					mnemonic = .Xori,
					args     = {
						rd  = args.rd,
						rs1 = args.rs1,
						imm = -1,
					},
				})

			case .J:
				write_instruction(ctx, {
					mnemonic = .Jal,
					args     = {
						rd  = .Zero,
						imm = args.imm,
					},
				})
			case .Call:
				write_instruction(ctx, {
					mnemonic = .Jal,
					args     = {
						rd  = .Ra,
						imm = args.imm,
					},
				})
			case .Ret:
				write_instruction(ctx, {
					mnemonic = .Jalr,
					args     = {
						rd  = .Zero,
						rs1 = .Ra,
						imm = 0,
					},
				})

			case .Bnez:
				write_instruction(ctx, {
					mnemonic = .Bne,
					args     = {
						rs1 = args.rs1,
						rs2 = .Zero,
						imm = args.imm,
					},
				})
			case .Beqz:
				write_instruction(ctx, {
					mnemonic = .Beq,
					args     = {
						rs1 = args.rs1,
						rs2 = .Zero,
						imm = args.imm,
					},
				})

			case .Bgt:
				write_instruction(ctx, {
					mnemonic = .Blt,
					args     = {
						rs1 = args.rs2,
						rs2 = args.rs1,
						imm = args.imm,
					},
				})
			case .Bgtu:
				write_instruction(ctx, {
					mnemonic = .Bltu,
					args     = {
						rs1 = args.rs2,
						rs2 = args.rs1,
						imm = args.imm,
					},
				})
			case .Ble:
				write_instruction(ctx, {
					mnemonic = .Bge,
					args     = {
						rs1 = args.rs2,
						rs2 = args.rs1,
						imm = args.imm,
					},
				})
			case .Bleu:
				write_instruction(ctx, {
					mnemonic = .Bgeu,
					args     = {
						rs1 = args.rs2,
						rs2 = args.rs1,
						imm = args.imm,
					},
				})
			}
			continue
		}

		errorf(ctx, "Unknown mnemonic: `%s`", mnemonic)

		parse_args :: proc(ctx: ^Parsing_Context, line: string, arg_types: []Instruction_Arg) -> (args: Instruction_Args) {
			line := line

			parse_arg :: proc(ctx: ^Parsing_Context, str: ^string, type: Instruction_Arg) -> (value: i32) {
				min_value, max_value: int
				register:             bool
				address:              bool
				even:                 bool
				relocation_type:      Relocation_Type

				switch type {
				case .Imm12, .Off12:
					max_value =  (1 << 11) - 1
					min_value = -(1 << 11)

				case .Rel12:
					max_value       = ( (1 << 11) - 1) << 1
					min_value       = (-(1 << 11)    ) << 1
					address         = true
					even            = true
					relocation_type = .Relative_12

				case .Imm20:
					max_value =  (1 << 19) - 1
					min_value = -(1 << 19)

				case .Rel20:
					max_value        = ( (1 << 19) - 1) << 1
					min_value        = (-(1 << 19)    ) << 1
					address          = true
					even             = true
					relocation_type  = .Relative_20

				case .Uimm20:
					max_value = (1 << 20) - 1
					min_value = 0

				case .Uimm5:
					max_value = (1 << 5) - 1
					min_value = 0
					max_value = (1 << 12) - 1

				case .Imm:
					min_value = int(min(i32))
					max_value = int(max(u32))

				case .Rel:
					min_value       = int(min(i32))
					max_value       = int(max(i32))
					address         = true
					even            = true
					relocation_type = .Relative_20_12

				case .Addr:
					min_value       = 0
					max_value       = int(max(u32))
					address         = true
					relocation_type = .Absolute_20_12

				case .Rd, .Rs1, .Rs2:
					register  = true
					min_value = 0
					max_value = 31
				}

				arg_len := min(
					uint(strings.index_byte(str^, ',' )),
					uint(strings.index_byte(str^, ' ' )),
					uint(strings.index_byte(str^, '\t')),
					uint(strings.index_byte(str^, '(' )),
					uint(strings.index_byte(str^, ')' )),
					uint(len(str^)),
				)

				if v, ok := ctx.constants[str[:arg_len]]; ok {
					if v < min_value || v > max_value || (v % 2 == 1 && even) {
						errorf(ctx, "Immediate value not representable: %s=%d (%d ..= %d)", str[:arg_len], v, min_value, max_value)
					}
					str^ = str[arg_len:]
					return i32(v)
				}

				if !register && str[0] == '\'' {
					if len(str) < 3 {
						errorf(ctx, "Invalid immediate value: `%s`", str)
						return 0
					}

					r, n := utf8.decode_rune_in_string(str[1:])
					if r == utf8.RUNE_ERROR {
						errorf(ctx, "Invalid immediate value: `%s`", str)
						return 0
					}

					if r == '\\' {
						v: i32
						switch str[2] {
						case 'n':
							v = '\n'
						case 'r':
							v = '\r'
						case 't':
							v = '\t'
						case '\\':
							v = '\\'
						case:
							errorf(ctx, "Invalid immediate value: `%s`", str)
							return 0
						}
						str^ = str[4:]
						return v
					}
					
					if len(str) < 2 + n || str[1 + n] != '\'' {
						errorf(ctx, "Invalid immediate value: `%s`")
						return 0
					}

					str^ = str[2 + n:]

					return i32(r)
				}

				arg := str[:arg_len]
				num := arg
				str^ = str[arg_len:]

				if address && (
					'a' <= arg[0] && arg[0] <= 'z' ||
					'A' <= arg[0] && arg[0] <= 'Z' ||
					arg[0] == '_'
				) {
					append(&ctx.relocations, Relocation {
						location = {
							offset  = u32(ctx.offset),
							section = len(ctx.sections),
						},
						label    = arg,
						line     = ctx.line,
						type     = relocation_type,
					})
					return 0
				}

				if register {
					if reg, ok := register_aliases[arg]; ok {
						return i32(reg)
					}

					if arg[0] != 'x' {
						errorf(ctx, "Invalid register name: `%s`", arg)
						return 0
					}
					num = arg[1:]
				}

				v, ok := strconv.parse_int(num, register ? 10 : 0)

				if !ok {
					if register {
						errorf(ctx, "Invalid register name: `%s`", arg)
						return 0
					} else {
						errorf(ctx, "Invalid immediate value: `%s`", arg)
						return 0
					}
				}

				if v < min_value || v > max_value || (v % 2 == 1 && even) {
					if register {
						errorf(ctx, "Invalid register name: `%s`", arg)
						return 0
					} else {
						errorf(ctx, "Immediate value not representable: %d (%d ..= %d)", v, min_value, max_value)
						return 0
					}
				}
			
				return i32(v)
			}

			offset: bool
			i := 0
			for i < len(arg_types) {
				if len(line) == 0 {
					append(&ctx.errors, Error {
						line    = ctx.line,
						message = "Not enough arguments",
					})
					break
				}

				v := parse_arg(ctx, &line, arg_types[i])

				switch arg_types[i] {
				case .Imm12, .Imm20, .Uimm5, .Off12, .Uimm20, .Rel12, .Rel20, .Imm, .Rel, .Addr:
					args.imm = i32(v)
				case .Rd:
					args.rd  = Register(v)
				case .Rs1:
					args.rs1 = Register(v)
				case .Rs2:
					args.rs2 = Register(v)
				}

				line = strings.trim_left_space(line)

				if len(line) != 0 {
					if offset {
						if line[0] != ')' {
							append(&ctx.errors, Error {
								line    = ctx.line,
								message = "Expected offset to be of the form 'offset(register)'",
							})
						} else {
							line = line[1:]
						}
					} else if arg_types[i] == .Off12 {
						if line[0] != '(' {
							append(&ctx.errors, Error {
								line    = ctx.line,
								message = "Expected offset to be of the form 'offset(register)'",
							})
						} else {
							line = line[1:]
						}
					} else {
						if len(line) != 0 {
							if line[0] != ',' {
								append(&ctx.errors, Error {
									line    = ctx.line,
									message = "Expected a comma after an argument",
								})
							}
							line = line[1:]
						}
					}

					line   = strings.trim_left_space(line)
					offset = arg_types[i] == .Off12
				}

				i += 1
			}

			return args
		}
	}
	end_section(ctx)

	sorted_sections := slice.clone(ctx.sections[:], context.temp_allocator)
	slice.sort_by(sorted_sections, proc(a, b: Section) -> bool {
		return a.offset < b.offset
	})

	for i in 0 ..< len(sorted_sections) - 1 {
		if int(sorted_sections[i].offset) + sorted_sections[i].len > int(sorted_sections[i + 1].offset) {
			ctx.line = sorted_sections[i + 1].line_start
			errorf(
				ctx,
				"Collision between .%v section starting at %#x and .%v section starting at %#x",
				section_type_names[sorted_sections[i].type],
				sorted_sections[i].offset,
				section_type_names[sorted_sections[i + 1].type],
				sorted_sections[i + 1].offset,
			)
		}
	}

	return ctx.sections[:], ctx.relocations[:], ctx.labels, ctx.errors[:]
}

@(require_results)
assemble_instruction :: proc(instruction: Instruction) -> u32 {
	info := instruction_infos[instruction.mnemonic]

	ret := u32(info.opcode)

	switch info.type {
	case .R:
		ret |= u32(instruction.rd)  << 7
		ret |= u32(info.funct3)     << 12
		ret |= u32(instruction.rs1) << 15
		ret |= u32(instruction.rs2) << 20
		ret |= u32(info.funct7)     << 25
	case .I:
		ret |= u32(instruction.rd)  << 7
		ret |= u32(info.funct3)     << 12
		ret |= u32(instruction.rs1) << 15
		ret |= u32(instruction.imm) << 20
	case .T:
		ret |= u32(instruction.rd)  << 7
		ret |= u32(info.funct3)     << 12
		ret |= u32(instruction.rs1) << 15
		ret |= u32(instruction.imm) << 20
		ret |= u32(info.funct7)     << 25
	case .S:
		ret |= u32(instruction.imm & 0x1F) << 7
		ret |= u32(info.funct3)            << 12
		ret |= u32(instruction.rs1)        << 15
		ret |= u32(instruction.rs2)        << 20
		ret |= u32(instruction.imm >> 5)   << 25
	case .B:
		ret = u32(B_Type_Instruction{
			opcode   = info.opcode,
			imm_11   = u8(instruction.imm >> 11),
			imm_1_4  = u8(instruction.imm >> 1),
			funct3   = info.funct3,
			rs1      = instruction.rs1,
			rs2      = instruction.rs2,
			imm_5_10 = u8(instruction.imm >> 5),
			imm_12   = i8(instruction.imm >> 12),
		})
	case .U:
		ret |= u32(instruction.rd)  << 7
		ret |= u32(instruction.imm) << 12
	case .J:
		ret |= u32(instruction.rd)                 << 7
		ret |= u32(instruction.imm  >> 12 & 0xFF)  << 12
		ret |= u32(instruction.imm  >> 11 & 1)     << 20
		ret |= u32(instruction.imm  >> 1  & 0x3FF) << 21
		ret |= u32(instruction.imm  >> 20 & 1)     << 31
	case .E:
		ret |= u32(info.funct12) << 20
	}

	return ret
}

@(require_results)
assemble_instructions :: proc(instructions: []Instruction, allocator := context.allocator) -> []u32 {
	output := make([]u32, len(instructions), allocator)

	for inst, i in instructions {
		output[i] = assemble_instruction(inst)
	}
	
	return output
}

@(require_results)
disassemble_instruction :: proc(data: u32) -> (inst: Instruction, ok: bool) {
	opcode := u8(data & 0x7F)

	funct3  := u8(data >> 12 & 0x7)
	funct7  := u8(data >> 25)
	funct12 := u16(data >> 20)

	info: ^Instruction_Info
	for &i, m in instruction_infos {
		if i.opcode != opcode {
			continue
		}

		cond: bool
		switch i.type {
		case .R, .T:
			cond = i.funct3 == funct3 && i.funct7 == funct7
		case .I, .S, .B:
			cond = i.funct3 == funct3
		case .U:
			cond = true
		case .J:
			cond = true
		case .E:
			cond = i.funct12 == funct12
		}

		if cond {
			inst.mnemonic = m
			info          = &i
			inst.type     = i.type
			break
		}
	}

	if info == nil {
		return
	}

	switch info.type {
	case .R:
		r := R_Type_Instruction(data)
		inst.rd  = r.rd
		inst.rs1 = r.rs1
		inst.rs2 = r.rs2
	case .I:
		inst.rd  = Register(data >> 7 & 0x1F)
		inst.rs1 = Register(data >> 15 & 0x1F)
		inst.imm = i32(data) >> 20
	case .T:
		inst.rd  = Register(data >> 7 & 0x1F)
		inst.rs1 = Register(data >> 15 & 0x1F)
		inst.imm = (i32(data) >> 20) & 0x1F
	case .S:
		s := S_Type_Instruction(data)
		inst.rs1 = s.rs1
		inst.rs2 = s.rs2
		inst.imm = i32(s.imm_5_11) << 5 | i32(s.imm_0_4)
	case .B:
		b := B_Type_Instruction(data)
		inst.rs1 = b.rs1
		inst.rs2 = b.rs2
		inst.imm = i32(b.imm_12)   << 12 |
		           i32(b.imm_11)   << 11 |
		           i32(b.imm_5_10) << 5  |
		           i32(b.imm_1_4)  << 1
	case .U:
		inst.rd  = Register(data >> 7 & 0x1F)
		inst.imm = i32(data >> 12)
	case .J:
		j := J_Type_Instruction(data)
		inst.rd = j.rd
		inst.imm = i32(j.imm_20)    << 20 |
		           i32(j.imm_12_19) << 12 |
		           i32(j.imm_11)    << 11 |
		           i32(j.imm_1_10)  << 1
	case .E:
	}

	ok = true
	return
}

print_instruction :: proc(
	w:           io.Writer,
	instruction: Instruction,
	nice_register_names := false,
	syntax_highlighting := false,
) -> (n: int) {
	info   := instruction_infos[instruction.mnemonic]
	offset := false
	if syntax_highlighting {
		n += fmt.wprint(w, ansi.CSI + ansi.FG_BLUE + ansi.SGR)
	}
	n += fmt.wprintf(w, "%s", info.mnemonic)
	if len(info.args) != 0 {
		n += fmt.wprint(w, ' ')
	}
	if syntax_highlighting {
		n += fmt.wprint(w, ansi.CSI + ansi.RESET + ansi.SGR)
	}
	for arg, i in info.args {
		if i != 0 && !offset {
			n += fmt.wprint(w, ", ")
		}
		reg: Maybe(Register)
		switch arg {
		case .Imm12, .Imm20, .Uimm5, .Uimm20, .Rel12, .Rel20, .Addr:
			if syntax_highlighting {
				n += fmt.wprint(w, ansi.CSI + ansi.FG_RED + ansi.SGR)
			}
			n += fmt.wprintf(w, "%#x", instruction.imm)
		case .Off12:
			if syntax_highlighting {
				n += fmt.wprintf(
					w,
					ansi.CSI + ansi.FG_RED + ansi.SGR +
					"%#x" +
					ansi.CSI + ansi.RESET  + ansi.SGR +
					"(",
					instruction.imm,
				)
			} else {
				n += fmt.wprintf(w, "%#x(", instruction.imm)
			}
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
			if nice_register_names {
				n += fmt.wprint(w, register_names[reg])
			} else {
				n += fmt.wprintf(w, "x%d", int(reg))
			}
		}

		if arg != .Off12 && offset {
			n     += fmt.wprintf(w, ")")
			offset = false
		}

		if syntax_highlighting {
			n += fmt.wprint(w, ansi.CSI + ansi.RESET + ansi.SGR)
		}
	}

	return
}

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
