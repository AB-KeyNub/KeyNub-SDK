# KeyNub License Dongle — SWI-Prolog Pack

```prolog
:- use_module(library(keynub_licdongle)).

secret(Sealed, Secret) :-
    with_dongle(D,                          % first dongle, or with_dongle([serial(S)], D, Goal)
        ( dongle_verify_genuine(D),         % throws unless genuine
          with_session(D,                   % closed on every exit path
              app_decrypt(D, Sealed, Secret))   % <- build the licence check on this
        )).
```

**Nothing linked.** The pack's foreign module (`c/keynub_licdongle4pl.c`)
loads the SDK's flat companion API from the native library at run time, on
the first call that needs it; it is not linked against the native library.
Loading `library(keynub_licdongle)` needs no native library. SWI-Prolog 8.4
or later, on Windows, Linux and macOS.

## Setup

```
swipl pack install keynub_licdongle
```

installs the pack from the [SWI-Prolog pack list](https://www.swi-prolog.org/pack/list?p=keynub_licdongle).
From a clone of the [SDK repository](https://github.com/AB-KeyNub/KeyNub-SDK)
instead, give the folder as a `file://` URL:

```
swipl pack install file:///home/me/KeyNub-SDK/bindings/prolog
swipl pack install file:///C:/src/KeyNub-SDK/bindings/prolog
```

The install builds the foreign module with CMake and a C compiler and runs
the unit tests. On Windows it needs `gcc` (MinGW-w64), `cmake` and `ninja` on
the PATH; on Linux and macOS `cmake` and the system C compiler.

The pack does not contain the native library. Put the library for your
platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
next to your program, or name it before the first call:

```prolog
?- set_library_path('/opt/keynub/libkeynub_licdongle_flat.so').
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. The pack
looks in `natives/<platform>/` from the program's folder, the working
directory and its own folder upwards, then asks the system loader. A process
loads the library once; `loaded_library_path/1` tells which. On Linux,
install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every failed call throws `error(keynub_error(Status, Code, Operation,
  Detail), _)`: `Status` is an atom (`no_device`, `not_genuine`,
  `auth_required`, ...; `unknown` for a code the pack does not know), `Code`
  the raw status code, `Operation` the flat API function and `Detail` the
  library's diagnostic text, which may be empty. `status_name/2` maps codes
  and atoms both ways. A library that cannot be loaded throws
  `error(keynub_library_error(Message), _)`. `print_message/2` prints both.
- Byte data (records, keys, sealed data) is a list of codes 0..255, as
  `read_file_to_codes/3` with `type(binary)` returns it; a string or atom
  whose characters are all below 256 is accepted as input. Text from the
  dongle (serials, device paths, record names) is a string.
- `dongle_info/2` returns a dict (`I.firmware_major`, `I.write_auth_rotated`,
  ...). `devices/1` returns `device(Serial, Path)` terms and
  `dongle_records/2` `record(Name, Size)` terms.
- `with_dongle/2,3` and `with_session/2` call their goal as `once/1` and
  close the dongle and the session on every exit path, exceptions included.
  A dongle opened with `dongle_open/1,2` is closed by `dongle_close/1`, or
  when it is garbage collected.
- `dongle_genuine/1` is the test for a gate and **fails closed**: every
  error makes it fail.
- `app_encrypt/4` takes the scope `device` (this dongle only) or `developer`
  (any dongle issued by the same developer).
- `erase_all_records/1` is the only call that erases more than one record;
  `erase_record/2` erases the one record it names.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `( dongle_genuine(D) -> true ; halt(1) )` is one
> conditional branch, and patching one of those in a release binary is a
> beginner exercise. Route something the program needs through
> `app_encrypt/4` and `app_decrypt/3`, so removing the check removes the data.

## Layout

`bindings/prolog` is the pack: `pack.pl`, the module
`prolog/keynub_licdongle.pl` (documented with PlDoc), the foreign module
`c/keynub_licdongle4pl.c` with its `CMakeLists.txt`, and the tests in
`test/`. The samples are under
[`samples/prolog`](https://github.com/AB-KeyNub/KeyNub-SDK/tree/master/samples/prolog)
(`swipl samples/prolog/verify_and_read.pl` once the pack is installed).

## Tests

`swipl pack install` runs the unit tests, which need neither the native
library nor a dongle. In a built tree:

```
swipl -p foreign=<folder of keynub_licdongle4pl> test/unit_test.pl
swipl -p foreign=<folder of keynub_licdongle4pl> test/standin_test.pl
```

The stand-in test runs without a dongle: it compiles a stand-in for the flat
C API (the SDK's `bindings/flat/licd_flat.c` over
`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK sources when
the pack is not inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a
compiled stand-in instead.

## Links

- [KeyNub License Dongle for SWI-Prolog](https://www.keynub.com/developers/prolog/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
