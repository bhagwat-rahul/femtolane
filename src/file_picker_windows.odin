package main
import "core:strings"
import win32 "core:sys/windows"

first_allowed_extension :: #force_inline proc(filters: []File_Type_Filter) -> string {
	for filter in filters {
		for ext in filter.extensions {
			if normalized := normalized_extension(ext); len(normalized) > 0 { return normalized }
		}
	}
	return ""
}

windows_filter_pattern :: proc(filter: File_Type_Filter) -> string {
	patterns := make([]string, len(filter.extensions), context.temp_allocator)
	count := 0
	for ext in filter.extensions {
		if pattern := wildcard_for_extension(ext, context.temp_allocator); len(pattern) > 0 {
			patterns[count] = pattern
			count += 1
		}
	}
	if count == 0 { return "" }
	return strings.join(patterns[:count], ";", context.temp_allocator) or_else ""
}

pick_path :: proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {
	co_init := win32.CoInitializeEx(nil, .APARTMENTTHREADED)
	if win32.FAILED(co_init) { return "", false }
	defer win32.CoUninitialize()
	dialog_ptr: rawptr
	class_id := win32.CLSID_FileSaveDialog if request.mode == .Save_File else win32.CLSID_FileOpenDialog
	if hr := win32.CoCreateInstance(class_id, nil, win32.CLSCTX_INPROC_SERVER, win32.IID_IFileDialog, &dialog_ptr);
	   win32.FAILED(hr) { return "", false }
	dialog := cast(^win32.IFileDialog)dialog_ptr
	defer dialog.Vtbl.Release(cast(^win32.IUnknown)dialog)
	options: win32.FILEOPENDIALOGOPTIONS
	if hr := dialog.Vtbl.GetOptions(dialog, &options); win32.FAILED(hr) { return "", false }
	options |= win32.FOS_FORCEFILESYSTEM | win32.FOS_PATHMUSTEXIST | win32.FOS_FORCESHOWHIDDEN
	switch request.mode {
	case .Open_File: options |= win32.FOS_FILEMUSTEXIST
	case .Save_File: options |= win32.FOS_OVERWRITEPROMPT
	case .Open_Folder: options |= win32.FOS_PICKFOLDERS
	}
	if hr := dialog.Vtbl.SetOptions(dialog, options); win32.FAILED(hr) { return "", false }
	if len(request.title) > 0 { _ = dialog.Vtbl.SetTitle(dialog, win32.utf8_to_wstring(request.title, context.temp_allocator)) }
	if len(request.starting_path) > 0 {
		folder_ptr: rawptr
		if hr := win32.SHCreateItemFromParsingName(
			win32.utf8_to_wstring(request.starting_path, context.temp_allocator),
			nil,
			win32.IID_IShellItem,
			&folder_ptr,
		); win32.SUCCEEDED(hr) {
			folder := cast(^win32.IShellItem)folder_ptr
			defer folder.Vtbl.Release(cast(^win32.IUnknown)folder)
			_ = dialog.Vtbl.SetFolder(dialog, folder)
		}
	}
	if request.mode == .Save_File &&
	   len(request.suggested_name) > 0 { _ = dialog.Vtbl.SetFileName(dialog, win32.utf8_to_wstring(request.suggested_name, context.temp_allocator)) }
	if request.mode != .Open_Folder && len(request.file_types) > 0 {
		specs := make([]win32.COMDLG_FILTERSPEC, len(request.file_types), context.temp_allocator)
		spec_count := 0
		for filter in request.file_types {
			pattern := windows_filter_pattern(filter)
			if len(pattern) == 0 { continue }
			description := filter.description if len(filter.description) > 0 else pattern
			specs[spec_count] = {
				pszName = win32.utf8_to_wstring(description, context.temp_allocator),
				pszSpec = win32.utf8_to_wstring(pattern, context.temp_allocator),
			}
			spec_count += 1
		}
		if spec_count > 0 {
			_ = dialog.Vtbl.SetFileTypes(dialog, u32(spec_count), raw_data(specs[:spec_count]))
		}
		if default_ext := first_allowed_extension(request.file_types);
		   len(default_ext) > 0 { _ = dialog.Vtbl.SetDefaultExtension(dialog, win32.utf8_to_wstring(default_ext, context.temp_allocator)) }
	}
	if win32.FAILED(dialog.Vtbl.Show(dialog, nil)) { return "", false }
	item: ^win32.IShellItem
	if hr := dialog.Vtbl.GetResult(dialog, &item); win32.FAILED(hr) || item == nil { return "", false }
	defer item.Vtbl.Release(cast(^win32.IUnknown)item)
	path_w: win32.LPWSTR
	if hr := item.Vtbl.GetDisplayName(item, .FILESYSPATH, &path_w); win32.FAILED(hr) || path_w == nil { return "", false }
	defer win32.CoTaskMemFree(rawptr(path_w))
	selection, _ = win32.wstring_to_utf8_alloc(cstring16(path_w), -1, allocator)
	return selection, len(selection) > 0
}
