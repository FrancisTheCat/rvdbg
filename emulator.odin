package rvdbg

import "base:intrinsics"

import "core:io"
import "core:slice"

CPU :: struct {
	registers:         [Register]u32,
	mem:               []byte    `fmt:"-"`,
	pc:                u32       `fmt:"x"`,
	stdout:            io.Writer `fmt:"-"`,
	registers_written: bit_set[Register],
	registers_read:    bit_set[Register],
	last_instruction:  Instruction,
}

CPU_State :: enum {
	Running,
	Ebreak,
	Invalid_Instruction,
	Trivial_Loop,

	Debugger_Breakpoint,
	Debugger_Paused,
}

cpu_init :: proc(cpu: ^CPU, mem: []byte, stdout: io.Writer) {
	cpu^ = {
		mem    = mem,
		stdout = stdout,
	}
}

cpu_load_sections :: proc(cpu: ^CPU, sections: []Section) {
	for section in sections {
		switch section.type {
		case .Text:
			assembled := assemble_instructions(section.data.?, context.temp_allocator)
			copy(slice.reinterpret([]u32, cpu.mem[section.offset:]), assembled)
		case .Data, .Rodata:
			copy(cpu.mem[section.offset:], section.data.([]byte))
		}
	}
}

execute_instruction :: proc(cpu: ^CPU) -> CPU_State {
	inst, ok := disassemble_instruction(intrinsics.unaligned_load(cast(^u32)&cpu.mem[cpu.pc]))
	if !ok {
		return .Invalid_Instruction
	}
	cpu.last_instruction = inst
	cpu.pc              += 4

	defer cpu.registers[.Zero] = 0

	switch inst.type {
	case .R, .B:
		cpu.registers_read    = { inst.rs1, inst.rs2, }
		cpu.registers_written = { inst.rd, }
	case .S:
		cpu.registers_read    = { inst.rs1, inst.rs2, }
		cpu.registers_written = {}
	case .I:
		cpu.registers_read    = { inst.rs1, }
		cpu.registers_written = { inst.rd, }
	case .U, .J:
		cpu.registers_read    = {}
		cpu.registers_written = { inst.rd, }
	case .T:
		cpu.registers_read    = { inst.rs1, }
		cpu.registers_written = { inst.rd, }
	case .E:
		cpu.registers_read    = {}
		cpu.registers_written = {}
	}

	store_address: u32
	store_size:    u32

	switch inst.mnemonic {
	case .Addi:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] + u32(inst.imm)
	case .Slti:
		cpu.registers[inst.rd] = u32(i32(cpu.registers[inst.rs1]) < inst.imm)
	case .Sltiu:
		cpu.registers[inst.rd] = u32(cpu.registers[inst.rs1] < u32(inst.imm))
	case .Andi:
		cpu.registers[inst.rd] = u32(cpu.registers[inst.rs1] & u32(inst.imm))
	case .Ori:
		cpu.registers[inst.rd] = u32(cpu.registers[inst.rs1] | u32(inst.imm))
	case .Xori:
		cpu.registers[inst.rd] = u32(cpu.registers[inst.rs1] ~ u32(inst.imm))
	case .Slli:
		cpu.registers[inst.rd] = u32(cpu.registers[inst.rs1] << u32(inst.imm))
	case .Srli:
		cpu.registers[inst.rd] = u32(cpu.registers[inst.rs1] >> u32(inst.imm))
	case .Srai:
		cpu.registers[inst.rd] = u32(i32(cpu.registers[inst.rs1]) >> u32(inst.imm))

	case .Lui:
		cpu.registers[inst.rd] = u32(inst.imm) << 12
	case .Auipc:
		cpu.registers[inst.rd] = cpu.pc - 4 + u32(inst.imm) << 12

	case .Add:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] + cpu.registers[inst.rs2]
	case .Sub:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] - cpu.registers[inst.rs2]
	case .Slt:
		cpu.registers[inst.rd] = u32(i32(cpu.registers[inst.rs1]) < i32(cpu.registers[inst.rs2]))
	case .Sltu:
		cpu.registers[inst.rd] = u32(cpu.registers[inst.rs1] < cpu.registers[inst.rs2])
	case .And:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] & cpu.registers[inst.rs2]
	case .Or:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] | cpu.registers[inst.rs2]
	case .Xor:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] ~ cpu.registers[inst.rs2]
	case .Sll:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] << cpu.registers[inst.rs2]
	case .Srl:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] >> cpu.registers[inst.rs2]
	case .Sra:
		cpu.registers[inst.rd] = u32(i32(cpu.registers[inst.rs1]) >> cpu.registers[inst.rs2])

	case .Jal:
		cpu.registers[inst.rd] = cpu.pc
		cpu.pc                += u32(inst.imm) - 4
	case .Jalr:
		cpu.registers[inst.rd] = cpu.pc
		cpu.pc                 = u32(inst.imm) + cpu.registers[inst.rs1]
	case .Beq, .Bne, .Blt, .Bltu, .Bge, .Bgeu:
		cond: bool
		#partial switch inst.mnemonic {
		case .Beq:
			cond = cpu.registers[inst.rs1]      == cpu.registers[inst.rs2]
		case .Bne:
			cond = cpu.registers[inst.rs1]      != cpu.registers[inst.rs2]
		case .Blt:
			cond = i32(cpu.registers[inst.rs1]) <  i32(cpu.registers[inst.rs2])
		case .Bltu:
			cond = cpu.registers[inst.rs1]      <  cpu.registers[inst.rs2]
		case .Bge:
			cond = i32(cpu.registers[inst.rs1]) >= i32(cpu.registers[inst.rs2])
		case .Bgeu:
			cond = cpu.registers[inst.rs1]      >= cpu.registers[inst.rs2]
		}
		if cond {
			cpu.pc += u32(inst.imm) - 4
		}

	case .Lw:
		cpu.registers[inst.rd] =     intrinsics.unaligned_load(cast(^u32)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)])
	case .Lh:
		cpu.registers[inst.rd] = u32(intrinsics.unaligned_load(cast(^i16)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)]))
	case .Lhu:
		cpu.registers[inst.rd] = u32(intrinsics.unaligned_load(cast(^u16)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)]))
	case .Lb:
		cpu.registers[inst.rd] = u32(intrinsics.unaligned_load(cast(^ i8)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)]))
	case .Lbu:
		cpu.registers[inst.rd] = u32(intrinsics.unaligned_load(cast(^ u8)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)]))

	case .Sw:
		intrinsics.unaligned_store(cast(^u32)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)], u32(cpu.registers[inst.rs2]))
		store_address = cpu.registers[inst.rs1] + u32(inst.imm)
		store_size    = size_of(u32)
	case .Sh:
		intrinsics.unaligned_store(cast(^u16)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)], u16(cpu.registers[inst.rs2]))
		store_address = cpu.registers[inst.rs1] + u32(inst.imm)
		store_size    = size_of(u16)
	case .Sb:
		intrinsics.unaligned_store(cast(^ u8)&cpu.mem[cpu.registers[inst.rs1] + u32(inst.imm)],  u8(cpu.registers[inst.rs2]))
		store_address = cpu.registers[inst.rs1] + u32(inst.imm)
		store_size    = size_of(u8)

	case .Ecall:
		return .Invalid_Instruction
	case .Ebreak:
		return .Ebreak

	case .Mul:
		cpu.registers[inst.rd] = cpu.registers[inst.rs1] * cpu.registers[inst.rs2]
	case .Mulh:
		cpu.registers[inst.rd] = u32((i64(i32(cpu.registers[inst.rs1])) * i64(i32(cpu.registers[inst.rs2]))) >> 32)
	case .Mulhu:
		cpu.registers[inst.rd] = u32((u64(cpu.registers[inst.rs1]) * u64(cpu.registers[inst.rs2])) >> 32)
	case .Mulhsu:
		cpu.registers[inst.rd] = u32((i64(i32(cpu.registers[inst.rs1])) * i64(cpu.registers[inst.rs2])) >> 32)

	case .Div:
		if cpu.registers[inst.rs2] == 0 {
			cpu.registers[inst.rd] = transmute(u32)i32(-1)
		} else {
			cpu.registers[inst.rd] = u32(i32(cpu.registers[inst.rs1]) / i32(cpu.registers[inst.rs2]))
		}
	case .Divu:
		if cpu.registers[inst.rs2] == 0 {
			cpu.registers[inst.rd] = ~u32(0)
		} else {
			cpu.registers[inst.rd] = cpu.registers[inst.rs1] / cpu.registers[inst.rs2]
		}
	case .Rem:
		if cpu.registers[inst.rs2] == 0 {
			cpu.registers[inst.rd] = 1
		} else {
			cpu.registers[inst.rd] = u32(i32(cpu.registers[inst.rs1]) % abs(i32(cpu.registers[inst.rs2])))
		}
	case .Remu:
		if cpu.registers[inst.rs2] == 0 {
			cpu.registers[inst.rd] = 1
		} else {
			cpu.registers[inst.rd] = cpu.registers[inst.rs1] % cpu.registers[inst.rs2]
		}
	}

	TERMINAL_ADDRESS :: 0xFFFF_FFFF
	if store_address <= TERMINAL_ADDRESS && TERMINAL_ADDRESS <= u64(store_address) + u64(store_size) {
		io.write_byte(cpu.stdout, cpu.mem[TERMINAL_ADDRESS])
	}

	SERIAL_PORT_BASE :: 0xFFFFC000
	SERP_TX_ST_REG   :: SERIAL_PORT_BASE + 0x0008
	SERP_TX_DATA_REG :: SERIAL_PORT_BASE + 0x000C

	if store_address <= SERP_TX_DATA_REG && SERP_TX_DATA_REG <= u64(store_address) + u64(store_size) {
		io.write_rune(cpu.stdout, (^rune)(&cpu.mem[SERP_TX_DATA_REG])^)
	}
	cpu.mem[SERP_TX_ST_REG] = 1 // ready
	
	return .Running
}
