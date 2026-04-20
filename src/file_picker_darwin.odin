package main

import "base:intrinsics"
import "core:strings"
import cocoa "core:sys/darwin/Foundation"

ns_string :: #force_inline proc(text: string) -> ^cocoa.String {
	value := cocoa.String_alloc()->initWithOdinString(text)
	cocoa.autorelease(cast(^cocoa.Object)value)
	return value
}

file_url :: #force_inline proc(path: string) -> ^cocoa.URL {
	value := cocoa.URL_alloc()->initFileURLWithPath(ns_string(path))
	cocoa.autorelease(cast(^cocoa.Object)value)
	return value
}

allowed_types_array :: proc(filters: []File_Type_Filter) -> ^cocoa.Array {
	count := 0
	for filter in filters {
		count += len(filter.extensions)
		for ext in filter.extensions {
			if is_wildcard_extension(ext) { return nil }
		}
	}
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
	if index == 0 { return nil }
	value := cocoa.Array_alloc()->initWithObjects(raw_data(objects), cocoa.UInteger(index))
	cocoa.autorelease(cast(^cocoa.Object)value)
	return value
}

clone_url_path :: #force_inline proc(url: ^cocoa.URL, allocator := context.allocator) -> string {
	return "" if url == nil else (strings.clone(string(cocoa.URL_fileSystemRepresentation(url)), allocator) or_else "")
}

pick_path :: proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {
	cocoa.scoped_autoreleasepool()
	app := cocoa.Application_sharedApplication()
	cocoa.Application_setActivationPolicy(app, .Regular)
	cocoa.Application_activateIgnoringOtherApps(app, true)
	if request.mode == .Save_File {
		panel := cocoa.SavePanel_savePanel()
		intrinsics.objc_send(nil, panel, "setShowsHiddenFiles:", cocoa.BOOL(true))
		if len(request.title) > 0 { intrinsics.objc_send(nil, panel, "setTitle:", ns_string(request.title)) }
		if len(request.starting_path) > 0 { intrinsics.objc_send(nil, panel, "setDirectoryURL:", file_url(request.starting_path)) }
		if len(request.suggested_name) > 0 { intrinsics.objc_send(nil, panel, "setNameFieldStringValue:", ns_string(request.suggested_name)) }
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
	intrinsics.objc_send(nil, panel, "setShowsHiddenFiles:", cocoa.BOOL(true))
	if len(request.title) > 0 { intrinsics.objc_send(nil, panel, "setTitle:", ns_string(request.title)) }
	if len(request.starting_path) > 0 { intrinsics.objc_send(nil, panel, "setDirectoryURL:", file_url(request.starting_path)) }
	if request.mode == .Open_File {
		if types := allowed_types_array(request.file_types); types != nil { cocoa.OpenPanel_setAllowedFileTypes(panel, types) }
	}
	if cocoa.SavePanel_runModal(cast(^cocoa.SavePanel)panel) != .OK { return "", false }
	selection = clone_url_path(cocoa.SavePanel_URL(cast(^cocoa.SavePanel)panel), allocator)
	return selection, len(selection) > 0
}
