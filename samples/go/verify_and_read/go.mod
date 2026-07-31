module keynub.example/verify_and_read

// 1.17 matches the binding: runtime/cgo.Handle is how a Go progress callback
// crosses the C boundary without handing C a Go pointer.
go 1.17

require github.com/AB-KeyNub/KeyNub-SDK/bindings/go v0.0.0

// Path replacement so the sample builds straight from a checkout. A real consumer
// would `go get` the published module instead.
replace github.com/AB-KeyNub/KeyNub-SDK/bindings/go => ../../../bindings/go
