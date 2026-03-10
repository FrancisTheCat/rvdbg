package rvdbg

import "base:runtime"

_dialog_file_open :: proc(directory: bool, allocator: runtime.Allocator) -> (file: string, ok: bool) {
	unimplemented()
}

_dialog_file_open_multiple :: proc(directory: bool, allocator: runtime.Allocator) -> (files: []string, ok: bool) {
	unimplemented()
}

_dialog_file_save :: proc(allocator: runtime.Allocator) -> (file: string, ok: bool) {
	unimplemented()
}

