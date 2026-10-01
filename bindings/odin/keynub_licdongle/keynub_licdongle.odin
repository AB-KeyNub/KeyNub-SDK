/*
KeyNub License Dongle: verify that a dongle is genuine, read and write the
license records it holds, use its hardware counters and encrypt data so that
only a dongle can decrypt it. Calls the SDK's flat C API through a library
loaded at run time (see library.odin); nothing is linked.

	import kn "keynub:keynub_licdongle"

	unseal :: proc(sealed: []u8) -> (data: []u8, err: kn.Error) {
		d := kn.open() or_return
		defer kn.close(&d)
		_ = kn.verify_genuine(d, context.temp_allocator) or_return
		kn.open_session(d) or_return
		defer kn.close_session(d)
		return kn.app_decrypt(d, sealed)
	}
*/
package keynub_licdongle

import "core:bytes"
import "core:reflect"
import "core:strings"

// Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
// LICDF_ERROR_SIZE), and one for a record name.
@(private)
SERIAL_SIZE :: 15
@(private)
DATE_SIZE :: 11
@(private)
PATH_SIZE :: 512
@(private)
ERROR_SIZE :: 256
@(private)
NAME_SIZE :: 256

// Bits in the flags value of licdf_get_info.
@(private)
FLAG_SECURE_ELEMENT_READY :: 0x01
@(private)
FLAG_PROVISIONED :: 0x02
@(private)
FLAG_WATCHDOG_REBOOT :: 0x04
@(private)
FLAG_ISOLATED :: 0x08
@(private)
FLAG_WRITE_AUTH_ROTATED :: 0x10

// Version is the native library's version.
Version :: struct {
	major, minor, patch: int,
}

// Device is an attached dongle.
Device :: struct {
	serial: string,
	path:   string,
}

// Device_Info is the plaintext device information.
Device_Info :: struct {
	protocol_major:       int,
	protocol_minor:       int,
	firmware_major:       int,
	firmware_minor:       int,
	firmware_patch:       int,
	secure_element_ready: bool,
	provisioned:          bool,
	watchdog_reboot:      bool,
	isolated:             bool,
	write_auth_rotated:   bool,
	data_capacity:        int,
	data_free:            int,
}

// Verification is the result of a successful `verify_genuine`.
Verification :: struct {
	serial:           string,
	provisioned_date: string,
}

// Record is a record on the dongle.
Record :: struct {
	name: string,
	size: int,
}

// Scope says which dongles can open data sealed with `app_encrypt`: this one
// (`.Device`) or any dongle issued by the same developer (`.Developer`).
Scope :: enum i32 {
	Device    = 0,
	Developer = 1,
}

// Dongle is an open dongle: the flat API's handle, 0 once closed.
Dongle :: struct {
	handle: i32,
}

// ---- helpers ----------------------------------------------------------------

// c_string returns the text before the first NUL byte of `buffer` (all of it
// when there is none), without copying.
@(private)
c_string :: proc(buffer: []u8) -> string {
	end := bytes.index_byte(buffer, 0)
	return string(buffer[:end]) if end >= 0 else string(buffer)
}

// input returns a pointer the library can read even for empty data.
@(private)
input :: proc(data: []u8, spare: ^u8) -> [^]u8 {
	return raw_data(data) if len(data) > 0 else ([^]u8)(spare)
}

@(private)
Sized_Call :: enum {
	Record_Read,
	App_Encrypt,
	App_Decrypt,
}

@(private)
Sized_Arguments :: struct {
	call:   Sized_Call,
	handle: i32,
	name:   cstring,
	data:   [^]u8,
	length: i32,
	scope:  i32,
}

@(private)
sized_call :: proc(a: ^Api, args: Sized_Arguments, buffer: [^]u8, capacity: i32, needed: ^i32) -> i32 {
	switch args.call {
	case .Record_Read:
		return a.record_read(args.handle, args.name, buffer, capacity, needed)
	case .App_Encrypt:
		return a.app_encrypt(args.handle, args.scope, args.data, args.length, buffer, capacity, needed)
	case .App_Decrypt:
		return a.app_decrypt(args.handle, args.data, args.length, buffer, capacity, needed)
	}
	return i32(Status.Internal)
}

// read_sized follows the two-call convention: it asks for the size with a
// capacity of 0, then reads into a buffer of that size.
@(private)
read_sized :: proc(a: ^Api, args: Sized_Arguments, allocator := context.allocator) -> (data: []u8, err: Error) {
	needed: i32
	spare: u8
	rc := sized_call(a, args, ([^]u8)(&spare), 0, &needed)
	if rc == 0 {
		return make([]u8, 0, allocator), nil
	}
	if rc != i32(Status.Range) {
		return nil, error_from_code(rc)
	}
	buffer := make([]u8, max(int(needed), 1), allocator)
	rc = sized_call(a, args, raw_data(buffer), needed, &needed)
	if rc != 0 {
		delete(buffer, allocator)
		return nil, error_from_code(rc)
	}
	return buffer[:int(needed)], nil
}

// ---- the library and status codes -------------------------------------------

// library_version returns the native library's version.
@(require_results)
library_version :: proc() -> (version: Version, err: Error) {
	a := api() or_return
	major, minor, patch: i32
	error_from_code(a.version(&major, &minor, &patch)) or_return
	return {int(major), int(minor), int(patch)}, nil
}

// status_text returns human-readable text for a status code; it needs no
// dongle. Without the library it returns the status's name.
status_text :: proc(status: Status, allocator := context.allocator) -> string {
	a, err := api()
	text: [ERROR_SIZE]u8
	if err != nil || a.strerror(i32(status), &text[0], ERROR_SIZE) != 0 {
		return strings.clone(reflect.enum_string(status), allocator)
	}
	return strings.clone(c_string(text[:]), allocator)
}

// error_message returns text for an error: the library's text for a
// `Status`, what was tried for a `Library_Error`, empty for nil.
error_message :: proc(err: Error, allocator := context.allocator) -> string {
	switch e in err {
	case Status:
		return status_text(e, allocator)
	case Library_Error:
		return library_error_detail(allocator)
	}
	return strings.clone("", allocator)
}

// ---- discovery and opening ----------------------------------------------------

// devices returns the attached dongles. Free the list with `delete_devices`.
@(require_results)
devices :: proc(allocator := context.allocator) -> (list: []Device, err: Error) {
	a := api() or_return
	count: i32
	error_from_code(a.device_count(&count)) or_return
	out := make([dynamic]Device, 0, int(count), allocator)
	text: [PATH_SIZE]u8
	for i in 0 ..< count {
		rc := a.device_serial(i, &text[0], PATH_SIZE)
		if rc != 0 {
			delete_devices(out[:], allocator)
			return nil, error_from_code(rc)
		}
		serial := strings.clone(c_string(text[:]), allocator)
		rc = a.device_path(i, &text[0], PATH_SIZE)
		if rc != 0 {
			delete(serial, allocator)
			delete_devices(out[:], allocator)
			return nil, error_from_code(rc)
		}
		append(&out, Device{serial, strings.clone(c_string(text[:]), allocator)})
	}
	return out[:], nil
}

// delete_devices frees a list from `devices`.
delete_devices :: proc(list: []Device, allocator := context.allocator) {
	for device in list {
		delete(device.serial, allocator)
		delete(device.path, allocator)
	}
	delete(list, allocator)
}

// open opens the dongle with this serial, or the first one found when
// `serial` is empty. Close it with `close`, for instance with
// `defer kn.close(&d)`.
@(require_results)
open :: proc(serial := "") -> (d: Dongle, err: Error) {
	a := api() or_return
	text := strings.clone_to_cstring(serial)
	defer delete(text)
	handle := a.open(text)
	if handle < 0 {
		return {}, error_from_code(handle)
	}
	return {handle}, nil
}

// open_path opens the dongle at this device path (from `devices`).
@(require_results)
open_path :: proc(path: string) -> (d: Dongle, err: Error) {
	a := api() or_return
	text := strings.clone_to_cstring(path)
	defer delete(text)
	handle := a.open_path(text)
	if handle < 0 {
		return {}, error_from_code(handle)
	}
	return {handle}, nil
}

// is_open reports whether `close` has not been called yet.
is_open :: proc(d: Dongle) -> bool {
	return d.handle > 0
}

// close closes the dongle; further calls fail with `.Invalid_Arg`. Calling it
// again does nothing.
close :: proc(d: ^Dongle) {
	handle := d.handle
	if handle <= 0 {
		return
	}
	d.handle = 0
	a, err := api()
	if err == nil {
		a.close(handle)
	}
}

// ---- plaintext information and authenticity ----------------------------------

// serial returns the dongle's serial number (14 hex digits).
@(require_results)
serial :: proc(d: Dongle, allocator := context.allocator) -> (text: string, err: Error) {
	a := api() or_return
	buffer: [SERIAL_SIZE]u8
	error_from_code(a.get_serial(d.handle, &buffer[0], SERIAL_SIZE)) or_return
	return strings.clone(c_string(buffer[:]), allocator), nil
}

// info returns the plaintext device information.
@(require_results)
info :: proc(d: Dongle) -> (result: Device_Info, err: Error) {
	a := api() or_return
	pa, pb, fa, fb, fc, flags, capacity, free: i32
	error_from_code(a.get_info(d.handle, &pa, &pb, &fa, &fb, &fc, &flags, &capacity, &free)) or_return
	return {
			protocol_major = int(pa),
			protocol_minor = int(pb),
			firmware_major = int(fa),
			firmware_minor = int(fb),
			firmware_patch = int(fc),
			secure_element_ready = flags & FLAG_SECURE_ELEMENT_READY != 0,
			provisioned = flags & FLAG_PROVISIONED != 0,
			watchdog_reboot = flags & FLAG_WATCHDOG_REBOOT != 0,
			isolated = flags & FLAG_ISOLATED != 0,
			write_auth_rotated = flags & FLAG_WRITE_AUTH_ROTATED != 0,
			data_capacity = int(capacity),
			data_free = int(free),
		},
		nil
}

// verify_genuine proves the dongle is genuine: certificate chain to the
// trusted root plus a live challenge-response. It returns nil only when it
// is. Free the result with `delete_verification`.
@(require_results)
verify_genuine :: proc(d: Dongle, allocator := context.allocator) -> (result: Verification, err: Error) {
	a := api() or_return
	genuine: i32
	serial: [SERIAL_SIZE]u8
	date: [DATE_SIZE]u8
	error_from_code(a.verify_genuine(d.handle, &genuine, &serial[0], SERIAL_SIZE, &date[0], DATE_SIZE)) or_return
	if genuine == 0 {
		return {}, Status.Not_Genuine
	}
	return {strings.clone(c_string(serial[:]), allocator), strings.clone(c_string(date[:]), allocator)}, nil
}

// delete_verification frees a result of `verify_genuine`.
delete_verification :: proc(v: Verification, allocator := context.allocator) {
	delete(v.serial, allocator)
	delete(v.provisioned_date, allocator)
}

// is_genuine is the boolean form for a gate: true only when `verify_genuine`
// succeeds. It fails closed: every failure gives false.
is_genuine :: proc(d: Dongle) -> bool {
	v, err := verify_genuine(d)
	if err != nil {
		return false
	}
	delete_verification(v)
	return true
}

// set_trust_root overrides the CA root that `verify_genuine` checks against
// (DER).
@(require_results)
set_trust_root :: proc(d: Dongle, der: []u8) -> Error {
	a := api() or_return
	spare: u8
	return error_from_code(a.set_trust_root(d.handle, input(der, &spare), i32(len(der))))
}

// last_error returns diagnostic detail for the most recent failure on this
// dongle; it may be empty.
last_error :: proc(d: Dongle, allocator := context.allocator) -> string {
	a, err := api()
	text: [ERROR_SIZE]u8
	if err != nil || a.last_error(d.handle, &text[0], ERROR_SIZE) != 0 {
		return strings.clone("", allocator)
	}
	return strings.clone(c_string(text[:]), allocator)
}

// ---- sessions and the write role ------------------------------------------------

// open_session opens an authenticated session; records, counters and app
// crypto need one. Close it with `close_session`, for instance with
// `defer kn.close_session(d)`.
@(require_results)
open_session :: proc(d: Dongle) -> Error {
	a := api() or_return
	return error_from_code(a.session_open(d.handle))
}

// close_session closes the session, if one is open.
close_session :: proc(d: Dongle) {
	a, err := api()
	if err == nil {
		a.session_close(d.handle)
	}
}

// authorize_write elevates the session to the write role with a write-auth
// key (P-256 PKCS#8 DER).
@(require_results)
authorize_write :: proc(d: Dongle, key: []u8) -> Error {
	a := api() or_return
	spare: u8
	return error_from_code(a.write_auth(d.handle, input(key, &spare), i32(len(key))))
}

// rotate_write_key replaces the dongle's write-auth key with `key` (P-256
// PKCS#8 DER). Call `authorize_write` first. From the next session on, only
// the new key elevates.
@(require_results)
rotate_write_key :: proc(d: Dongle, key: []u8) -> Error {
	a := api() or_return
	spare: u8
	return error_from_code(a.write_auth_rotate(d.handle, input(key, &spare), i32(len(key))))
}

// ---- records ----------------------------------------------------------------------

// records returns the records on the dongle. Free the list with
// `delete_records`.
@(require_results)
records :: proc(d: Dongle, allocator := context.allocator) -> (list: []Record, err: Error) {
	a := api() or_return
	count: i32
	error_from_code(a.record_count(d.handle, &count)) or_return
	out := make([dynamic]Record, 0, int(count), allocator)
	text: [NAME_SIZE]u8
	for i in 0 ..< count {
		size: i32
		rc := a.record_name(d.handle, i, &text[0], NAME_SIZE, &size)
		if rc != 0 {
			delete_records(out[:], allocator)
			return nil, error_from_code(rc)
		}
		append(&out, Record{strings.clone(c_string(text[:]), allocator), int(size)})
	}
	return out[:], nil
}

// delete_records frees a list from `records`.
delete_records :: proc(list: []Record, allocator := context.allocator) {
	for record in list {
		delete(record.name, allocator)
	}
	delete(list, allocator)
}

// read_record returns the content of a record.
@(require_results)
read_record :: proc(d: Dongle, name: string, allocator := context.allocator) -> (data: []u8, err: Error) {
	a := api() or_return
	text := strings.clone_to_cstring(name)
	defer delete(text)
	return read_sized(a, {call = .Record_Read, handle = d.handle, name = text}, allocator)
}

// write_record writes a record, replacing one of the same name. It needs the
// write role.
@(require_results)
write_record :: proc(d: Dongle, name: string, data: []u8) -> Error {
	a := api() or_return
	text := strings.clone_to_cstring(name)
	defer delete(text)
	spare: u8
	return error_from_code(a.record_write(d.handle, text, input(data, &spare), i32(len(data))))
}

// erase_record erases one record. It needs the write role.
@(require_results)
erase_record :: proc(d: Dongle, name: string) -> Error {
	a := api() or_return
	text := strings.clone_to_cstring(name)
	defer delete(text)
	return error_from_code(a.record_erase(d.handle, text))
}

// erase_all_records erases every record. It needs the write role.
@(require_results)
erase_all_records :: proc(d: Dongle) -> Error {
	a := api() or_return
	return error_from_code(a.record_erase_all(d.handle))
}

// ---- counters -----------------------------------------------------------------------

// read_counter returns the value of a hardware monotonic counter.
@(require_results)
read_counter :: proc(d: Dongle, counter_id: int) -> (value: int, err: Error) {
	a := api() or_return
	result: i32
	error_from_code(a.counter_read(d.handle, i32(counter_id), &result)) or_return
	return int(result), nil
}

// increment_counter increments a counter and returns the new value. It needs
// the write role.
@(require_results)
increment_counter :: proc(d: Dongle, counter_id: int) -> (value: int, err: Error) {
	a := api() or_return
	result: i32
	error_from_code(a.counter_increment(d.handle, i32(counter_id), &result)) or_return
	return int(result), nil
}

// ---- app-data encryption ------------------------------------------------------------

// app_encrypt seals `plaintext` so that only a dongle can open it: this one
// (`.Device`) or any dongle issued by the same developer (`.Developer`).
@(require_results)
app_encrypt :: proc(d: Dongle, scope: Scope, plaintext: []u8, allocator := context.allocator) -> (sealed: []u8, err: Error) {
	a := api() or_return
	spare: u8
	args := Sized_Arguments {
		call   = .App_Encrypt,
		handle = d.handle,
		data   = input(plaintext, &spare),
		length = i32(len(plaintext)),
		scope  = i32(scope),
	}
	return read_sized(a, args, allocator)
}

// app_decrypt opens data sealed with `app_encrypt`.
@(require_results)
app_decrypt :: proc(d: Dongle, packed: []u8, allocator := context.allocator) -> (plaintext: []u8, err: Error) {
	a := api() or_return
	spare: u8
	args := Sized_Arguments {
		call   = .App_Decrypt,
		handle = d.handle,
		data   = input(packed, &spare),
		length = i32(len(packed)),
	}
	return read_sized(a, args, allocator)
}
