//go:build keynub_standin

// Every call of the binding against the C ABI stand-in:
// bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory,
// compiled into keynub_licdongle_standin with an import library (Windows) or a
// link name (elsewhere) of keynub_licdongle, so the package links it in place
// of the shipping library. From this directory, on Windows (PowerShell, with
// MinGW-w64 gcc on the path):
//
//	mkdir -Force $env:TEMP\kn-go > $null
//	gcc -shared -O1 -DLICD_BUILD_SHARED -I../../include ../julia/test/stub/licd_stub.c -o $env:TEMP\kn-go\keynub_licdongle_standin.dll "-Wl,--out-implib,$env:TEMP\kn-go\libkeynub_licdongle.dll.a"
//	$env:CGO_LDFLAGS = "-L$env:TEMP\kn-go"; $env:PATH = "$env:TEMP\kn-go;$env:PATH"
//	go test -tags keynub_standin
//
// On Linux:
//
//	mkdir -p /tmp/kn-go
//	cc -shared -fPIC -O1 -DLICD_BUILD_SHARED -I../../include -Wl,-soname,libkeynub_licdongle_standin.so ../julia/test/stub/licd_stub.c -o /tmp/kn-go/libkeynub_licdongle_standin.so
//	ln -sf libkeynub_licdongle_standin.so /tmp/kn-go/libkeynub_licdongle.so
//	CGO_LDFLAGS=-L/tmp/kn-go LD_LIBRARY_PATH=/tmp/kn-go go test -tags keynub_standin
//
// The stand-in keeps records, counters and the write key per opened device, so
// each test starts from a fresh dongle.

package keynub

import (
	"bytes"
	"errors"
	"sort"
	"strings"
	"testing"
)

const standInSerial = "04A1B2C3D4E5F6"

var (
	standInFactoryKey     = []byte{0x30, 0x10, 0x01, 0x02, 0x03}
	standInReplacementKey = []byte{0x30, 0x11, 0x09, 0x08, 0x07, 0x06}
)

// openStandIn opens the stand-in's dongle and closes it and its context at the
// end of the test.
func openStandIn(t *testing.T) (*Context, *Dongle) {
	t.Helper()
	ctx, err := NewContext()
	if err != nil {
		t.Fatalf("NewContext: %v", err)
	}
	d, err := ctx.Open("")
	if err != nil {
		ctx.Close()
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() {
		d.Close()
		ctx.Close()
	})
	return ctx, d
}

func openSession(t *testing.T, d *Dongle) *Session {
	t.Helper()
	s, err := d.OpenSession()
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

// wantStatus fails the test unless err is a *Error with this status.
func wantStatus(t *testing.T, err error, status Status, what string) {
	t.Helper()
	var e *Error
	if !errors.As(err, &e) {
		t.Errorf("%s: want %v, got %v", what, status, err)
		return
	}
	if e.Status != status {
		t.Errorf("%s: want %v, got %v", what, status, e.Status)
	}
}

func must(t *testing.T, err error, what string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
}

func TestStandInVersionDevicesAndOpen(t *testing.T) {
	if major, minor, patch := LibraryVersion(); major != 9 || minor != 8 || patch != 7 {
		t.Fatalf("library version %d.%d.%d: not the stand-in", major, minor, patch)
	}
	if got := StatusNoDevice.String(); got != "no device" {
		t.Errorf("status text: %q", got)
	}

	ctx, err := NewContext()
	must(t, err, "NewContext")
	defer ctx.Close()
	if ctx.Raw() == nil {
		t.Error("Raw")
	}

	devices, err := ctx.Enumerate()
	must(t, err, "Enumerate")
	want := []DeviceInfo{{Serial: standInSerial, Path: "stub:0", VendorID: 0x1234, ProductID: 0xABCD}}
	if len(devices) != 1 || devices[0] != want[0] {
		t.Errorf("devices: %+v", devices)
	}

	_, err = ctx.Open("nope")
	wantStatus(t, err, StatusNoDevice, "open by unknown serial")
	if !errors.Is(err, ErrNoDevice) {
		t.Error("errors.Is(err, ErrNoDevice)")
	}
	var e *Error
	if errors.As(err, &e) && (e.Op != "licd_open" || e.Detail != "no dongle with that serial") {
		t.Errorf("error fields: %+v", e)
	}
	if !strings.Contains(err.Error(), "no device") {
		t.Errorf("error text: %q", err.Error())
	}
	if got := ctx.LastErrorDetail(); got != "no dongle with that serial" {
		t.Errorf("LastErrorDetail: %q", got)
	}
	_, err = ctx.OpenPath("stub:9")
	wantStatus(t, err, StatusNoDevice, "open by unknown path")

	for _, open := range []func() (*Dongle, error){
		func() (*Dongle, error) { return ctx.Open("") },
		func() (*Dongle, error) { return ctx.Open(standInSerial) },
		func() (*Dongle, error) { return ctx.OpenPath("stub:0") },
	} {
		d, err := open()
		must(t, err, "open")
		if serial, err := d.Serial(); err != nil || serial != standInSerial {
			t.Errorf("serial: %q, %v", serial, err)
		}
		d.Close()
	}
}

func TestStandInInfoAndGenuine(t *testing.T) {
	_, d := openStandIn(t)
	info, err := d.Info()
	must(t, err, "Info")
	want := Info{
		ProtocolMajor: 1, ProtocolMinor: 0,
		FirmwareMajor: 2, FirmwareMinor: 3, FirmwarePatch: 4,
		SeReady: true, Provisioned: true,
		DataCapacity: 1024 * 1024, DataFree: 1000000,
		WatchdogReboot: false, Isolated: true, WriteAuthRotated: false,
	}
	if info != want {
		t.Errorf("info: %+v", info)
	}
	g, err := d.VerifyGenuine()
	must(t, err, "VerifyGenuine")
	if g != (GenuineResult{Genuine: true, Serial: standInSerial, ProvisionedDate: "2026-08-15"}) {
		t.Errorf("genuine: %+v", g)
	}
	if !d.IsGenuine() {
		t.Error("IsGenuine")
	}
}

func TestStandInTrustRoot(t *testing.T) {
	ctx, d := openStandIn(t)
	wantStatus(t, ctx.SetTrustRoot([]byte{0x02, 0x01, 0x00}), StatusCertificateInvalid, "malformed trust root")
	wantStatus(t, ctx.SetTrustRoot(nil), StatusInvalidArgument, "empty trust root")

	root := append([]byte{0x30, 0x82, 0x01, 0x00}, bytes.Repeat([]byte{0xAB}, 128)...)
	must(t, ctx.SetTrustRoot(root), "SetTrustRoot")
	_, err := d.VerifyGenuine()
	wantStatus(t, err, StatusCertificateInvalid, "verify against a foreign root")
	if !errors.Is(err, ErrCertificateInvalid) {
		t.Error("errors.Is(err, ErrCertificateInvalid)")
	}
	if d.IsGenuine() {
		t.Error("IsGenuine fails closed")
	}

	root = append([]byte{0x30, 0x82, 0x01, 0x00}, bytes.Repeat([]byte{0x01}, 128)...)
	must(t, ctx.SetTrustRoot(root), "SetTrustRoot")
	if !d.IsGenuine() {
		t.Error("IsGenuine after the right root")
	}
}

func TestStandInRecordsAndWriteRole(t *testing.T) {
	_, d := openStandIn(t)
	s := openSession(t, d)

	payload := []byte("license-blob-0123456789")
	err := s.WriteRecord("lic", payload)
	wantStatus(t, err, StatusAuthRequired, "write before the write role")
	if !errors.Is(err, ErrAuthRequired) {
		t.Error("errors.Is(err, ErrAuthRequired)")
	}
	wantStatus(t, s.EraseRecord("lic"), StatusAuthRequired, "erase before the write role")
	wantStatus(t, s.EraseAllRecords(), StatusAuthRequired, "erase all before the write role")
	_, err = s.IncrementCounter(0)
	wantStatus(t, err, StatusAuthRequired, "increment before the write role")
	err = s.AuthorizeWrite([]byte{0x30, 0x00})
	wantStatus(t, err, StatusNotGenuine, "write role with a bad key")
	if !errors.Is(err, ErrNotGenuine) {
		t.Error("errors.Is(err, ErrNotGenuine)")
	}

	must(t, s.AuthorizeWrite(standInFactoryKey), "AuthorizeWrite")
	must(t, s.WriteRecord("lic", payload), "WriteRecord")
	if got, err := s.ReadRecord("lic"); err != nil || !bytes.Equal(got, payload) {
		t.Errorf("read back: %q, %v", got, err)
	}
	must(t, s.WriteRecord("cfg", []byte("cfgdata")), "WriteRecord cfg")
	records, err := s.ListRecords()
	must(t, err, "ListRecords")
	names := []string{}
	for _, r := range records {
		names = append(names, r.Name)
		if r.Name == "lic" && r.Size != uint32(len(payload)) {
			t.Errorf("record size: %d", r.Size)
		}
	}
	sort.Strings(names)
	if strings.Join(names, ",") != "cfg,lic" {
		t.Errorf("record names: %v", names)
	}
	if got, err := s.ReadRecord("cfg"); err != nil || string(got) != "cfgdata" {
		t.Errorf("second record: %q, %v", got, err)
	}
	_, err = s.ReadRecord("nope")
	wantStatus(t, err, StatusNotFound, "read a missing record")
	if !errors.Is(err, ErrNotFound) {
		t.Error("errors.Is(err, ErrNotFound)")
	}
	wantStatus(t, s.EraseRecord("nope"), StatusNotFound, "erase a missing record")

	// An empty name is refused by the binding, never passed on as "erase everything".
	wantStatus(t, s.EraseRecord(""), StatusInvalidArgument, "erase with an empty name")
	_, err = s.ReadRecord("")
	wantStatus(t, err, StatusInvalidArgument, "read with an empty name")
	wantStatus(t, s.WriteRecord("", payload), StatusInvalidArgument, "write with an empty name")
	if records, _ := s.ListRecords(); len(records) != 2 {
		t.Errorf("two records: %v", records)
	}
	must(t, s.EraseRecord("cfg"), "EraseRecord")
	if records, _ := s.ListRecords(); len(records) != 1 || records[0].Name != "lic" {
		t.Errorf("one record left: %v", records)
	}

	must(t, s.WriteRecord("empty", nil), "write an empty record")
	if got, err := s.ReadRecord("empty"); err != nil || len(got) != 0 {
		t.Errorf("empty record: %q, %v", got, err)
	}

	// Bigger than one transfer chunk, with progress, cancellation and a panicking callback.
	big := make([]byte, 3000)
	for k := range big {
		big[k] = byte(k*31 + 5)
	}
	var last uint32
	must(t, s.WriteRecordProgress("big", big, func(done, total uint32) bool {
		last = done
		return true
	}), "WriteRecordProgress")
	if last != uint32(len(big)) {
		t.Errorf("write progress: %d", last)
	}
	last = 0
	got, err := s.ReadRecordProgress("big", func(done, total uint32) bool {
		last = done
		return true
	})
	if err != nil || !bytes.Equal(got, big) || last != uint32(len(big)) {
		t.Errorf("multi-chunk read: %d bytes, progress %d, %v", len(got), last, err)
	}
	_, err = s.ReadRecordProgress("big", func(done, total uint32) bool { return false })
	wantStatus(t, err, StatusCancelled, "cancelled transfer")
	if !errors.Is(err, ErrCancelled) {
		t.Error("errors.Is(err, ErrCancelled)")
	}
	func() {
		defer func() {
			if r := recover(); r != "from the callback" {
				t.Errorf("panic re-raised: %v", r)
			}
		}()
		_, _ = s.ReadRecordProgress("big", func(done, total uint32) bool { panic("from the callback") })
	}()
	if got, err := s.ReadRecord("big"); err != nil || !bytes.Equal(got, big) {
		t.Errorf("read after a panic: %d bytes, %v", len(got), err)
	}

	must(t, s.EraseAllRecords(), "EraseAllRecords")
	if records, _ := s.ListRecords(); len(records) != 0 {
		t.Errorf("erase all: %v", records)
	}
}

func TestStandInCounters(t *testing.T) {
	_, d := openStandIn(t)
	s := openSession(t, d)
	must(t, s.AuthorizeWrite(standInFactoryKey), "AuthorizeWrite")

	before, err := s.ReadCounter(0)
	must(t, err, "ReadCounter")
	if after, err := s.IncrementCounter(0); err != nil || after != before+1 {
		t.Errorf("increment: %d, %v", after, err)
	}
	if v, _ := s.ReadCounter(0); v != before+1 {
		t.Errorf("counter 0: %d", v)
	}
	if v, _ := s.ReadCounter(1); v != 0 {
		t.Errorf("counter 1: %d", v)
	}
	_, err = s.ReadCounter(7)
	wantStatus(t, err, StatusRange, "read a counter out of range")
	_, err = s.IncrementCounter(7)
	wantStatus(t, err, StatusRange, "increment a counter out of range")
}

func TestStandInAppEncryptAndDecrypt(t *testing.T) {
	_, d := openStandIn(t)
	s := openSession(t, d)

	secret := make([]byte, 100)
	for k := range secret {
		secret[k] = byte((3*k + 7) % 256)
	}
	for _, scope := range []Scope{ScopeDevice, ScopeDeveloper} {
		blob, err := s.AppEncrypt(scope, secret)
		must(t, err, "AppEncrypt")
		if len(blob) <= len(secret) || blob[0] != byte(scope) {
			t.Errorf("sealed data, scope %d: %d bytes, scope byte %d", scope, len(blob), blob[0])
		}
		if plain, err := s.AppDecrypt(blob); err != nil || !bytes.Equal(plain, secret) {
			t.Errorf("round trip, scope %d: %v", scope, err)
		}
		tampered := append([]byte(nil), blob...)
		tampered[len(tampered)-1] ^= 1
		_, err = s.AppDecrypt(tampered)
		wantStatus(t, err, StatusTagMismatch, "tampered blob")
		if !errors.Is(err, ErrTagMismatch) {
			t.Error("errors.Is(err, ErrTagMismatch)")
		}
	}
	_, err := s.AppEncrypt(Scope(7), secret)
	wantStatus(t, err, StatusInvalidArgument, "unknown scope")
	blob, err := s.AppEncrypt(ScopeDevice, nil)
	must(t, err, "AppEncrypt, empty")
	if plain, err := s.AppDecrypt(blob); err != nil || len(plain) != 0 {
		t.Errorf("empty round trip: %q, %v", plain, err)
	}
}

func TestStandInWriteKeyRotation(t *testing.T) {
	_, d := openStandIn(t)

	s, err := d.OpenSession()
	must(t, err, "OpenSession")
	wantStatus(t, s.RotateWriteKey(standInReplacementKey), StatusAuthRequired, "rotate before the write role")
	must(t, s.AuthorizeWrite(standInFactoryKey), "AuthorizeWrite")
	must(t, s.RotateWriteKey(standInReplacementKey), "RotateWriteKey")
	must(t, s.WriteRecord("lic", []byte("still-writable")), "the session keeps its role")
	s.Close()

	if info, err := d.Info(); err != nil || !info.WriteAuthRotated {
		t.Errorf("rotated flag: %+v, %v", info, err)
	}

	s = openSession(t, d)
	wantStatus(t, s.AuthorizeWrite(standInFactoryKey), StatusNotGenuine, "factory key after rotation")
	must(t, s.AuthorizeWrite(standInReplacementKey), "AuthorizeWrite, new key")
	must(t, s.WriteRecord("lic", []byte("new-key-writes")), "WriteRecord")
	if got, err := s.ReadRecord("lic"); err != nil || string(got) != "new-key-writes" {
		t.Errorf("write with the new key: %q, %v", got, err)
	}
}

func TestStandInSessionAndCloseSemantics(t *testing.T) {
	ctx, err := NewContext()
	must(t, err, "NewContext")
	d, err := ctx.Open("")
	must(t, err, "Open")

	// Closing one session ends the device's session, so the other one is refused by the device.
	stale, err := d.OpenSession()
	must(t, err, "OpenSession")
	s, err := d.OpenSession()
	must(t, err, "OpenSession")
	must(t, s.Close(), "Close")
	_, err = stale.ListRecords()
	wantStatus(t, err, StatusSessionExpired, "records without a session")
	if !errors.Is(err, ErrSessionExpired) {
		t.Error("errors.Is(err, ErrSessionExpired)")
	}
	stale.Close()
	must(t, s.Close(), "Close again")
	_, err = s.ReadCounter(0)
	wantStatus(t, err, StatusSessionExpired, "a closed session")

	// Adopt takes over a device handle; the adopting Dongle now owns and closes it.
	adopted := ctx.Adopt(d.Raw())
	if serial, err := adopted.Serial(); err != nil || serial != standInSerial {
		t.Errorf("adopted: %q, %v", serial, err)
	}
	orphan, err := adopted.OpenSession()
	must(t, err, "OpenSession")
	must(t, adopted.Close(), "Close")
	must(t, adopted.Close(), "Close again")
	if adopted.Raw() != nil {
		t.Error("Raw after close")
	}
	_, err = adopted.Serial()
	wantStatus(t, err, StatusInvalidArgument, "serial after close")
	_, err = orphan.ListRecords()
	wantStatus(t, err, StatusInvalidArgument, "a session whose dongle closed")
	must(t, orphan.Close(), "Close an orphaned session")

	must(t, ctx.Close(), "Close context")
	must(t, ctx.Close(), "Close context again")
	if ctx.LastErrorDetail() != "" {
		t.Error("LastErrorDetail after close")
	}
}
