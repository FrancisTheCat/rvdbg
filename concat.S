#pragma qtrvsim show registers
#pragma qtrvsim show program
#pragma qtrvsim show memory
#pragma qtrvsim focus memory 0x1000
# .globl _start
.equ SERIAL_PORT_BASE,      0xffffc000
.equ SERP_TX_ST_REG_o,          0x0008
.equ SERP_TX_DATA_REG_o,        0x000c

.data
.org 0x800

string_one:
  .byte 4
  .ascii "one "

string_two:
  .byte 4
  .ascii "two "

string_three:
  .byte 6
  .ascii "three "

string_four:
  .byte 5
  .ascii "four "

string_five:
  .byte 5
  .ascii "five "

string_six:
  .byte 4
  .ascii "six "

string_seven:
  .byte 6
  .ascii "seven "

string_eight:
  .byte 6
  .ascii "eight "

string_nine:
  .byte 5
  .ascii "nine "

string_yarn:
  .byte 15
  .ascii "ball(s) of yarn"

string_cat:
  .byte 6
  .ascii "cat(s)"

string_box:
  .byte 7
  .ascii "box(es)"

string_containing:
  .byte 12
  .ascii " containing "

string_next_to:
  .byte 9
  .ascii " next to "

test:
   .ascii "[[]][]"

concat_string:
    # .asciz "[]"
# concat_string:
    .asciz "2[8@+1cat]+[cat+@]+9[9@+1cat]+2[2[[]+[]]]+2[]"


.text
.org 0x200
_start:


# ----------------- Stub to test functions in QtRVSim -----------------
    # These lines are not executed by the Artemis tester.
    # Feel free to adjust values and the function for testing.

    li sp, 0x100000
    la a0, concat_string
    call print_concat

    ebreak  # stop execution in QtRVSim to inspect the result
# -------------- End of stub to test functions in QtRVSim -------------



# ------------------------------ print_character -------------------------------
# Prints a character to QtRVSim's serial port. Adapted from QtRVSim's
# `template.S`.

# first (and only) argument: character to print.
print_character:
    li t0, SERIAL_PORT_BASE

tx_busy:
    lw   t1, SERP_TX_ST_REG_o(t0)   // read status of transmitter
    andi t1, t1, 0x1                // mask ready bit
    beq  t1, zero, tx_busy          // continue only if ready

    sw   a0, SERP_TX_DATA_REG_o(t0)   // write character to Tx data register
    ret


# -------------------------------- print_string --------------------------------

# first (and only) argument: pascal string to print
print_string:
    # t0: cursor
    # t1: end
    # a0: char
    
    addi sp, sp, -0x10
    sw   ra, 0(sp)
    addi t0, a0, 1
    lb   t1, 0(a0)
	bne  t1, x0, print_string_nz
	lw   ra, 0(sp)
	addi sp, sp, 0x10
	ret
	
print_string_nz:
    add  t1, t1, t0

print_string_loop:
    lb   a0, 0(t0)
    sw   t0, 4(sp)
    sw   t1, 8(sp)
    call print_character
    lw   t0, 4(sp)
    lw   t1, 8(sp)
    addi t0, t0, 1
    bne  t0, t1, print_string_loop
    
    lw   ra, 0(sp)
    addi sp, sp, 0x10
    ret


# -------------------------------- print_digit ---------------------------------

# first (and only) argument: address of ASCII-encoded digit
# return value: address of next character
print_digit:
	addi  sp, sp, -0x10
	sw    ra, 0(sp)
	sw    a0, 4(sp)
	lb    t0, 0(a0)
	addi  t0, t0, -0x31 # -'1'
	li    t1, 12
	mul   t0, t0, t1
	auipc t1, 0
	addi  t1, t1, 16
	add   t0, t0, t1
	jr    0(t0)
	
	la    a0, string_one
	j     print_digit_end
	la    a0, string_two
	j     print_digit_end
	la    a0, string_three
	j     print_digit_end
	la    a0, string_four
	j     print_digit_end
	la    a0, string_five
	j     print_digit_end
	la    a0, string_six
	j     print_digit_end
	la    a0, string_seven
	j     print_digit_end
	la    a0, string_eight
	j     print_digit_end
	la    a0, string_nine
	j     print_digit_end
	
print_digit_end:
	call print_string
	lw    a0, 4(sp)
	addi  a0, a0, 1
	lw    ra, 0(sp)
	addi  sp, sp, 0x10
    ret


# ------------------------------- print_multiple -------------------------------

# first (and only) argument: address of first character of MULTIPLE-produced string
# return value: address of first character after MULTIPLE-produced string
print_multiple:
	addi sp, sp, -0x10
	sw   ra, 0(sp)
    call print_digit
    lw   ra, 0(sp)
    addi sp, sp, 0x10
    j   print_subject


# ------------------------------- print_subject --------------------------------

# first (and only) argument: address of first character of SUBJECT-produced string
# return value: address of first character after SUBJECT-produced string
print_subject:
    addi sp, sp, -0x10
    sw   ra, 0(sp)
    sw   a0, 4(sp)

    lb   t0, 0(a0)

    li   t1, 0x40
    bne  t0, t1, print_subject_n_yarn
    la   a0, string_yarn
    call print_string
    lw   ra, 0(sp)
    lw   a0, 4(sp)
    addi a0, a0, 1
    addi sp, sp, 0x10
    ret
print_subject_n_yarn:

    li   t1, 0x63
    bne  t0, t1, print_subject_n_cat
    la   a0, string_cat
    call print_string
    lw   ra, 0(sp)
    lw   a0, 4(sp)
    addi a0, a0, 3
    addi sp, sp, 0x10
    ret
print_subject_n_cat:

    li   t1, 0x5D
    lb   t0, 1(a0)
    bne  t0, t1, print_subject_nested
    la   a0, string_box
    call print_string
    lw   ra, 0(sp)
    lw   a0, 4(sp)
    addi a0, a0, 2
    addi sp, sp, 0x10
    ret

print_subject_nested:
    la   a0, string_box
    call  print_string
    la   a0, string_containing
    call  print_string
    
    lw   a0, 4(sp)
    addi a0, a0, 1
    call  print_concat
    addi a0, a0, 1

    lw   ra, 0(sp)
    addi sp, sp, 0x10
    ret

# -------------------------------- print_concat --------------------------------

# first (and only) argument: address of first character of CONCAT-produced string
# return value: address of first character after CONCAT-produced string 
print_concat:
	addi sp, sp, -0x10
	sw   ra, 0(sp)
	j    print_concat_start
	
print_concat_next:
	sw   a0, 4(sp)
	la   a0, string_next_to
	call  print_string
	lw   a0, 4(sp)
	
print_concat_start:
	lb   t0, 0(a0)
	
	li   t1, 0x30
	ble  t0, t1, print_concat_no_digit
	li   t1, 0x39
	bgt  t0, t1, print_concat_no_digit
	call print_multiple
	j print_concat_plus
	
print_concat_no_digit:
	call print_subject
	j print_concat_plus

print_concat_plus:
	lb   t0, 0(a0)
	li   t1, 0x2B
	addi a0, a0, 1
	beq  t0, t1, print_concat_next
	
	addi a0, a0, -1
	lw   ra, 0(sp)
	addi sp, sp, 0x10
    ret
    


# -----------------------------------strings------------------------------------

