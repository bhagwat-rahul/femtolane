package main
import "core:c"
import "core:strings"

// =====================================================
// Types
// =====================================================

DBusConnection :: rawptr
DBusMessage :: rawptr

DBusError :: struct {
	name:    cstring,
	message: cstring,
	_opaque: [64]byte,
}

DBusMessageIter :: struct {
	_opaque: [64]byte,
}

DBUS_BUS_SESSION: c.int : 0


@(default_calling_convention = "c")
foreign _ {
	dbus_error_init :: proc(err: ^DBusError) ---
	dbus_bus_get :: proc(bus: c.int, err: ^DBusError) -> DBusConnection ---
	dbus_message_new_method_call :: proc(bus: cstring, path: cstring, interface: cstring, method: cstring) -> DBusMessage ---
	dbus_message_iter_init_append :: proc(msg: DBusMessage, iter: ^DBusMessageIter) -> c.int ---
	dbus_message_iter_append_basic :: proc(iter: ^DBusMessageIter, typ: c.int, value: rawptr) -> c.int ---
	dbus_connection_send_with_reply_and_block :: proc(conn: DBusConnection, msg: DBusMessage, timeout: c.int, err: ^DBusError) -> DBusMessage ---
	dbus_message_iter_init :: proc(msg: DBusMessage, iter: ^DBusMessageIter) -> c.int ---
	dbus_message_iter_next :: proc(iter: ^DBusMessageIter) -> c.int ---
	dbus_message_iter_get_basic :: proc(iter: ^DBusMessageIter, value: rawptr) -> c.int ---
	dbus_message_get_path :: proc(msg: DBusMessage) -> cstring ---
	dbus_connection_read_write :: proc(conn: DBusConnection, timeout: c.int) -> c.int ---
	dbus_connection_pop_message :: proc(conn: DBusConnection) -> DBusMessage ---
	dbus_message_is_signal :: proc(msg: DBusMessage, interface: cstring, signal: cstring) -> c.int ---
}

pick_path :: proc(request: File_Picker_Request, allocator := context.allocator) -> (selection: string, ok: bool) {

	err: DBusError
	dbus_error_init(&err)

	conn := dbus_bus_get(DBUS_BUS_SESSION, &err)
	if conn == nil {
		return "", false
	}

	title: cstring = strings.clone_to_cstring(request.title)
	if len(title) == 0 { title = "Select File" }

	parent: cstring = ""

	msg := dbus_message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.FileChooser",
		"OpenFile",
	)

	if msg == nil { return "", false }

	iter: DBusMessageIter
	dbus_message_iter_init_append(msg, &iter)

	p := parent
	t := title

	dbus_message_iter_append_basic(&iter, 's', rawptr(&p))
	dbus_message_iter_append_basic(&iter, 's', rawptr(&t))

	reply := dbus_connection_send_with_reply_and_block(conn, msg, -1, &err)

	if reply == nil { return "", false }

	handle: cstring
	dbus_message_iter_init(reply, &iter)
	dbus_message_iter_get_basic(&iter, &handle)

	for {
		dbus_connection_read_write(conn, 0)

		sig := dbus_connection_pop_message(conn)
		if sig == nil { continue }

		if dbus_message_is_signal(sig, "org.freedesktop.portal.Request", "Response") == 0 { continue }

		path := dbus_message_get_path(sig)
		if path == nil || path != handle { continue }

		dbus_message_iter_init(sig, &iter)

		response_code: c.int
		dbus_message_iter_get_basic(&iter, &response_code)

		if response_code != 0 { return "", false }

		dbus_message_iter_next(&iter)

		uri: cstring
		dbus_message_iter_get_basic(&iter, &uri)

		if uri == nil { return "", false }

		uri_str := string(uri)

		if len(uri_str) > 7 && uri_str[0:7] == "file://" { return strings.clone(uri_str[7:], allocator), true }

		return strings.clone(uri_str, allocator), true
	}
}
