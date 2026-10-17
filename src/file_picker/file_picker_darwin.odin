package file_picker
import "core:strings"
import "vendor:darwin/AppKit"

ns_string :: #force_inline proc(text: string) -> ^AppKit.String {
	value := AppKit.String.alloc()->initWithOdinString(text)
	value->autorelease()
	return value
}

file_url :: #force_inline proc(path: string) -> ^AppKit.URL {
	value := AppKit.URL.alloc()->initFileURLWithPath(ns_string(path))
	value->autorelease()
	return value
}

allowed_types_array :: proc(filters: []File_Type_Filter) -> ^AppKit.Array {
	count := 0
	for filter in filters {
		count += len(filter.extensions)
		for ext in filter.extensions {
			if is_wildcard_extension(ext) { return nil }
		}
	}
	if count == 0 { return nil }
	objects := make([]AppKit.id, count, context.temp_allocator)
	index := 0
	for filter in filters {
		for ext in filter.extensions {
			if normalized := normalized_extension(ext); len(normalized) > 0 {
				objects[index] = AppKit.id(ns_string(normalized))
				index += 1
			}
		}
	}
	if index == 0 { return nil }
	value := AppKit.Array.alloc()->initWithObjects(raw_data(objects), AppKit.UInteger(index))
	value->autorelease()
	return value
}

clone_url_path :: #force_inline proc(url: ^AppKit.URL, allocator := context.temp_allocator) -> string {
	return "" if url == nil else (strings.clone(string(url->fileSystemRepresentation()), allocator) or_else "")
}

pick_path :: proc(request: File_Picker_Request, allocator := context.temp_allocator) -> (selection: string) {
	AppKit.scoped_autoreleasepool()
	app := AppKit.Application.sharedApplication()
	app->setActivationPolicy(.Regular)
	app->activateIgnoringOtherApps(true)
	if request.mode == .Save_File {
		panel := AppKit.SavePanel.savePanel()
		panel->setShowsHiddenFiles(true)
		if len(request.title) > 0 {
			title := ns_string(request.title)
			panel->setTitle(title)
			panel->setMessage(title)
		}
		if len(request.starting_path) > 0 { panel->setDirectoryURL(file_url(request.starting_path)) }
		if len(request.suggested_name) > 0 { panel->setNameFieldStringValue(ns_string(request.suggested_name)) }
		if types := allowed_types_array(request.file_types); types != nil { panel->setAllowedFileTypes(types) }
		if panel->runModal() != AppKit.ModalResponseOK { return "" }
		selection = clone_url_path(panel->URL(), allocator)
		return selection
	}
	panel := AppKit.OpenPanel.openPanel()
	panel->setCanChooseFiles(request.mode == .Open_File)
	panel->setCanChooseDirectories(request.mode == .Open_Folder)
	panel->setAllowsMultipleSelection(false)
	panel->setResolvesAliases(true)
	panel->setShowsHiddenFiles(true)
	if len(request.title) > 0 {
		title := ns_string(request.title)
		panel->setTitle(title)
		panel->setMessage(title)
	}
	if len(request.starting_path) > 0 { panel->setDirectoryURL(file_url(request.starting_path)) }
	if request.mode == .Open_File {
		if types := allowed_types_array(request.file_types); types != nil { panel->setAllowedFileTypes(types) }
	}
	if panel->runModal() != AppKit.ModalResponseOK { return "" }
	selection = clone_url_path(panel->URL(), allocator)
	return selection
}
