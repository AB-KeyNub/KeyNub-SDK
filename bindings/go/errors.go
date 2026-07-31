package keynub

import "fmt"

/*
#include <licdongle.h>
*/
import "C"

// Status is why an operation failed. Mirrors licd_status.
type Status int

// The status codes the SDK can report.
const (
	StatusOK                   Status = 0
	StatusInvalidArgument      Status = -1
	StatusNoDevice             Status = -2
	StatusAccessDenied         Status = -3
	StatusIO                   Status = -4
	StatusTimeout              Status = -5
	StatusProtocol             Status = -6
	StatusNotGenuine           Status = -7
	StatusCertificateInvalid   Status = -8
	StatusSessionExpired       Status = -9
	StatusTagMismatch          Status = -10
	StatusRange                Status = -11
	StatusStorageFull          Status = -12
	StatusBusy                 Status = -13
	StatusNotFound             Status = -14
	StatusAuthRequired         Status = -15
	StatusFirmwareIncompatible Status = -16
	StatusSDKTooOld            Status = -17
	StatusCancelled            Status = -18
	StatusNotImplemented       Status = -19
	StatusInternal             Status = -20
)

// String is the SDK's own text for the status.
func (s Status) String() string {
	return C.GoString(C.licd_strerror(C.int(s)))
}

// Error is a failed dongle operation.
type Error struct {
	// Status says which failure this is. Compare with errors.Is and one of the
	// sentinels below, or switch on this directly.
	Status Status
	// Op is the C function that failed.
	Op string
	// Detail is the SDK's diagnostic text, or empty. Log it; do not parse it.
	Detail string
}

func newError(status int, op, detail string) *Error {
	return &Error{Status: Status(status), Op: op, Detail: detail}
}

func (e *Error) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("%s: %s (%s)", e.Op, e.Status, e.Detail)
	}
	return fmt.Sprintf("%s: %s", e.Op, e.Status)
}

// Is makes errors.Is(err, ErrNoDevice) work: two errors match when they report
// the same status, whichever call produced them.
func (e *Error) Is(target error) bool {
	other, ok := target.(*Error)
	return ok && other.Status == e.Status
}

// Sentinels for errors.Is. Only the statuses a caller plausibly branches on are
// named; for the rest, compare Error.Status directly.
var (
	// ErrNoDevice: no matching dongle was found or present.
	ErrNoDevice = &Error{Status: StatusNoDevice}
	// ErrAccessDenied: the OS refused the device (a missing udev rule on Linux).
	ErrAccessDenied = &Error{Status: StatusAccessDenied}
	// ErrNotGenuine: the authenticity check failed.
	ErrNotGenuine = &Error{Status: StatusNotGenuine}
	// ErrCertificateInvalid: the device certificate or its chain was invalid.
	ErrCertificateInvalid = &Error{Status: StatusCertificateInvalid}
	// ErrSessionExpired: no session, or it expired.
	ErrSessionExpired = &Error{Status: StatusSessionExpired}
	// ErrNotFound: the named record does not exist.
	ErrNotFound = &Error{Status: StatusNotFound}
	// ErrAuthRequired: the operation needs the write role.
	ErrAuthRequired = &Error{Status: StatusAuthRequired}
	// ErrCancelled: a progress callback cancelled the transfer.
	ErrCancelled = &Error{Status: StatusCancelled}
	// ErrTagMismatch: AEAD verification failed — the data was tampered with.
	ErrTagMismatch = &Error{Status: StatusTagMismatch}
)
