//go:build keynub_sim

package keynub

// Test-only. Links keynub_licdongle_sim instead of the shipping library — the
// whole ABI plus licd_open_simulated — so the suite can drive the full protocol
// stack with no hardware:
//
//	CGO_LDFLAGS="-L../../build" go test -tags keynub_sim
//
// A build tag rather than a separate module, so the code under test is the code
// that ships: nothing here stubs any of it out. It lives in a normal source file
// rather than in the test, because cgo is not supported inside _test.go files.

/*
#cgo LDFLAGS: -lkeynub_licdongle_sim

#include <licdongle.h>

// Exported by keynub_licdongle_sim only; the shipping library has neither.
int licd_open_simulated(licd_ctx *ctx, licd_device **out_dev);
void licd_test_get_master_key_der(const uint8_t **out_der, uint32_t *out_len);
*/
import "C"

import "unsafe"

// OpenSimulated opens a dongle backed by the in-process software simulator,
// using the committed X.509 and key fixtures. Close it like any other dongle.
func (c *Context) OpenSimulated() (*Dongle, error) {
	var dev *C.licd_device
	rc := C.licd_open_simulated(c.ptr, &dev)
	if err := c.check(rc, "licd_open_simulated"); err != nil {
		return nil, err
	}
	return &Dongle{ptr: dev, ctx: c}, nil
}

// SimulatorMasterKeyDER is the fixture developer write-auth key, for driving
// AuthorizeWrite in tests. Static fixture data; never a real key.
func SimulatorMasterKeyDER() []byte {
	var der *C.uint8_t
	var length C.uint32_t
	C.licd_test_get_master_key_der(&der, &length)
	return C.GoBytes(unsafe.Pointer(der), C.int(length))
}
