package rvdbg

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:strings"

@(require_results)
_dialog_file_open :: proc(directory: bool, allocator: runtime.Allocator) -> (file: string, ok: bool) {
	command: [3]string = {
		"zenity",
		"--file-selection",
		"--directory",
	}
	n := 3 if directory else 2
	state, stdout, stderr, err := os.process_exec({
		command = command[:n],
	}, context.temp_allocator)

	if err != nil || !state.success {
		fmt.eprintln("Failed to open file dialog:", string(stderr))
		return
	}

	file = strings.clone(strings.trim_space(string(stdout)), allocator)
	ok   = true
	return
}

@(require_results)
_dialog_file_open_multiple :: proc(directory: bool, allocator: runtime.Allocator) -> (files: []string, ok: bool) {
	command: [4]string = {
		"zenity",
		"--file-selection",
		"--multiple",
		"--directory",
	}
	n := 4 if directory else 3
	state, stdout, stderr, err := os.process_exec({
		command = command[:n],
	}, context.temp_allocator)

	if err != nil || !state.success {
		fmt.eprintln("Failed to open file dialog:", string(stderr))
		return
	}

	files = strings.split(string(stdout), "|", allocator)
	for &file in files {
		file = strings.clone(strings.trim_space(file), allocator)
	}
	ok = true
	return
}

@(require_results)
_dialog_file_save :: proc(allocator: runtime.Allocator) -> (file: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec({
		command = { "zenity", "--file-selection", "--save", },
	}, context.temp_allocator)

	if err != nil || !state.success {
		fmt.eprintln("Failed to open file dialog:", string(stderr))
		return
	}

	file = strings.clone(strings.trim_space(string(stdout)), allocator)
	ok   = true
	return
}
