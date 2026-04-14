package main

import "base:intrinsics"
import "core:strings"
import cocoa "core:sys/darwin/Foundation"
import win32 "core:sys/windows"

when ODIN_OS == .Linux {
	foreign import gtk "system:gtk-3"
	foreign import gobject "system:gobject-2.0"
	foreign import glib "system:glib-2.0"

	Gtk_File_Chooser_Action :: enum c_int { OPEN, SAVE, SELECT_FOLDER, CREATE_FOLDER }
	GTK_RESPONSE_ACCEPT :: -3

	@(default_calling_convention="c")
	foreign gtk {
		gtk_init_check :: proc(argc, argv: rawptr) -> bool ---
		gtk_file_chooser_native_new :: proc(title: cstring, parent: rawptr, action: Gtk_File_Chooser_Action, accept_label, cancel_label: cstring) -> rawptr ---
		gtk_native_dialog_run :: proc(dialog: rawptr) -> c_int ---
		gtk_file_chooser_set_current_folder :: proc(chooser: rawptr, path: cstring) -> bool ---
		gtk_file_chooser_set_current_name :: proc(chooser: rawptr, name: cstring) ---
		gtk_file_chooser_set_do_overwrite_confirmation :: proc(chooser: rawptr, enabled: bool) ---
		gtk_file_chooser_get_filename :: proc(chooser: rawptr) -> cstring ---
		gtk_file_chooser_add_filter :: proc(chooser, filter: rawptr) ---
		gtk_file_filter_new :: proc() -> rawptr ---
		gtk_file_filter_set_name :: proc(filter: rawptr, name: cstring) ---
		gtk_file_filter_add_pattern :: proc(filter: rawptr, pattern: cstring) ---
	}

	@(default_calling_convention="c")
	foreign gobject { g_object_unref :: proc(object: rawptr) --- }
	@(default_calling_convention="c")
	foreign glib { g_free :: proc(ptr: rawptr) --- }
}

Picker_Mode :: enum {
	Open_File,
	Save_File,
	Open_Folder,
}

File_Type_Filter :: struct {
	description: string,
	extensions:  []string, // "png", "jpg", "json"
}

File_Picker_Request :: struct {
	mode:           Picker_Mode,
	title:          string,
	starting_path:  string,
	suggested_name: string,
	file_types:     []File_Type_Filter,
}

pick_path :: #force_inline proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {
	when ODIN_OS == .Darwin    { return pick_path_darwin(request, allocator) }
	when ODIN_OS == .Windows   { return pick_path_windows(request, allocator) }
	when ODIN_OS == .Linux     { return pick_path_linux(request, allocator) }
	return "", false
}

@(private="file")
normalized_extension :: #force_inline proc(extension: string) -> string {
	if len(extension) > 0 && extension[0] == '.' { return extension[1:] }
	return extension
}

@(private="file")
count_valid_extensions :: #force_inline proc(extensions: []string) -> int {
	count := 0
	for extension in extensions {
		if len(normalized_extension(extension)) > 0 { count += 1 }
	}
	return count
}

@(private="file")
wildcard_for_extension :: #force_inline proc(extension: string, allocator := context.temp_allocator) -> string {
	ext := normalized_extension(extension)
	if len(ext) == 0 { return "" }
	return strings.concatenate({"*.", ext}, allocator) or_else ""
}

when ODIN_OS == .Darwin {
	@(private="file")
	ns_string :: #force_inline proc(text: string) -> ^cocoa.String {
		value := cocoa.String_alloc()->initWithOdinString(text)
		cocoa.autorelease(cast(^cocoa.Object)value)
		return value
	}

	@(private="file")
	file_url :: #force_inline proc(path: string) -> ^cocoa.URL {
		value := cocoa.URL_alloc()->initFileURLWithPath(ns_string(path))
		cocoa.autorelease(cast(^cocoa.Object)value)
		return value
	}

	@(private="file")
	allowed_types_array :: proc(filters: []File_Type_Filter) -> ^cocoa.Array {
		count := 0
		for filter in filters { count += count_valid_extensions(filter.extensions) }
		if count == 0 { return nil }
		objects := make([]^cocoa.Object, count, context.temp_allocator)
		index := 0
		for filter in filters {
			for ext in filter.extensions {
				if normalized := normalized_extension(ext); len(normalized) > 0 {
					objects[index] = cast(^cocoa.Object)ns_string(normalized)
					index += 1
				}
			}
		}
		value := cocoa.Array_alloc()->initWithObjects(raw_data(objects), cocoa.UInteger(count))
		cocoa.autorelease(cast(^cocoa.Object)value)
		return value
	}

	@(private="file")
	clone_url_path :: #force_inline proc(url: ^cocoa.URL, allocator := context.allocator) -> string {
		if url == nil { return "" }
		return strings.clone(string(cocoa.URL_fileSystemRepresentation(url)), allocator) or_else ""
	}

	@(private="file")
	pick_path_darwin :: proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {
		pool := cocoa.AutoreleasePool_alloc()->init()
		defer cocoa.AutoreleasePool_drain(pool)
		app := cocoa.Application_sharedApplication()
		cocoa.Application_setActivationPolicy(app, .Regular)
		cocoa.Application_activateIgnoringOtherApps(app, true)
		if request.mode == .Save_File {
			panel := cocoa.SavePanel_savePanel()
			if len(request.title) > 0           { intrinsics.objc_send(nil, panel, "setTitle:", ns_string(request.title)) }
			if len(request.starting_path) > 0   { intrinsics.objc_send(nil, panel, "setDirectoryURL:", file_url(request.starting_path)) }
			if len(request.suggested_name) > 0  { intrinsics.objc_send(nil, panel, "setNameFieldStringValue:", ns_string(request.suggested_name)) }
			if types := allowed_types_array(request.file_types); types != nil { intrinsics.objc_send(nil, panel, "setAllowedFileTypes:", types) }
			if cocoa.SavePanel_runModal(panel) != .OK { return "", false }
			selection = clone_url_path(cocoa.SavePanel_URL(panel), allocator)
			return selection, len(selection) > 0
		}
		panel := cocoa.OpenPanel_openPanel()
		cocoa.OpenPanel_setCanChooseFiles(panel, request.mode == .Open_File)
		cocoa.OpenPanel_setCanChooseDirectories(panel, request.mode == .Open_Folder)
		cocoa.OpenPanel_setAllowsMultipleSelection(panel, false)
		cocoa.OpenPanel_setResolvesAliases(panel, true)
		if len(request.title) > 0         { intrinsics.objc_send(nil, panel, "setTitle:", ns_string(request.title)) }
		if len(request.starting_path) > 0 { intrinsics.objc_send(nil, panel, "setDirectoryURL:", file_url(request.starting_path)) }
		if request.mode == .Open_File {
			if types := allowed_types_array(request.file_types); types != nil { cocoa.OpenPanel_setAllowedFileTypes(panel, types) }
		}
		if cocoa.SavePanel_runModal(cast(^cocoa.SavePanel)panel) != .OK { return "", false }
		selection = clone_url_path(cocoa.SavePanel_URL(cast(^cocoa.SavePanel)panel), allocator)
		return selection, len(selection) > 0
	}
} else when ODIN_OS == .Windows {
	@(private="file")
	first_allowed_extension :: #force_inline proc(filters: []File_Type_Filter) -> string {
		for filter in filters {
			for ext in filter.extensions {
				if normalized := normalized_extension(ext); len(normalized) > 0 { return normalized }
			}
		}
		return ""
	}

	@(private="file")
	windows_filter_pattern :: proc(filter: File_Type_Filter) -> string {
		valid_extension_count := count_valid_extensions(filter.extensions)
		if valid_extension_count == 0 { return "" }
		patterns := make([]string, valid_extension_count, context.temp_allocator)
		count := 0
		for ext in filter.extensions {
			if pattern := wildcard_for_extension(ext, context.temp_allocator); len(pattern) > 0 {
				patterns[count] = pattern
				count += 1
			}
		}
		return strings.join(patterns, ";", context.temp_allocator) or_else ""
	}

	@(private="file")
	pick_path_windows :: proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {
		co_init := win32.CoInitializeEx(nil, .APARTMENTTHREADED)
		if win32.FAILED(co_init) { return "", false }
		defer win32.CoUninitialize()
		dialog_ptr: rawptr
		class_id := win32.CLSID_FileSaveDialog if request.mode == .Save_File else win32.CLSID_FileOpenDialog
		if hr := win32.CoCreateInstance(class_id, nil, win32.CLSCTX_INPROC_SERVER, win32.IID_IFileDialog, &dialog_ptr); win32.FAILED(hr) { return "", false }
		dialog := cast(^win32.IFileDialog)dialog_ptr
		defer dialog.Vtbl.Release(cast(^win32.IUnknown)dialog)
		options: win32.FILEOPENDIALOGOPTIONS
		if hr := dialog.Vtbl.GetOptions(dialog, &options); win32.FAILED(hr) { return "", false }
		options |= win32.FOS_FORCEFILESYSTEM | win32.FOS_PATHMUSTEXIST
		switch request.mode {
		case .Open_File:   options |= win32.FOS_FILEMUSTEXIST
		case .Save_File:   options |= win32.FOS_OVERWRITEPROMPT
		case .Open_Folder: options |= win32.FOS_PICKFOLDERS
		}
		if hr := dialog.Vtbl.SetOptions(dialog, options); win32.FAILED(hr) { return "", false }
		if len(request.title) > 0 { _ = dialog.Vtbl.SetTitle(dialog, win32.utf8_to_wstring(request.title, context.temp_allocator) or_else nil) }
		if len(request.starting_path) > 0 {
			folder_ptr: rawptr
			if hr := win32.SHCreateItemFromParsingName(win32.utf8_to_wstring(request.starting_path, context.temp_allocator) or_else nil, nil, win32.IID_IShellItem, &folder_ptr); win32.SUCCEEDED(hr) {
				folder := cast(^win32.IShellItem)folder_ptr
				defer folder.Vtbl.Release(cast(^win32.IUnknown)folder)
				_ = dialog.Vtbl.SetFolder(dialog, folder)
			}
		}
		if request.mode == .Save_File && len(request.suggested_name) > 0 { _ = dialog.Vtbl.SetFileName(dialog, win32.utf8_to_wstring(request.suggested_name, context.temp_allocator) or_else nil) }
		if request.mode != .Open_Folder && len(request.file_types) > 0 {
			specs := make([]win32.COMDLG_FILTERSPEC, len(request.file_types), context.temp_allocator)
			spec_count := 0
			for filter in request.file_types {
				pattern := windows_filter_pattern(filter)
				if len(pattern) == 0 { continue }
				description := filter.description if len(filter.description) > 0 else pattern
				specs[spec_count] = {pszName = win32.utf8_to_wstring(description, context.temp_allocator) or_else nil, pszSpec = win32.utf8_to_wstring(pattern, context.temp_allocator) or_else nil}
				spec_count += 1
			}
			if spec_count > 0 {
				_ = dialog.Vtbl.SetFileTypes(dialog, uint(spec_count), raw_data(specs[:spec_count]))
			}
			if default_ext := first_allowed_extension(request.file_types); len(default_ext) > 0 { _ = dialog.Vtbl.SetDefaultExtension(dialog, win32.utf8_to_wstring(default_ext, context.temp_allocator) or_else nil) }
		}
		if win32.FAILED(dialog.Vtbl.Show(dialog, nil)) { return "", false }
		item: ^win32.IShellItem
		if hr := dialog.Vtbl.GetResult(dialog, &item); win32.FAILED(hr) || item == nil { return "", false }
		defer item.Vtbl.Release(cast(^win32.IUnknown)item)
		path_w: win32.LPWSTR
		if hr := item.Vtbl.GetDisplayName(item, .FILESYSPATH, &path_w); win32.FAILED(hr) || path_w == nil { return "", false }
		defer win32.CoTaskMemFree(rawptr(path_w))
		selection, _ = win32.wstring_to_utf8(path_w, -1, allocator)
		return selection, len(selection) > 0
	}
} else when ODIN_OS == .Linux {
	@(private="file")
	add_linux_filters :: proc(dialog: rawptr, filters: []File_Type_Filter) {
		for filter in filters {
			gtk_filter := gtk_file_filter_new()
			if gtk_filter == nil { continue }
			if len(filter.description) > 0 { gtk_file_filter_set_name(gtk_filter, strings.clone_to_cstring(filter.description, context.temp_allocator) or_else nil) }
			for ext in filter.extensions {
				if pattern := wildcard_for_extension(ext, context.temp_allocator); len(pattern) > 0 {
					gtk_file_filter_add_pattern(gtk_filter, strings.clone_to_cstring(pattern, context.temp_allocator) or_else nil)
				}
			}
			gtk_file_chooser_add_filter(dialog, gtk_filter)
		}
	}

	@(private="file")
	pick_path_linux :: proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {
		if !gtk_init_check(nil, nil) { return "", false }
		action := Gtk_File_Chooser_Action.OPEN
		accept_label := "Open"
		switch request.mode {
		case .Save_File:
			action = .SAVE
			accept_label = "Save"
		case .Open_Folder:
			action = .SELECT_FOLDER
			accept_label = "Select"
		}
		title := request.title
		if len(title) == 0 { title = "Select Path" }
		dialog := gtk_file_chooser_native_new(strings.clone_to_cstring(title, context.temp_allocator) or_else nil, nil, action, strings.clone_to_cstring(accept_label, context.temp_allocator) or_else nil, "Cancel")
		if dialog == nil { return "", false }
		defer g_object_unref(dialog)
		if len(request.starting_path) > 0 { _ = gtk_file_chooser_set_current_folder(dialog, strings.clone_to_cstring(request.starting_path, context.temp_allocator) or_else nil) }
		if request.mode == .Save_File {
			gtk_file_chooser_set_do_overwrite_confirmation(dialog, true)
			if len(request.suggested_name) > 0 { gtk_file_chooser_set_current_name(dialog, strings.clone_to_cstring(request.suggested_name, context.temp_allocator) or_else nil) }
		} else if request.mode == .Open_File {
			add_linux_filters(dialog, request.file_types)
		}
		if gtk_native_dialog_run(dialog) != GTK_RESPONSE_ACCEPT { return "", false }
		path := gtk_file_chooser_get_filename(dialog)
		if path == nil { return "", false }
		defer g_free(rawptr(path))
		selection = strings.clone(string(path), allocator) or_else ""
		return selection, len(selection) > 0
	}
}
