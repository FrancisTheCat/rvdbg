package rvdbg

@(require_results)
dialog_file_open :: proc(directory := false, allocator := context.temp_allocator) -> (file: string, ok: bool) {
	return _dialog_file_open(directory, allocator)
}

@(require_results)
dialog_file_open_multiple :: proc(directory := false, allocator := context.temp_allocator) -> (files: []string, ok: bool) {
	return _dialog_file_open_multiple(directory, allocator)
}

@(require_results)
dialog_file_save :: proc(allocator := context.temp_allocator) -> (file: string, ok: bool) {
	return _dialog_file_save(allocator)
}
