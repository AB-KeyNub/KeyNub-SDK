// Package keynub is the Go binding for the KeyNub USB-C license dongle.
//
//	ctx, err := keynub.NewContext()
//	defer ctx.Close()
//
//	dongle, err := ctx.Open("")        // first dongle, or a serial
//	defer dongle.Close()
//	if _, err := dongle.VerifyGenuine(); err != nil { ... }
//
//	session, err := dongle.OpenSession()
//	defer session.Close()
//	data, err := session.AppDecrypt(blob)   // <- build the licence check on this
//
// Building needs the native library. Its location is not knowable at compile
// time, so pass it in:
//
//	CGO_LDFLAGS="-L/path/to/native/" go build
//
// Read docs/integration-security.md before deciding where the check goes.
// `if licensed { }` is one line to delete from a Go binary too — route something
// the program needs through AppEncrypt/AppDecrypt instead.
package keynub

/*
#cgo CFLAGS: -I${SRCDIR}/../../include

#include <stdlib.h>
#include <string.h>
#include <licdongle.h>

// Declared here, defined in Go (see progress.go). cgo forbids a file with
// //export from having definitions in its preamble, so the small wrappers below
// live in this file and the exported Go function lives in that one.
extern int keynubProgressBridge(uint32_t done, uint32_t total, void *user);

// The progress-taking calls are wrapped so Go never has to build a C function
// pointer, and so the cgo.Handle can travel as a uintptr rather than as a Go
// pointer (which cgo forbids passing to C).
static int keynub_record_read(licd_device *dev, const char *name, void *buf, uint32_t cap,
                              uint32_t *out_len, uint32_t *out_total, uintptr_t user,
                              int with_progress) {
    return licd_record_read(dev, name, 0, buf, cap, out_len, out_total,
                            with_progress ? keynubProgressBridge : NULL, (void *)user);
}

static int keynub_record_write(licd_device *dev, const char *name, const void *data,
                               uint32_t len, uintptr_t user, int with_progress) {
    return licd_record_write(dev, name, data, len,
                             with_progress ? keynubProgressBridge : NULL, (void *)user);
}
*/
import "C"

import (
	"fmt"
	"runtime/cgo"
	"unsafe"
)

// Scope decides who can decrypt data produced by Session.AppEncrypt.
type Scope int

const (
	// ScopeDevice: only this one physical dongle can decrypt.
	ScopeDevice Scope = 0
	// ScopeDeveloper: any dongle from the same developer batch, so one encrypted
	// blob ships to every customer.
	ScopeDeveloper Scope = 1
)

// ProgressFunc reports transfer progress. Return false to cancel, which surfaces
// as StatusCancelled.
type ProgressFunc func(done, total uint32) bool

const serialBufferSize = C.LICD_SERIAL_HEX_LEN + 1

// Context is the library context: the entry point for finding and opening
// dongles. It is safe for concurrent use, per the C ABI's contract.
type Context struct {
	ptr *C.licd_ctx
}

// NewContext creates a library context. Close it when done, after the dongles it
// opened.
func NewContext() (*Context, error) {
	var ptr *C.licd_ctx
	rc := C.licd_init(&ptr)
	if rc != C.LICD_OK {
		return nil, newError(int(rc), "licd_init", "")
	}
	return &Context{ptr: ptr}, nil
}

// LibraryVersion reports the native core's semantic version.
func LibraryVersion() (major, minor, patch int) {
	var a, b, c C.int
	C.licd_version(&a, &b, &c)
	return int(a), int(b), int(c)
}

// Close releases the context. Safe to call more than once.
func (c *Context) Close() error {
	if c != nil && c.ptr != nil {
		C.licd_free(c.ptr)
		c.ptr = nil
	}
	return nil
}

func (c *Context) check(rc C.int, op string) error {
	if rc == C.LICD_OK {
		return nil
	}
	return newError(int(rc), op, c.LastErrorDetail())
}

// LastErrorDetail is the SDK's diagnostic detail for the most recent failure on
// this thread. Log it; do not parse it.
func (c *Context) LastErrorDetail() string {
	if c == nil || c.ptr == nil {
		return ""
	}
	return C.GoString(C.licd_error_detail(c.ptr))
}

// Raw exposes the underlying handle, so this package can be mixed with direct
// cgo calls. Valid only while the Context is open.
func (c *Context) Raw() unsafe.Pointer { return unsafe.Pointer(c.ptr) }

// SetTrustRoot overrides the CA root that VerifyGenuine checks against.
//
// Applications do not need this: a release build embeds the KeyNub production
// root. It exists for dongles provisioned against a different CA, and for
// vendor tooling.
func (c *Context) SetTrustRoot(der []byte) error {
	rc := C.licd_set_trust_root(c.ptr, (*C.uint8_t)(bytePtr(der)), C.size_t(len(der)))
	return c.check(rc, "licd_set_trust_root")
}

// DeviceInfo describes one discovered dongle.
type DeviceInfo struct {
	Serial    string
	Path      string // opaque; pass to OpenPath
	VendorID  uint16
	ProductID uint16
}

// Enumerate lists the connected dongles. An empty slice means none are attached,
// which is a normal result rather than an error.
func (c *Context) Enumerate() ([]DeviceInfo, error) {
	var list *C.licd_device_info
	var count C.size_t
	if err := c.check(C.licd_enumerate(c.ptr, &list, &count), "licd_enumerate"); err != nil {
		return nil, err
	}
	if list == nil || count == 0 {
		return nil, nil
	}
	defer C.licd_free_device_list(list, count)

	out := make([]DeviceInfo, 0, int(count))
	stride := unsafe.Sizeof(*list)
	for i := 0; i < int(count); i++ {
		e := (*C.licd_device_info)(unsafe.Pointer(uintptr(unsafe.Pointer(list)) + uintptr(i)*stride))
		out = append(out, DeviceInfo{
			Serial:    C.GoString(&e.serial[0]),
			Path:      C.GoString(&e.path[0]),
			VendorID:  uint16(e.vendor_id),
			ProductID: uint16(e.product_id),
		})
	}
	return out, nil
}

// Open opens the dongle with this serial, or the first one found when serial is
// empty.
func (c *Context) Open(serial string) (*Dongle, error) {
	var dev *C.licd_device
	var rc C.int
	if serial == "" {
		rc = C.licd_open(c.ptr, nil, &dev)
	} else {
		cs := C.CString(serial)
		defer C.free(unsafe.Pointer(cs))
		rc = C.licd_open(c.ptr, cs, &dev)
	}
	if err := c.check(rc, "licd_open"); err != nil {
		return nil, err
	}
	return &Dongle{ptr: dev, ctx: c}, nil
}

// OpenPath opens a specific dongle by the path from Enumerate.
func (c *Context) OpenPath(path string) (*Dongle, error) {
	cs := C.CString(path)
	defer C.free(unsafe.Pointer(cs))
	var dev *C.licd_device
	if err := c.check(C.licd_open_path(c.ptr, cs, &dev), "licd_open_path"); err != nil {
		return nil, err
	}
	return &Dongle{ptr: dev, ctx: c}, nil
}

// Adopt takes ownership of a device opened through the C ABI directly, so this
// package can be introduced into an existing cgo codebase a call at a time. The
// returned Dongle closes it.
func (c *Context) Adopt(dev unsafe.Pointer) *Dongle {
	return &Dongle{ptr: (*C.licd_device)(dev), ctx: c}
}

// Info is the plaintext device info from Dongle.Info.
type Info struct {
	ProtocolMajor uint8
	ProtocolMinor uint8
	FirmwareMajor uint8
	FirmwareMinor uint8
	FirmwarePatch uint8
	SeReady    bool
	Provisioned   bool
	DataCapacity  uint32
	DataFree      uint32
	// WatchdogReboot reports that the dongle's *previous* boot ended in a
	// watchdog timeout: the firmware hung and reset itself. It is the only trace
	// a field hang leaves behind, and a power cycle clears it, so log it.
	WatchdogReboot bool
	// Isolated reports that the dongle confirmed at boot that its USB and parsing code is fenced off
	// from keys and storage. The software simulator reports false.
	Isolated bool
}

// GenuineResult is the verified identity from Dongle.VerifyGenuine.
type GenuineResult struct {
	Genuine         bool
	Serial          string
	Batch           string
	ProvisionedDate string // "YYYY-MM-DD", or empty
}

// RecordInfo describes a record stored on the dongle.
type RecordInfo struct {
	Name string
	Size uint32
}

// Dongle is an open connection to a dongle. Use it from one goroutine at a time.
type Dongle struct {
	ptr *C.licd_device
	ctx *Context
}

// Close releases the dongle. Safe to call more than once.
func (d *Dongle) Close() error {
	if d != nil && d.ptr != nil {
		C.licd_close(d.ptr)
		d.ptr = nil
	}
	return nil
}

// Raw exposes the underlying handle for mixing with direct cgo calls.
func (d *Dongle) Raw() unsafe.Pointer { return unsafe.Pointer(d.ptr) }

func (d *Dongle) check(rc C.int, op string) error { return d.ctx.check(rc, op) }

// Info reads the plaintext device info.
func (d *Dongle) Info() (Info, error) {
	var raw C.licd_info
	if err := d.check(C.licd_get_info(d.ptr, &raw), "licd_get_info"); err != nil {
		return Info{}, err
	}
	return Info{
		ProtocolMajor:  uint8(raw.proto_version_major),
		ProtocolMinor:  uint8(raw.proto_version_minor),
		FirmwareMajor:  uint8(raw.fw_version_major),
		FirmwareMinor:  uint8(raw.fw_version_minor),
		FirmwarePatch:  uint8(raw.fw_version_patch),
		SeReady:     raw.se_ready != 0,
		Provisioned:    raw.provisioned != 0,
		DataCapacity:   uint32(raw.data_capacity),
		DataFree:       uint32(raw.data_free),
		WatchdogReboot: raw.watchdog_reboot != 0,
		Isolated:       raw.isolated != 0,
	}, nil
}

// Serial reads the dongle serial as hex.
func (d *Dongle) Serial() (string, error) {
	buf := make([]C.char, serialBufferSize)
	rc := C.licd_get_serial(d.ptr, &buf[0], C.size_t(len(buf)))
	if err := d.check(rc, "licd_get_serial"); err != nil {
		return "", err
	}
	return C.GoString(&buf[0]), nil
}

// VerifyGenuine proves authenticity: the certificate chain to the trusted root
// plus a live ECDSA challenge-response. It returns an error unless the dongle is
// genuine.
func (d *Dongle) VerifyGenuine() (GenuineResult, error) {
	var raw C.licd_genuine_result
	if err := d.check(C.licd_verify_genuine(d.ptr, &raw), "licd_verify_genuine"); err != nil {
		return GenuineResult{}, err
	}
	return GenuineResult{
		Genuine:         raw.genuine != 0,
		Serial:          C.GoString(&raw.serial[0]),
		Batch:           C.GoString(&raw.batch[0]),
		ProvisionedDate: C.GoString(&raw.provisioned_date[0]),
	}, nil
}

// IsGenuine is the non-erroring form, for a licence gate. It fails closed: a
// missing dongle, an I/O error and an invalid certificate all report false.
func (d *Dongle) IsGenuine() bool {
	result, err := d.VerifyGenuine()
	return err == nil && result.Genuine
}

// OpenSession opens an encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM).
func (d *Dongle) OpenSession() (*Session, error) {
	if err := d.check(C.licd_session_open(d.ptr), "licd_session_open"); err != nil {
		return nil, err
	}
	return &Session{dongle: d}, nil
}

// Session is an open encrypted session: records, counters and app-crypto.
type Session struct {
	dongle *Dongle
	closed bool
}

// Close ends the session, zeroizing the session keys on the dongle. Safe to call
// more than once, and it never fails: teardown is local state.
func (s *Session) Close() error {
	if !s.closed {
		s.closed = true
		if s.dongle.ptr != nil {
			C.licd_session_close(s.dongle.ptr)
		}
	}
	return nil
}

func (s *Session) dev() (*C.licd_device, error) {
	if s.closed {
		return nil, newError(C.LICD_E_SESSION_EXPIRED, "session", "the session has been closed")
	}
	if s.dongle.ptr == nil {
		return nil, newError(C.LICD_E_INVALID_ARG, "session", "the dongle has been closed")
	}
	return s.dongle.ptr, nil
}

func (s *Session) check(rc C.int, op string) error { return s.dongle.check(rc, op) }

// AuthorizeWrite elevates to the write role with the developer master key (a DER
// EC private key). Vendor tooling only — never ship that key in an application.
func (s *Session) AuthorizeWrite(masterKeyDER []byte) error {
	dev, err := s.dev()
	if err != nil {
		return err
	}
	rc := C.licd_write_auth(dev, (*C.uint8_t)(bytePtr(masterKeyDER)), C.size_t(len(masterKeyDER)))
	return s.check(rc, "licd_write_auth")
}

// ListRecords lists the records stored on the dongle.
func (s *Session) ListRecords() ([]RecordInfo, error) {
	dev, err := s.dev()
	if err != nil {
		return nil, err
	}
	var names **C.char
	var sizes *C.uint32_t
	var count C.size_t
	rc := C.licd_record_list(dev, &names, &sizes, &count)
	if err := s.check(rc, "licd_record_list"); err != nil {
		return nil, err
	}
	if names == nil || count == 0 {
		return nil, nil
	}
	defer C.licd_free_record_list(names, sizes, count)

	out := make([]RecordInfo, 0, int(count))
	for i := 0; i < int(count); i++ {
		namePtr := *(**C.char)(unsafe.Pointer(uintptr(unsafe.Pointer(names)) +
			uintptr(i)*unsafe.Sizeof(*names)))
		size := *(*C.uint32_t)(unsafe.Pointer(uintptr(unsafe.Pointer(sizes)) +
			uintptr(i)*unsafe.Sizeof(*sizes)))
		out = append(out, RecordInfo{Name: C.GoString(namePtr), Size: uint32(size)})
	}
	return out, nil
}

// ReadRecord reads a record in full.
func (s *Session) ReadRecord(name string) ([]byte, error) {
	return s.ReadRecordProgress(name, nil)
}

// ReadRecordProgress reads a record, reporting progress. Returning false from
// progress cancels the transfer, which surfaces as StatusCancelled.
func (s *Session) ReadRecordProgress(name string, progress ProgressFunc) ([]byte, error) {
	dev, err := s.dev()
	if err != nil {
		return nil, err
	}
	if name == "" {
		return nil, newError(C.LICD_E_INVALID_ARG, "licd_record_read",
			"the record name must not be empty")
	}
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))

	// Probe for the size first, so progress runs monotonically from 0 to total.
	var probe [1]byte
	var got, total C.uint32_t
	rc := C.keynub_record_read(dev, cname, unsafe.Pointer(&probe[0]), 1, &got, &total, 0, 0)
	if err := s.check(rc, "licd_record_read"); err != nil {
		return nil, err
	}
	if total == 0 {
		return nil, nil
	}

	buf := make([]byte, int(total))
	state, handle, withProgress := newProgressState(progress)
	if withProgress != 0 {
		defer handle.Delete()
	}
	rc = C.keynub_record_read(dev, cname, unsafe.Pointer(&buf[0]), total, &got, &total,
		C.uintptr_t(handle), withProgress)
	if err := state.panicIfAny(); err != nil {
		panic(err)
	}
	if err := s.check(rc, "licd_record_read"); err != nil {
		return nil, err
	}
	return buf[:int(got)], nil
}

// WriteRecord atomically replaces a record. Requires the write role.
func (s *Session) WriteRecord(name string, data []byte) error {
	return s.WriteRecordProgress(name, data, nil)
}

// WriteRecordProgress writes a record, reporting progress. Requires the write role.
func (s *Session) WriteRecordProgress(name string, data []byte, progress ProgressFunc) error {
	dev, err := s.dev()
	if err != nil {
		return err
	}
	if name == "" {
		return newError(C.LICD_E_INVALID_ARG, "licd_record_write",
			"the record name must not be empty")
	}
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))

	state, handle, withProgress := newProgressState(progress)
	if withProgress != 0 {
		defer handle.Delete()
	}
	rc := C.keynub_record_write(dev, cname, bytePtr(data), C.uint32_t(len(data)),
		C.uintptr_t(handle), withProgress)
	if err := state.panicIfAny(); err != nil {
		panic(err)
	}
	return s.check(rc, "licd_record_write")
}

// EraseRecord erases one record. Requires the write role.
func (s *Session) EraseRecord(name string) error {
	dev, err := s.dev()
	if err != nil {
		return err
	}
	if name == "" {
		// A nil name means "erase everything" to the C API; that is
		// EraseAllRecords here, so an empty variable cannot wipe the dongle.
		return newError(C.LICD_E_INVALID_ARG, "licd_record_erase",
			"the record name must not be empty; use EraseAllRecords")
	}
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	return s.check(C.licd_record_erase(dev, cname), "licd_record_erase")
}

// EraseAllRecords erases every record. Requires the write role.
func (s *Session) EraseAllRecords() error {
	dev, err := s.dev()
	if err != nil {
		return err
	}
	return s.check(C.licd_record_erase(dev, nil), "licd_record_erase")
}

// ReadCounter reads a hardware monotonic counter.
func (s *Session) ReadCounter(counterID uint8) (uint32, error) {
	dev, err := s.dev()
	if err != nil {
		return 0, err
	}
	var value C.uint32_t
	rc := C.licd_counter_read(dev, C.uint8_t(counterID), &value)
	if err := s.check(rc, "licd_counter_read"); err != nil {
		return 0, err
	}
	return uint32(value), nil
}

// IncrementCounter increments a counter and returns the new value. Irreversible:
// the counter is monotonic in hardware. Requires the write role.
func (s *Session) IncrementCounter(counterID uint8) (uint32, error) {
	dev, err := s.dev()
	if err != nil {
		return 0, err
	}
	var value C.uint32_t
	rc := C.licd_counter_increment(dev, C.uint8_t(counterID), &value)
	if err := s.check(rc, "licd_counter_increment"); err != nil {
		return 0, err
	}
	return uint32(value), nil
}

// AppEncrypt encrypts so that only a dongle of scope can decrypt.
//
// This is the pair to build a licence check on: put something the program
// genuinely needs through it, so removing the check removes the data.
func (s *Session) AppEncrypt(scope Scope, plaintext []byte) ([]byte, error) {
	dev, err := s.dev()
	if err != nil {
		return nil, err
	}
	if scope != ScopeDevice && scope != ScopeDeveloper {
		return nil, newError(C.LICD_E_INVALID_ARG, "licd_app_encrypt",
			fmt.Sprintf("unknown scope %d", int(scope)))
	}
	var out *C.uint8_t
	var outLen C.uint32_t
	rc := C.licd_app_encrypt(dev, C.licd_scope(scope), bytePtr(plaintext),
		C.uint32_t(len(plaintext)), &out, &outLen)
	if err := s.check(rc, "licd_app_encrypt"); err != nil {
		return nil, err
	}
	return takeBuffer(out, outLen), nil
}

// AppDecrypt decrypts a blob produced by AppEncrypt, using the dongle.
func (s *Session) AppDecrypt(packed []byte) ([]byte, error) {
	dev, err := s.dev()
	if err != nil {
		return nil, err
	}
	var out *C.uint8_t
	var outLen C.uint32_t
	rc := C.licd_app_decrypt(dev, bytePtr(packed), C.uint32_t(len(packed)), &out, &outLen)
	if err := s.check(rc, "licd_app_decrypt"); err != nil {
		return nil, err
	}
	return takeBuffer(out, outLen), nil
}

// bytePtr is the address of the first byte, or nil for an empty slice. Indexing
// element 0 of an empty slice would panic, and the C side treats a zero length as
// "no data" regardless of the pointer.
func bytePtr(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return nil
	}
	return unsafe.Pointer(&b[0])
}

// takeBuffer copies a library-allocated buffer into Go memory and frees it.
func takeBuffer(ptr *C.uint8_t, length C.uint32_t) []byte {
	if ptr == nil {
		return nil
	}
	defer C.licd_free_buffer(ptr)
	if length == 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(ptr), C.int(length))
}

// newProgressState prepares the cgo.Handle carrying a progress callback into C.
// Returns a zero handle and 0 when there is no callback, so the C side is passed
// a null function pointer rather than a trampoline that does nothing.
func newProgressState(progress ProgressFunc) (*progressState, cgo.Handle, C.int) {
	if progress == nil {
		return &progressState{}, 0, 0
	}
	state := &progressState{callback: progress}
	return state, cgo.NewHandle(state), 1
}
