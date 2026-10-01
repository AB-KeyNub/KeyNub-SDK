#lang scribble/manual
@(require (for-label racket/base
                     racket/contract/base
                     keynub/licdongle))

@title{KeyNub License Dongle}
@author{KeyNub}

@defmodule[keynub/licdongle]

Verify that a KeyNub License Dongle is genuine, read and write the license
records it holds, use its hardware counters and seal data so that only a dongle
can open it.

@racketblock[
(require keynub/licdongle)

(define secret
  (with-dongle (d)                (code:comment "first dongle, or (d #:serial \"...\")")
    (dongle-verify-genuine d)     (code:comment "raises unless genuine")
    (with-session d               (code:comment "closed on every exit path")
      (app-decrypt d sealed))))   (code:comment "build the licence check on this")
]

The package calls the SDK's flat C API from the native library
@tt{keynub_licdongle_flat} through @racketmodname[ffi/unsafe]. The library is
loaded on the first call that needs it, so requiring the module and building
this documentation work without it. Every function checks its arguments with a
contract before it calls the library.

Read the SDK's
@hyperlink["https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md"]{integration
security notes} before writing the check. @racket[(unless (dongle-genuine? d) (exit 1))]
is one conditional branch, and patching one of those in a release binary is a
beginner exercise. Route something the program needs through
@racket[app-encrypt] and @racket[app-decrypt], so removing the check removes
the data.

@table-of-contents[]

@section{Installation and the Native Library}

@commandline{raco pkg install keynub-licdongle}

The package does not contain the native library. Take the file for your
platform from the SDK's
@hyperlink["https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md"]{natives
folder}. The package looks for it in this order:

@itemlist[#:style 'ordered
 @item{the path given to @racket[set-library-path!];}
 @item{the path in the environment variable @tt{KEYNUB_LICDONGLE_FLAT_LIBRARY};}
 @item{@tt{natives/<platform>/<file name>} in the folder of the running
       program, the current directory and the package's own folder, and in each
       of their parent folders, where @tt{<platform>} is one of @tt{win-x64},
       @tt{win-x86}, @tt{win-arm64}, @tt{linux-x64}, @tt{linux-arm64},
       @tt{osx-x64} and @tt{osx-arm64};}
 @item{the bare file name, for the system loader.}]

A process loads the library once. On Linux, install the udev rule described in
the natives folder's notes so the dongle is accessible without root.

@defthing[library-environment-variable string?]{
The name of the environment variable that names the library file:
@racket["KEYNUB_LICDONGLE_FLAT_LIBRARY"].}

@defproc[(library-basename) string?]{
The library's file name on this operating system:
@tt{keynub_licdongle_flat.dll}, @tt{libkeynub_licdongle_flat.so} or
@tt{libkeynub_licdongle_flat.dylib}.}

@defproc[(library-candidates) (listof string?)]{
The paths the package tries, in order. The last one is the bare file name,
unless a path was set with @racket[set-library-path!] or in the environment.}

@defproc[(set-library-path! [path path-string?]) void?]{
Names the library file to load. Call it before the first dongle call. Raises
@racket[exn:fail:keynub:library] when a different library is already loaded.}

@defproc[(library-path) string?]{
The path of the loaded library, or the first candidate when nothing is loaded
yet.}

@defproc[(loaded-library-path) (or/c string? #f)]{
The path of the loaded library; @racket[#f] before the first call.}

@defstruct*[lib-version ([major exact-integer?]
                         [minor exact-integer?]
                         [patch exact-integer?])
            #:transparent]{
A version of the native library.}

@defproc[(library-version) lib-version?]{
The native library's version.}

@section{Errors}

@defstruct*[(exn:fail:keynub exn:fail) ([status (or/c symbol? #f)]
                                        [code exact-integer?]
                                        [operation string?]
                                        [detail string?])]{
Raised by every failed dongle call. @racket[status] is the name of the SDK
status code, for example @racket['no-device], @racket['not-genuine] or
@racket['auth-required] (see @racket[status-symbol]), and @racket[#f] for a
code this package does not know. @racket[code] is the raw code,
@racket[operation] the flat API function that failed, and @racket[detail] the
library's diagnostic text, which may be empty. The message reads
@tt{operation: status (code)}, followed by @tt{: detail} when there is one.}

@defstruct*[(exn:fail:keynub:library exn:fail) ()]{
Raised when the native library cannot be loaded or does not export every
function of the flat API, and by @racket[set-library-path!] once a different
library is loaded. It is not an @racket[exn:fail:keynub].}

@defproc[(status-symbol [code exact-integer?]) (or/c symbol? #f)]{
The name of a status code; @racket[#f] for a code this package does not know.
The names and their codes:
@racket['ok] 0, @racket['invalid-arg] -1, @racket['no-device] -2,
@racket['access-denied] -3, @racket['io] -4, @racket['timeout] -5,
@racket['protocol] -6, @racket['not-genuine] -7, @racket['cert-invalid] -8,
@racket['session-expired] -9, @racket['tag-mismatch] -10, @racket['range] -11,
@racket['storage-full] -12, @racket['busy] -13, @racket['not-found] -14,
@racket['auth-required] -15, @racket['fw-incompatible] -16,
@racket['sdk-too-old] -17, @racket['cancelled] -18,
@racket['not-implemented] -19 and @racket['internal] -20.}

@defproc[(status-code [name symbol?]) (or/c exact-integer? #f)]{
The code of a status name; @racket[#f] for a name this package does not know.}

@defproc[(status-text [code (integer-in -2147483648 2147483647)]) string?]{
Human-readable text for a status code, from the library; needs no dongle.}

@section{Finding and Opening a Dongle}

@defstruct*[device ([serial string?] [path string?]) #:transparent]{
An attached dongle: its serial number and its device path.}

@defproc[(devices) (listof device?)]{
The attached dongles.}

@defproc[(dongle? [v any/c]) boolean?]{
Returns @racket[#t] if @racket[v] is a dongle opened by this package.}

@defproc[(dongle-open [serial (or/c string? #f) #f]) dongle?]{
Opens the dongle with this serial number, or the first one found when
@racket[serial] is @racket[#f] or empty. Close it with @racket[dongle-close];
a dongle that becomes unreachable is closed when it is collected.}

@defproc[(dongle-open-path [path string?]) dongle?]{
Opens the dongle at this device path (from @racket[devices]).}

@defproc[(dongle-close [d dongle?]) void?]{
Closes the dongle. Closing a closed dongle does nothing; every other call on it
raises @racket[exn:fail:keynub] with status @racket['invalid-arg].}

@defproc[(dongle-open? [d dongle?]) boolean?]{
Whether @racket[dongle-close] has not been called on @racket[d] yet.}

@defproc[(call-with-dongle [proc (-> dongle? any)]
                           [#:serial serial (or/c string? #f) #f]
                           [#:path path (or/c string? #f) #f])
         any]{
Opens the first dongle, the one with serial number @racket[serial] or the one
at device path @racket[path], calls @racket[proc] with it and closes it on
every exit path, exceptions included. Returns what @racket[proc] returns. Give
@racket[serial] or @racket[path], not both.}

@defform*[((with-dongle (id) body ...+)
           (with-dongle (id #:serial serial-expr) body ...+)
           (with-dongle (id #:path path-expr) body ...+))]{
Evaluates the @racket[body] forms with @racket[id] bound to an open dongle, as
@racket[call-with-dongle] does, and closes the dongle on every exit path.}

@section{Information and Authenticity}

@defproc[(dongle-serial [d dongle?]) string?]{
The dongle's serial number (14 hex digits).}

@defstruct*[device-info ([protocol-major exact-integer?]
                         [protocol-minor exact-integer?]
                         [firmware-major exact-integer?]
                         [firmware-minor exact-integer?]
                         [firmware-patch exact-integer?]
                         [secure-element-ready? boolean?]
                         [provisioned? boolean?]
                         [watchdog-reboot? boolean?]
                         [isolated? boolean?]
                         [write-auth-rotated? boolean?]
                         [data-capacity exact-integer?]
                         [data-free exact-integer?])
            #:transparent]{
Plaintext device information: the protocol and firmware versions, whether the
secure element is ready, whether the dongle is provisioned, whether its
previous boot ended in a watchdog reset, whether it is isolated, whether its
write-auth key has been rotated away from the factory one, and the size of its
data area and the part of it that is free, in bytes.}

@defproc[(dongle-info [d dongle?]) device-info?]{
Plaintext device information; needs no session.}

@defstruct*[verification ([serial string?] [provisioned-date string?]) #:transparent]{
The result of a successful @racket[dongle-verify-genuine]: the serial number
and the day the dongle was provisioned, as @tt{YYYY-MM-DD}, or @racket[""]
when it reports none. The date is informational; no licensing decision should
turn on it.}

@defproc[(dongle-verify-genuine [d dongle?]) verification?]{
Proves the dongle is genuine: certificate chain to the trusted root plus a live
challenge-response. Returns only when it is; raises @racket[exn:fail:keynub]
otherwise.}

@defproc[(dongle-genuine? [d dongle?]) boolean?]{
The boolean form for a gate: @racket[#t] only when
@racket[dongle-verify-genuine] succeeds. Fails closed: every failure gives
@racket[#f].}

@defproc[(set-dongle-trust-root! [d dongle?] [der bytes?]) void?]{
Overrides the CA root (DER) that @racket[dongle-verify-genuine] checks against.
Applications do not need this: the library embeds the KeyNub production root.}

@defproc[(dongle-last-error [d dongle?]) string?]{
Diagnostic detail for the most recent failure on this dongle; may be empty.}

@section{Sessions and the Write Role}

Records, counters and app-data encryption need an authenticated session.
Writing records, erasing them and incrementing counters also need the write
role.

@defproc[(session-open [d dongle?]) void?]{
Opens an authenticated session.}

@defproc[(session-close [d dongle?]) void?]{
Closes the session.}

@defproc[(call-with-session [d dongle?] [thunk (-> any)]) any]{
Opens a session, calls @racket[thunk] and closes the session on every exit
path, exceptions included. Returns what @racket[thunk] returns.}

@defform[(with-session dongle-expr body ...+)]{
Evaluates the @racket[body] forms inside a session on the dongle, as
@racket[call-with-session] does.}

@defproc[(authorize-write [d dongle?] [key bytes?]) void?]{
Elevates the session to the write role with a write-auth key (P-256 PKCS#8
DER). Belongs in licence-issuing tooling, not in the application your users
run.}

@defproc[(rotate-write-key [d dongle?] [key bytes?]) void?]{
Replaces the dongle's write-auth key with @racket[key] (P-256 PKCS#8 DER). Call
@racket[authorize-write] first. From the next session on, only the new key
elevates. A dongle ships holding the factory write-auth key, which is public;
rotate it before shipping a dongle on.}

@section{Records}

@defstruct*[record ([name string?] [size exact-integer?]) #:transparent]{
A record on the dongle: its name and its size in bytes.}

@defproc[(dongle-records [d dongle?]) (listof record?)]{
The records on the dongle.}

@defproc[(read-record [d dongle?] [name string?]) bytes?]{
The content of a record. Raises @racket[exn:fail:keynub] with status
@racket['not-found] when there is none of that name.}

@defproc[(write-record! [d dongle?] [name string?] [data bytes?]) void?]{
Writes a record, replacing one of the same name. Needs the write role.}

@defproc[(erase-record! [d dongle?] [name string?]) void?]{
Erases one record. Needs the write role.}

@defproc[(erase-all-records! [d dongle?]) void?]{
Erases every record. Needs the write role. This is the only call that erases
more than one record; @racket[erase-record!] erases the one record it names.}

@section{Counters}

@defproc[(read-counter [d dongle?] [counter-id (integer-in -2147483648 2147483647)])
         exact-integer?]{
The value of a hardware monotonic counter.}

@defproc[(increment-counter! [d dongle?] [counter-id (integer-in -2147483648 2147483647)])
         exact-integer?]{
Increments a counter and returns the new value. Needs the write role.}

@section{App-Data Encryption}

@defproc[(app-encrypt [d dongle?] [scope (or/c 'device 'developer)] [plaintext bytes?])
         bytes?]{
Seals data so that only a dongle can open it: this one (@racket['device]) or
any dongle issued by the same developer (@racket['developer]). Build the
licence check on this pair: put something the program needs through it, so
removing the check removes the data.}

@defproc[(app-decrypt [d dongle?] [packed bytes?]) bytes?]{
Opens data sealed with @racket[app-encrypt]. Raises @racket[exn:fail:keynub]
with status @racket['tag-mismatch] when the data was altered.}
