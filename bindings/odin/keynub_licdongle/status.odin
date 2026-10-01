package keynub_licdongle

// Status names the SDK's status codes. A call that succeeds returns a nil
// `Error`, never `.Ok`; `.Unknown` stands for a code this package does not
// know.
Status :: enum i32 {
	Ok              = 0,
	Invalid_Arg     = -1,
	No_Device       = -2,
	Access_Denied   = -3,
	Io              = -4,
	Timeout         = -5,
	Protocol        = -6,
	Not_Genuine     = -7,
	Cert_Invalid    = -8,
	Session_Expired = -9,
	Tag_Mismatch    = -10,
	Range           = -11,
	Storage_Full    = -12,
	Busy            = -13,
	Not_Found       = -14,
	Auth_Required   = -15,
	Fw_Incompatible = -16,
	Sdk_Too_Old     = -17,
	Cancelled       = -18,
	Not_Implemented = -19,
	Internal        = -20,
	Unknown         = 1,
}

// Library_Error reports that the native library could not be loaded
// (`.Load_Failed`), or that `set_library_path` named a different file after
// one was loaded (`.Already_Loaded`). `library_error_detail` returns the text.
Library_Error :: enum i32 {
	None,
	Load_Failed,
	Already_Loaded,
}

// Error is what every call that can fail returns: nil on success, a `Status`
// for a failed dongle call, a `Library_Error` for a loading problem.
//
//	if err == kn.Status.No_Device { ... }
Error :: union #shared_nil {
	Status,
	Library_Error,
}

// status_from_code returns the status with this code; ok is false (and the
// status `.Unknown`) for a code this package does not know.
status_from_code :: proc "contextless" (code: i32) -> (status: Status, ok: bool) {
	if code >= -20 && code <= 0 {
		return Status(code), true
	}
	return .Unknown, false
}

// error_from_code returns the error for a status code: nil for 0.
error_from_code :: proc "contextless" (code: i32) -> Error {
	if code == 0 {
		return nil
	}
	status, _ := status_from_code(code)
	return status
}

// status_of returns the status an error carries: `.Ok` for nil, `.Unknown`
// for a `Library_Error`.
status_of :: proc "contextless" (err: Error) -> Status {
	switch e in err {
	case Status:
		return e
	case Library_Error:
		return .Unknown
	}
	return .Ok
}
