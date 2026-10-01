// KeyNub License Dongle: verify that a dongle is genuine, read and write the
// license records it holds, use its hardware counters and encrypt data so that
// only a dongle can decrypt it. Calls the SDK's flat C API through a library
// loaded at run time (see library.v); nothing is linked.
module keynub_licdongle

// Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
// LICDF_ERROR_SIZE), and one for a record name.
const serial_size = 15
const date_size = 11
const path_size = 512
const error_size = 256
const name_size = 256

// Bits in the flags value of licdf_get_info.
const flag_secure_element_ready = 0x01
const flag_provisioned = 0x02
const flag_watchdog_reboot = 0x04
const flag_isolated = 0x08
const flag_write_auth_rotated = 0x10

// Version is the native library's version.
pub struct Version {
pub:
	major int
	minor int
	patch int
}

// str returns "major.minor.patch".
pub fn (v Version) str() string {
	return '${v.major}.${v.minor}.${v.patch}'
}

// Device is an attached dongle.
pub struct Device {
pub:
	serial string
	path   string
}

// DeviceInfo is the plaintext device information.
pub struct DeviceInfo {
pub:
	protocol_major       int
	protocol_minor       int
	firmware_major       int
	firmware_minor       int
	firmware_patch       int
	secure_element_ready bool
	provisioned          bool
	watchdog_reboot      bool
	isolated             bool
	write_auth_rotated   bool
	data_capacity        int
	data_free            int
}

// Verification is the result of a successful `verify_genuine`.
pub struct Verification {
pub:
	serial           string
	provisioned_date string
}

// Record is a record on the dongle.
pub struct Record {
pub:
	name string
	size int
}

// Scope says which dongles can open data sealed with `app_encrypt`: this one
// (`device`) or any dongle issued by the same developer (`developer`).
pub enum Scope {
	device
	developer
}

// Dongle is an open dongle: the flat API's handle, 0 once closed.
@[heap]
pub struct Dongle {
mut:
	handle int
}

// ---- helpers --------------------------------------------------------------

fn check(operation string, handle int, rc i32) ! {
	if rc != 0 {
		return dongle_error(operation, int(rc), if handle > 0 { detail_of(handle) } else { '' })
	}
}

fn detail_of(handle int) string {
	a := api() or { return '' }
	mut text := []u8{len: error_size}
	if a.last_error(i32(handle), &u8(text.data), error_size) != 0 {
		return ''
	}
	return c_string(text)
}

// c_text returns `s` as a NUL-terminated byte buffer.
fn c_text(s string) []u8 {
	mut out := s.bytes()
	out << 0
	return out
}

// input returns a buffer the library can read even for empty data.
fn input(data []u8) []u8 {
	return if data.len == 0 { []u8{len: 1} } else { data }
}

// read_sized follows the two-call convention: it asks for the size with a
// capacity of 0, then reads into a buffer of that size. `call` takes the
// buffer, its capacity and the length out-parameter, and returns the status.
fn read_sized(handle int, operation string, call fn (&u8, i32, &i32) i32) ![]u8 {
	mut needed := i32(0)
	mut empty := []u8{len: 1}
	rc := call(&u8(empty.data), 0, &needed)
	if rc == 0 {
		return []u8{}
	}
	if rc != i32(Status.range) {
		return dongle_error(operation, int(rc), detail_of(handle))
	}
	mut data := []u8{len: if needed > 0 { int(needed) } else { 1 }}
	rc2 := call(&u8(data.data), needed, &needed)
	if rc2 != 0 {
		return dongle_error(operation, int(rc2), detail_of(handle))
	}
	return data[..int(needed)].clone()
}

// ---- the library and status codes -----------------------------------------

// library_version returns the native library's version.
pub fn library_version() !Version {
	a := api()!
	mut major, mut minor, mut patch := i32(0), i32(0), i32(0)
	check('licdf_version', 0, a.version(&major, &minor, &patch))!
	return Version{int(major), int(minor), int(patch)}
}

// status_text returns human-readable text for a status code; it needs no
// dongle.
pub fn status_text(code int) string {
	a := api() or { return (status_from_code(code) or { Status.unknown }).str() }
	mut text := []u8{len: error_size}
	if a.strerror(i32(code), &u8(text.data), error_size) != 0 {
		return (status_from_code(code) or { Status.unknown }).str()
	}
	return c_string(text)
}

// ---- discovery and opening -------------------------------------------------

// devices returns the attached dongles.
pub fn devices() ![]Device {
	a := api()!
	mut count := i32(0)
	check('licdf_device_count', 0, a.device_count(&count))!
	mut out := []Device{}
	mut text := []u8{len: path_size}
	for i in 0 .. int(count) {
		check('licdf_device_serial', 0, a.device_serial(i32(i), &u8(text.data), path_size))!
		serial := c_string(text)
		check('licdf_device_path', 0, a.device_path(i32(i), &u8(text.data), path_size))!
		out << Device{serial, c_string(text)}
	}
	return out
}

// open opens the dongle with this serial, or the first one found when
// `serial` is empty. Close it with `close`, for instance with
// `defer { d.close() }`.
pub fn open(serial string) !&Dongle {
	a := api()!
	text := c_text(serial)
	handle := a.open(&u8(text.data))
	if handle < 0 {
		return dongle_error('licdf_open', int(handle), '')
	}
	return &Dongle{
		handle: int(handle)
	}
}

// open_path opens the dongle at this device path (from `devices`).
pub fn open_path(path string) !&Dongle {
	a := api()!
	text := c_text(path)
	handle := a.open_path(&u8(text.data))
	if handle < 0 {
		return dongle_error('licdf_open_path', int(handle), '')
	}
	return &Dongle{
		handle: int(handle)
	}
}

// is_open reports whether `close` has not been called yet.
pub fn (d &Dongle) is_open() bool {
	return d.handle > 0
}

// close closes the dongle; further calls fail with `.invalid_arg`. Calling it
// again does nothing.
pub fn (mut d Dongle) close() {
	handle := d.handle
	if handle <= 0 {
		return
	}
	d.handle = 0
	a := api() or { return }
	a.close(i32(handle))
}

// ---- plaintext information and authenticity --------------------------------

// serial returns the dongle's serial number (14 hex digits).
pub fn (d &Dongle) serial() !string {
	a := api()!
	mut text := []u8{len: serial_size}
	check('licdf_get_serial', d.handle, a.get_serial(i32(d.handle), &u8(text.data), serial_size))!
	return c_string(text)
}

// info returns the plaintext device information.
pub fn (d &Dongle) info() !DeviceInfo {
	a := api()!
	mut pa, mut pb, mut fa, mut fb, mut fc := i32(0), i32(0), i32(0), i32(0), i32(0)
	mut flags, mut capacity, mut free := i32(0), i32(0), i32(0)
	check('licdf_get_info', d.handle, a.get_info(i32(d.handle), &pa, &pb, &fa, &fb, &fc, &flags,
		&capacity, &free))!
	return DeviceInfo{
		protocol_major:       int(pa)
		protocol_minor:       int(pb)
		firmware_major:       int(fa)
		firmware_minor:       int(fb)
		firmware_patch:       int(fc)
		secure_element_ready: flags & flag_secure_element_ready != 0
		provisioned:          flags & flag_provisioned != 0
		watchdog_reboot:      flags & flag_watchdog_reboot != 0
		isolated:             flags & flag_isolated != 0
		write_auth_rotated:   flags & flag_write_auth_rotated != 0
		data_capacity:        int(capacity)
		data_free:            int(free)
	}
}

// verify_genuine proves the dongle is genuine: certificate chain to the
// trusted root plus a live challenge-response. It returns only when it is,
// and an error otherwise.
pub fn (d &Dongle) verify_genuine() !Verification {
	a := api()!
	mut genuine := i32(0)
	mut serial := []u8{len: serial_size}
	mut date := []u8{len: date_size}
	check('licdf_verify_genuine', d.handle, a.verify_genuine(i32(d.handle), &genuine,
		&u8(serial.data), serial_size, &u8(date.data), date_size))!
	if genuine == 0 {
		return dongle_error('licdf_verify_genuine', Status.not_genuine.code(), '')
	}
	return Verification{c_string(serial), c_string(date)}
}

// is_genuine is the boolean form for a gate: true only when `verify_genuine`
// succeeds. It fails closed: every failure gives false.
pub fn (d &Dongle) is_genuine() bool {
	d.verify_genuine() or { return false }
	return true
}

// set_trust_root overrides the CA root that `verify_genuine` checks against
// (DER).
pub fn (d &Dongle) set_trust_root(der []u8) ! {
	a := api()!
	data := input(der)
	check('licdf_set_trust_root', d.handle, a.set_trust_root(i32(d.handle), &u8(data.data),
		i32(der.len)))!
}

// last_error returns diagnostic detail for the most recent failure on this
// dongle; it may be empty.
pub fn (d &Dongle) last_error() string {
	return detail_of(d.handle)
}

// ---- sessions and the write role -------------------------------------------

// open_session opens an authenticated session; records, counters and app
// crypto need one. Close it with `close_session`, for instance with
// `defer { d.close_session() }`.
pub fn (d &Dongle) open_session() ! {
	a := api()!
	check('licdf_session_open', d.handle, a.session_open(i32(d.handle)))!
}

// close_session closes the session, if one is open.
pub fn (d &Dongle) close_session() {
	a := api() or { return }
	a.session_close(i32(d.handle))
}

// authorize_write elevates the session to the write role with a write-auth
// key (P-256 PKCS#8 DER).
pub fn (d &Dongle) authorize_write(key []u8) ! {
	a := api()!
	data := input(key)
	check('licdf_write_auth', d.handle, a.write_auth(i32(d.handle), &u8(data.data), i32(key.len)))!
}

// rotate_write_key replaces the dongle's write-auth key with `key` (P-256
// PKCS#8 DER). Call `authorize_write` first. From the next session on, only
// the new key elevates.
pub fn (d &Dongle) rotate_write_key(key []u8) ! {
	a := api()!
	data := input(key)
	check('licdf_write_auth_rotate', d.handle, a.write_auth_rotate(i32(d.handle), &u8(data.data),
		i32(key.len)))!
}

// ---- records ----------------------------------------------------------------

// records returns the records on the dongle.
pub fn (d &Dongle) records() ![]Record {
	a := api()!
	mut count := i32(0)
	check('licdf_record_count', d.handle, a.record_count(i32(d.handle), &count))!
	mut out := []Record{}
	mut text := []u8{len: name_size}
	for i in 0 .. int(count) {
		mut size := i32(0)
		check('licdf_record_name', d.handle, a.record_name(i32(d.handle), i32(i), &u8(text.data),
			name_size, &size))!
		out << Record{c_string(text), int(size)}
	}
	return out
}

// read_record returns the content of a record.
pub fn (d &Dongle) read_record(name string) ![]u8 {
	a := api()!
	text := c_text(name)
	handle := d.handle
	return read_sized(handle, 'licdf_record_read', fn [a, text, handle] (buffer &u8, capacity i32, needed &i32) i32 {
		return a.record_read(i32(handle), &u8(text.data), buffer, capacity, needed)
	})
}

// write_record writes a record, replacing one of the same name. It needs the
// write role.
pub fn (d &Dongle) write_record(name string, data []u8) ! {
	a := api()!
	text := c_text(name)
	bytes := input(data)
	check('licdf_record_write', d.handle, a.record_write(i32(d.handle), &u8(text.data),
		&u8(bytes.data), i32(data.len)))!
}

// erase_record erases one record. It needs the write role.
pub fn (d &Dongle) erase_record(name string) ! {
	a := api()!
	text := c_text(name)
	check('licdf_record_erase', d.handle, a.record_erase(i32(d.handle), &u8(text.data)))!
}

// erase_all_records erases every record. It needs the write role.
pub fn (d &Dongle) erase_all_records() ! {
	a := api()!
	check('licdf_record_erase_all', d.handle, a.record_erase_all(i32(d.handle)))!
}

// ---- counters ---------------------------------------------------------------

// read_counter returns the value of a hardware monotonic counter.
pub fn (d &Dongle) read_counter(counter_id int) !int {
	a := api()!
	mut value := i32(0)
	check('licdf_counter_read', d.handle, a.counter_read(i32(d.handle), i32(counter_id), &value))!
	return int(value)
}

// increment_counter increments a counter and returns the new value. It needs
// the write role.
pub fn (d &Dongle) increment_counter(counter_id int) !int {
	a := api()!
	mut value := i32(0)
	check('licdf_counter_increment', d.handle, a.counter_increment(i32(d.handle), i32(counter_id),
		&value))!
	return int(value)
}

// ---- app-data encryption ----------------------------------------------------

// app_encrypt seals `plaintext` so that only a dongle can open it: this one
// (`.device`) or any dongle issued by the same developer (`.developer`).
pub fn (d &Dongle) app_encrypt(scope Scope, plaintext []u8) ![]u8 {
	a := api()!
	data := input(plaintext)
	length := i32(plaintext.len)
	scope_value := if scope == .device { i32(0) } else { i32(1) }
	handle := d.handle
	return read_sized(handle, 'licdf_app_encrypt', fn [a, data, length, scope_value, handle] (buffer &u8, capacity i32, needed &i32) i32 {
		return a.app_encrypt(i32(handle), scope_value, &u8(data.data), length, buffer, capacity,
			needed)
	})
}

// app_decrypt opens data sealed with `app_encrypt`.
pub fn (d &Dongle) app_decrypt(packed []u8) ![]u8 {
	a := api()!
	data := input(packed)
	length := i32(packed.len)
	handle := d.handle
	return read_sized(handle, 'licdf_app_decrypt', fn [a, data, length, handle] (buffer &u8, capacity i32, needed &i32) i32 {
		return a.app_decrypt(i32(handle), &u8(data.data), length, buffer, capacity, needed)
	})
}
