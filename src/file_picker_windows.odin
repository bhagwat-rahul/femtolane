package main
import "core:strings"
import "core:sys/windows"

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

pick_path :: proc(request: File_Picker_Request, allocator := context.temp_allocator) -> (selection: string) {
	co_init := windows.CoInitializeEx(nil, .APARTMENTTHREADED)
	if windows.FAILED(co_init) { return "" }
	defer windows.CoUninitialize()
	dialog_ptr: rawptr
	class_id := windows.CLSID_FileSaveDialog if request.mode == .Save_File else windows.CLSID_FileOpenDialog
	if hr := windows.CoCreateInstance(class_id, nil, windows.CLSCTX_INPROC_SERVER, windows.IID_IFileDialog, &dialog_ptr);
	   windows.FAILED(hr) { return "" }
	dialog := cast(^windows.IFileDialog)dialog_ptr
	defer dialog.Vtbl.Release(cast(^windows.IUnknown)dialog)
	options: windows.FILEOPENDIALOGOPTIONS
	if hr := dialog.Vtbl.GetOptions(dialog, &options); windows.FAILED(hr) { return "" }
	options |= windows.FOS_FORCEFILESYSTEM | windows.FOS_PATHMUSTEXIST | windows.FOS_FORCESHOWHIDDEN
	switch request.mode {
	case .Open_File: options |= windows.FOS_FILEMUSTEXIST
	case .Save_File: options |= windows.FOS_OVERWRITEPROMPT
	case .Open_Folder: options |= windows.FOS_PICKFOLDERS
	}
	if hr := dialog.Vtbl.SetOptions(dialog, options); windows.FAILED(hr) { return "" }
	if len(request.title) > 0 { _ = dialog.Vtbl.SetTitle(dialog, windows.utf8_to_wstring(request.title, context.temp_allocator)) }
	if len(request.starting_path) > 0 {
		folder_ptr: rawptr
		if hr := windows.SHCreateItemFromParsingName(
			windows.utf8_to_wstring(request.starting_path, context.temp_allocator),
			nil,
			windows.IID_IShellItem,
			&folder_ptr,
		); windows.SUCCEEDED(hr) {
			folder := cast(^windows.IShellItem)folder_ptr
			defer folder.Vtbl.Release(cast(^windows.IUnknown)folder)
			_ = dialog.Vtbl.SetFolder(dialog, folder)
		}
	}
	if request.mode == .Save_File &&
	   len(request.suggested_name) >
		   0 { _ = dialog.Vtbl.SetFileName(dialog, windows.utf8_to_wstring(request.suggested_name, context.temp_allocator)) }
	if request.mode != .Open_Folder && len(request.file_types) > 0 {
		specs := make([]windows.COMDLG_FILTERSPEC, len(request.file_types), context.temp_allocator)
		spec_count := 0
		for filter in request.file_types {
			pattern := windows_filter_pattern(filter)
			if len(pattern) == 0 { continue }
			description := filter.description if len(filter.description) > 0 else pattern
			specs[spec_count] = {
				pszName = windows.utf8_to_wstring(description, context.temp_allocator),
				pszSpec = windows.utf8_to_wstring(pattern, context.temp_allocator),
			}
			spec_count += 1
		}
		if spec_count > 0 {
			_ = dialog.Vtbl.SetFileTypes(dialog, u32(spec_count), raw_data(specs[:spec_count]))
		}
		if default_ext := first_allowed_extension(request.file_types);
		   len(default_ext) > 0 { _ = dialog.Vtbl.SetDefaultExtension(dialog, windows.utf8_to_wstring(default_ext, context.temp_allocator)) }
	}
	if windows.FAILED(dialog.Vtbl.Show(dialog, nil)) { return "" }
	item: ^windows.IShellItem
	if hr := dialog.Vtbl.GetResult(dialog, &item); windows.FAILED(hr) || item == nil { return "" }
	defer item.Vtbl.Release(cast(^windows.IUnknown)item)
	path_w: windows.LPWSTR
	if hr := item.Vtbl.GetDisplayName(item, .FILESYSPATH, &path_w); windows.FAILED(hr) || path_w == nil { return "" }
	defer windows.CoTaskMemFree(rawptr(path_w))
	selection, _ = windows.wstring_to_utf8_alloc(cstring16(path_w), -1, allocator)
	return selection
}
