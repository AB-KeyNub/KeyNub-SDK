//go:build !keynub_sim

package keynub

// Links the shipping library. Its directory is not knowable at compile time, so
// the caller supplies it:
//
//	CGO_LDFLAGS="-L/path/to/native/" go build
//
// The library must also be findable at run time (PATH on Windows, rpath or
// LD_LIBRARY_PATH elsewhere) — the same as for any shared library.

/*
#cgo LDFLAGS: -lkeynub_licdongle
*/
import "C"
