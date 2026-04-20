package main
import "core:c"
import "core:strings"

foreign import gtk "system:gtk-3"
foreign import gobject "system:gobject-2.0"
foreign import glib "system:glib-2.0"

Gtk_File_Chooser_Action :: enum c.int {
	OPEN,
	SAVE,
	SELECT_FOLDER,
	CREATE_FOLDER,
}
GTK_RESPONSE_ACCEPT : c.int : -3

@(default_calling_convention = "c")
foreign gtk {
	gtk_init_check :: proc(argc, argv: rawptr) -> bool ---
	gtk_file_chooser_native_new :: proc(title: cstring, parent: rawptr, action: Gtk_File_Chooser_Action, accept_label, cancel_label: cstring) -> rawptr ---
	gtk_native_dialog_run :: proc(dialog: rawptr) -> c.int ---
	gtk_file_chooser_set_current_folder :: proc(chooser: rawptr, path: cstring) -> bool ---
	gtk_file_chooser_set_current_name :: proc(chooser: rawptr, name: cstring) ---
	gtk_file_chooser_set_do_overwrite_confirmation :: proc(chooser: rawptr, enabled: bool) ---
	gtk_file_chooser_set_show_hidden :: proc(chooser: rawptr, show_hidden: bool) ---
	gtk_file_chooser_get_filename :: proc(chooser: rawptr) -> cstring ---
	gtk_file_chooser_add_filter :: proc(chooser, filter: rawptr) ---
	gtk_file_filter_new :: proc() -> rawptr ---
	gtk_file_filter_set_name :: proc(filter: rawptr, name: cstring) ---
	gtk_file_filter_add_pattern :: proc(filter: rawptr, pattern: cstring) ---
}

@(default_calling_convention = "c")
foreign gobject { g_object_unref :: proc(object: rawptr) --- }
@(default_calling_convention = "c")
foreign glib { g_free :: proc(ptr: rawptr) --- }


add_linux_filters :: proc(dialog: rawptr, filters: []File_Type_Filter) {
	for filter in filters {
		gtk_filter: rawptr
		for ext in filter.extensions {
			if pattern := wildcard_for_extension(ext, context.temp_allocator); len(pattern) > 0 {
				if gtk_filter == nil {
					gtk_filter = gtk_file_filter_new()
					if gtk_filter == nil { break }
					if len(filter.description) >
					   0 { gtk_file_filter_set_name(gtk_filter, strings.clone_to_cstring(filter.description, context.temp_allocator) or_else nil) }
				}
				gtk_file_filter_add_pattern(gtk_filter, strings.clone_to_cstring(pattern, context.temp_allocator) or_else nil)
			}
		}
		if gtk_filter != nil { gtk_file_chooser_add_filter(dialog, gtk_filter) }
	}
}

pick_path :: proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {
	if !gtk_init_check(nil, nil) { return "", false }
	action := Gtk_File_Chooser_Action.OPEN
	accept_label := "Open"
	switch request.mode {
	case .Open_File:
		action = .OPEN
		accept_label = "Open"
	case .Save_File:
		action = .SAVE
		accept_label = "Save"
	case .Open_Folder:
		action = .SELECT_FOLDER
		accept_label = "Select"
	}
	title := request.title
	if len(title) == 0 { title = "Select Path" }
	dialog := gtk_file_chooser_native_new(
		strings.clone_to_cstring(title, context.temp_allocator) or_else nil,
		nil,
		action,
		strings.clone_to_cstring(accept_label, context.temp_allocator) or_else nil,
		"Cancel",
	)
	if dialog == nil { return "", false }
	defer g_object_unref(dialog)
	gtk_file_chooser_set_show_hidden(dialog, true)
	if len(request.starting_path) >
	   0 { _ = gtk_file_chooser_set_current_folder(dialog, strings.clone_to_cstring(request.starting_path, context.temp_allocator) or_else nil) }
	if request.mode == .Save_File {
		gtk_file_chooser_set_do_overwrite_confirmation(dialog, true)
		if len(request.suggested_name) >
		   0 { gtk_file_chooser_set_current_name(dialog, strings.clone_to_cstring(request.suggested_name, context.temp_allocator) or_else nil) }
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
