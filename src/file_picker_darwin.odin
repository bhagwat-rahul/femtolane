package main
import "base:intrinsics"
import "core:strings"
import "core:sys/darwin/Foundation"

ns_string :: #force_inline proc(text: string) -> ^Foundation.String {
	value := Foundation.String_alloc()->initWithOdinString(text)
	Foundation.autorelease(cast(^Foundation.Object)value)
	return value
}

file_url :: #force_inline proc(path: string) -> ^Foundation.URL {
	value := Foundation.URL_alloc()->initFileURLWithPath(ns_string(path))
	Foundation.autorelease(cast(^Foundation.Object)value)
	return value
}

allowed_types_array :: proc(filters: []File_Type_Filter) -> ^Foundation.Array {
	count := 0
	for filter in filters {
		count += len(filter.extensions)
		for ext in filter.extensions {
			if is_wildcard_extension(ext) { return nil }
		}
	}
	if count == 0 { return nil }
	objects := make([]^Foundation.Object, count, context.temp_allocator)
	index := 0
	for filter in filters {
		for ext in filter.extensions {
			if normalized := normalized_extension(ext); len(normalized) > 0 {
				objects[index] = cast(^Foundation.Object)ns_string(normalized)
				index += 1
			}
		}
	}
	if index == 0 { return nil }
	value := Foundation.Array_alloc()->initWithObjects(raw_data(objects), Foundation.UInteger(index))
	Foundation.autorelease(cast(^Foundation.Object)value)
	return value
}

clone_url_path :: #force_inline proc(url: ^Foundation.URL, allocator := context.temp_allocator) -> string {
	return "" if url == nil else (strings.clone(string(Foundation.URL_fileSystemRepresentation(url)), allocator) or_else "")
}

pick_path :: proc(request: File_Picker_Request, allocator := context.temp_allocator) -> (selection: string) {
	Foundation.scoped_autoreleasepool()
	app := Foundation.Application_sharedApplication()
	Foundation.Application_setActivationPolicy(app, .Regular)
	Foundation.Application_activateIgnoringOtherApps(app, true)
	if request.mode == .Save_File {
		panel := Foundation.SavePanel_savePanel()
		intrinsics.objc_send(nil, panel, "setShowsHiddenFiles:", Foundation.BOOL(true))
		if len(request.title) > 0 { intrinsics.objc_send(nil, panel, "setTitle:", ns_string(request.title)) }
		if len(request.starting_path) > 0 { intrinsics.objc_send(nil, panel, "setDirectoryURL:", file_url(request.starting_path)) }
		if len(request.suggested_name) > 0 { intrinsics.objc_send(nil, panel, "setNameFieldStringValue:", ns_string(request.suggested_name)) }
		if types := allowed_types_array(request.file_types); types != nil { intrinsics.objc_send(nil, panel, "setAllowedFileTypes:", types) }
		if Foundation.SavePanel_runModal(panel) != .OK { return "" }
		selection = clone_url_path(Foundation.SavePanel_URL(panel), allocator)
		return selection
	}
	panel := Foundation.OpenPanel_openPanel()
	Foundation.OpenPanel_setCanChooseFiles(panel, request.mode == .Open_File)
	Foundation.OpenPanel_setCanChooseDirectories(panel, request.mode == .Open_Folder)
	Foundation.OpenPanel_setAllowsMultipleSelection(panel, false)
	Foundation.OpenPanel_setResolvesAliases(panel, true)
	intrinsics.objc_send(nil, panel, "setShowsHiddenFiles:", Foundation.BOOL(true))
	if len(request.title) > 0 { intrinsics.objc_send(nil, panel, "setTitle:", ns_string(request.title)) }
	if len(request.starting_path) > 0 { intrinsics.objc_send(nil, panel, "setDirectoryURL:", file_url(request.starting_path)) }
	if request.mode == .Open_File {
		if types := allowed_types_array(request.file_types); types != nil { Foundation.OpenPanel_setAllowedFileTypes(panel, types) }
	}
	if Foundation.SavePanel_runModal(cast(^Foundation.SavePanel)panel) != .OK { return "" }
	selection = clone_url_path(Foundation.SavePanel_URL(cast(^Foundation.SavePanel)panel), allocator)
	return selection
}
