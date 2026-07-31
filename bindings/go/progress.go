package keynub

/*
// Declarations only. A file containing //export may not define anything in its
// preamble, or the definition is emitted twice and the link fails.
#include <stdint.h>
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

// progressState carries a Go callback across the C boundary and holds any panic
// it raises until the SDK has unwound its own transfer.
type progressState struct {
	callback ProgressFunc
	panicked interface{}
}

// panicIfAny returns a panic value captured inside the callback, so the caller
// can re-raise it once C is no longer on the stack. Panicking through a cgo frame
// is undefined behaviour, which is why it is deferred rather than propagated.
func (p *progressState) panicIfAny() interface{} {
	if p == nil {
		return nil
	}
	value := p.panicked
	p.panicked = nil
	return value
}

//export keynubProgressBridge
func keynubProgressBridge(done, total C.uint32_t, user unsafe.Pointer) C.int {
	handle := cgo.Handle(uintptr(user))
	state, ok := handle.Value().(*progressState)
	if !ok || state.callback == nil {
		return 1 // no callback: never cancel
	}
	if state.panicked != nil {
		return 0 // already failed; keep cancelling
	}

	keepGoing := func() (result C.int) {
		defer func() {
			if r := recover(); r != nil {
				state.panicked = r
				result = 0
			}
		}()
		if state.callback(uint32(done), uint32(total)) {
			return 1
		}
		return 0
	}()
	return keepGoing
}
