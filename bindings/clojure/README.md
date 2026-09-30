# KeyNub License Dongle — Clojure Library

```clojure
;; deps.edn: com.keynub/keynub-licdongle-clj {:mvn/version "1.1.1"}
;; Leiningen: [com.keynub/keynub-licdongle-clj "1.1.1"]
(require '[keynub.licdongle :as kn])

(kn/with-dongle [d]                      ; the first dongle, or (kn/with-dongle [d serial] ...)
  (kn/verify-genuine d)                  ; throws unless genuine
  (kn/with-session [s d]                 ; closed on every exit path
    (kn/app-decrypt s sealed)))          ; <- build the licence check on this
```

A Clojure library over the Java binding
[`com.keynub/keynub-licdongle`](https://central.sonatype.com/artifact/com.keynub/keynub-licdongle)
(JNA), which calls the native KeyNub library. Clojure 1.11 or later on Java 17
or later, on Windows, Linux and macOS, with no driver.

## Setup

The library, like the Java binding, carries no native library. In a clone of
the SDK repository it finds `keynub_licdongle` for your platform in
`natives/<platform>/` on its own, from the working directory upwards, so the
samples run with nothing set. Elsewhere, take the library from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where JNA finds libraries (`jna.library.path`, `PATH`,
`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) or name it before the first call:

```clojure
(kn/set-library-path! "/opt/keynub/libkeynub_licdongle.so")
```

`KEYNUB_LICDONGLE_LIBRARY` in the environment, or the Java binding's system
property `keynub.licdongle.library`, does the same. A process loads the library
once; `(kn/library-path)` tells which. On Linux, install the udev rule
described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Dongles and sessions are the Java binding's `Dongle` and `Session` objects;
  `with-dongle` and `with-session` close them on every exit path, errors
  included, and return the value of their body. A dongle has one session at a
  time: opening another ends the one before it.
- Results are maps and vectors (`devices`, `info`, `verify-genuine`,
  `records`); record data, keys and sealed data are byte arrays. The functions
  that take data also take a string, used as its UTF-8 bytes.
- Every failure the native library reports is thrown as an `ex-info` whose
  data has `:keynub.licdongle/status` (`:no-device`, `:not-genuine`,
  `:not-found`, `:auth-required`, ...), `:keynub.licdongle/code` and
  `:keynub.licdongle/detail`, with the Java exception as its cause:
  `(case (::kn/status (ex-data e)) :no-device ...)`.
- `genuine?` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- Writing, erasing and incrementing need the write role:
  `(kn/authorize-write! s key-bytes)` with the dongle's write key, a P-256
  private key in PKCS#8 DER. That belongs in your licence-issuing tooling,
  never in what your users run. A new dongle accepts the public factory key
  until `rotate-write-key!` replaces it with yours; do that once per dongle,
  when it arrives.
- `erase-all-records!` is separate from `erase-record!`: an accidentally empty
  name never wipes the dongle.
- `read-record` and `write-record!` take an optional `(fn [done total] ...)`
  that cancels the transfer by returning `false`.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `(when-not (kn/genuine? d) (System/exit 1))` is one
> form, and deleting it from a program is no effort at all. Route something the
> program needs through `app-encrypt` and `app-decrypt`, so removing the check
> removes the data.

## Tests

`mvn test` in `bindings/clojure` (or `clojure -M:test`) runs without a dongle:
it compiles a stand-in for the C ABI (`bindings/julia/test/stub/licd_stub.c`)
with the C compiler on the path (cc, gcc, clang, `zig cc` or cl) and runs every
function against it; `-Dclojure.version=...` tests another Clojure.
`KEYNUB_SDK_ROOT` names the SDK sources when the project is not inside a clone;
`KEYNUB_LICDONGLE_LIBRARY` names a compiled stand-in instead. The samples are
under `samples/clojure`.

## Links

- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
- [KeyNub License Dongle for Clojure](https://www.keynub.com/developers/clojure/): the product, and how to
  order one
