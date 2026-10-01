module keynub_licdongle

// Status names the SDK's status codes. `unknown` stands for a code this
// module does not know.
pub enum Status {
	ok              = 0
	invalid_arg     = -1
	no_device       = -2
	access_denied   = -3
	io              = -4
	timeout         = -5
	protocol        = -6
	not_genuine     = -7
	cert_invalid    = -8
	session_expired = -9
	tag_mismatch    = -10
	range           = -11
	storage_full    = -12
	busy            = -13
	not_found       = -14
	auth_required   = -15
	fw_incompatible = -16
	sdk_too_old     = -17
	cancelled       = -18
	not_implemented = -19
	internal        = -20
	unknown         = 1
}

// status_from_code returns the status with this code, or none for a code this
// module does not know.
pub fn status_from_code(code int) ?Status {
	if code >= -20 && code <= 0 {
		return unsafe { Status(code) }
	}
	return none
}

// code returns the status's numeric value.
pub fn (s Status) code() int {
	return int(s)
}

// DongleError is a failed dongle call: the status, the raw code (`code()`),
// the operation (the flat API function) and the library's detail text, which
// may be empty.
pub struct DongleError {
	Error
pub:
	status    Status
	raw_code  int
	operation string
	detail    string
}

// msg returns "operation: status (code)", followed by ": detail" when there is
// one.
pub fn (e DongleError) msg() string {
	text := '${e.operation}: ${e.status} (${e.raw_code})'
	return if e.detail == '' { text } else { '${text}: ${e.detail}' }
}

// code returns the raw status code.
pub fn (e DongleError) code() int {
	return e.raw_code
}

// LibraryError reports that the native library could not be loaded, or does
// not fit.
pub struct LibraryError {
	Error
pub:
	detail string
}

// msg returns what was tried and why it failed.
pub fn (e LibraryError) msg() string {
	return e.detail
}

fn dongle_error(operation string, code int, detail string) DongleError {
	return DongleError{
		status:    status_from_code(code) or { Status.unknown }
		raw_code:  code
		operation: operation
		detail:    detail
	}
}

// c_string returns the text before the first NUL byte of `buffer` (all of it
// when there is none).
fn c_string(buffer []u8) string {
	end := buffer.index(0)
	return if end < 0 { buffer.bytestr() } else { buffer[..end].bytestr() }
}
