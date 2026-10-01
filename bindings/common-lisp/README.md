# KeyNub License Dongle — Common Lisp System

```lisp
(ql:quickload "keynub-licdongle")

(defvar *secret*
  (licdongle:with-dongle (d)                ; first dongle, or (d :serial "...")
    (licdongle:dongle-verify-genuine d)     ; signals unless genuine
    (licdongle:with-session (d)             ; closed on every exit path
      (licdongle:app-decrypt d *sealed*)))) ; <- build the licence check on this
```

**Nothing linked.** The system calls the SDK's flat companion API through
CFFI, from the native library loaded at run time on the first call; nothing is
compiled against it. Loading the system needs no library. Depends on `cffi`
only (with `babel` and `uiop`, which `cffi` brings along); SBCL 2.1.11 or
later, on Windows, Linux and macOS.

## Setup

From a clone of the [SDK repository](https://github.com/AB-KeyNub/KeyNub-SDK),
put `bindings/common-lisp/` where ASDF looks (a link in
`~/quicklisp/local-projects/`, or
`(push #p"/path/to/KeyNub-SDK/bindings/common-lisp/" asdf:*central-registry*)`)
and load it with `ql:quickload`, which also fetches `cffi`, or with
`asdf:load-system`.

The system does not contain the native library. Put the library for your
platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
next to your program, or name it before the first call:

```lisp
(licdongle:set-library-path "/opt/keynub/libkeynub_licdongle_flat.so")
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. The system
looks in `natives/<platform>/` from the program's folder, the current
directory and its own folder upwards (so a system loaded from an SDK clone
finds the clone's `natives/`), then asks the system loader. A process loads
the library once; `(licdongle:loaded-library-path)` tells which, and
`set-library-path` with a different file after that signals
`licdongle-library-error`. On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every failed call signals `licdongle-error`, with
  `licdongle-error-status` (`:no-device`, `:not-genuine`, `:auth-required`,
  ...), the raw `licdongle-error-code`, the `licdongle-error-operation` and
  the library's `licdongle-error-detail` text. Loading problems signal
  `licdongle-library-error`, a subtype whose status and code are `nil`.

  ```lisp
  (handler-case (licdongle:open-dongle)
    (licdongle:licdongle-error (e)
      (when (eq (licdongle:licdongle-error-status e) :no-device)
        (format t "no dongle~%"))))
  ```

- Results are structures (`device-info`, `verification`, `device`,
  `record`); `library-version` returns major, minor and patch as three
  values. Byte data is a vector of `(unsigned-byte 8)`, in and out. Arguments are checked with `check-type` before the library is touched.
  The system calls the SDK's flat API: integer handles and caller-provided
  buffers, no C structures and no hand-written layouts.
- `with-dongle` / `call-with-dongle` and `with-session` /
  `call-with-session` close the dongle and the session on every exit path,
  non-local exits included, and return what the body returns. A dongle opened
  with `open-dongle` is closed by `close-dongle`, and on SBCL also when it is
  collected.
- `dongle-genuine-p` is the boolean form for a gate and **fails closed**:
  every failure gives `nil`.
- `app-encrypt` takes the scope as `:device` (this dongle only) or
  `:developer` (any dongle issued by the same developer).
- `set-trust-root` overrides the CA root that `dongle-verify-genuine` checks
  against; applications do not need it.
- `erase-all-records` is the only call that erases more than one record;
  `erase-record` erases the one record it names.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `(unless (licdongle:dongle-genuine-p d) (uiop:quit 1))`
> is one conditional branch, and patching one of those in a saved image is no
> effort at all. Route something the program needs through `app-encrypt` and
> `app-decrypt`, so removing the check removes the data.

## Tests

`(asdf:test-system "keynub-licdongle")` runs the unit tests, which need
neither the library nor a dongle; from a shell,
`sbcl --non-interactive --load bindings/common-lisp/test/run-unit-tests.lisp`
does the same and sets the exit code.
`sbcl --non-interactive --load bindings/common-lisp/test/standin-test.lisp`
runs without a dongle: it compiles a stand-in for the flat C API
(`bindings/flat/licd_flat.c` over `bindings/julia/test/stub/licd_stub.c`) with
the C compiler on the path and exercises every call against it.
`KEYNUB_SDK_ROOT` names the SDK sources when the system is not inside a clone;
`KEYNUB_LICDONGLE_FLAT_LIBRARY` names a compiled stand-in instead. Both
commands expect ASDF to find `cffi`, as it does once Quicklisp is loaded. The
samples are under `samples/common-lisp`
(`sbcl --non-interactive --load samples/common-lisp/verify-and-read.lisp`).

## Links

- [KeyNub License Dongle for Common Lisp](https://www.keynub.com/developers/common-lisp/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
