# KeyNub License Dongle — Wolfram Language paclet

```wolfram
Needs["KeyNub`KeyNubLicDongle`"]

h = LicDongleOpen[];                        (* first dongle, or LicDongleOpen[serial] *)
LicDongleVerifyGenuine[h];                  (* a Failure unless genuine *)
LicDongleSessionOpen[h];
data = LicDongleAppDecrypt[h, sealed];      (* <- build the licence check on this *)
LicDongleSessionClose[h];
LicDongleClose[h];
```

**Pure Wolfram Language.** The paclet calls the SDK's flat companion API
through `ForeignFunctionLoad`, which the language has had since version 13.1,
so there is no LibraryLink shim to compile and nothing in the path of the check
that a customer could substitute. Mathematica, Wolfram Engine and
`wolframscript` alike, on Windows, Linux and macOS.

## It uses the flat API, not the core ABI

Like the Perl binding, this one calls
[`keynub_licdongle_flat`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/bindings/flat/README.md):
integer handles, caller-provided buffers and strings, no C structures. A
foreign function interface describes structures by hand-written layouts, and a
wrong offset there reads a neighbouring field, a plausible wrong value rather
than a crash. The flat API has no structures, so the problem does not arise.
What it costs is progress reporting: the flat API has no callbacks, and records
are read in one call.

## Setup

From the Wolfram Paclet Repository:

```wolfram
PacletInstall["KeyNub/KeyNubLicDongle"]
Needs["KeyNub`KeyNubLicDongle`"]
```

From a clone of the SDK repository, no packaging step:

```wolfram
PacletDirectoryLoad["<clone>/bindings/wolfram/KeyNubLicDongle"]
Needs["KeyNub`KeyNubLicDongle`"]
```

The paclet does not carry the native library. Take
`keynub_licdongle_flat` for your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries or name it before
the first call:

```wolfram
LicDongleLibraryPath["/opt/keynub/libkeynub_licdongle_flat.so"]
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. In a clone of
the repository the paclet finds `natives/<platform>/` on its own, from the
working directory upwards. A kernel loads the library once;
`LicDongleLibraryPath[]` tells which.

## Notes

- Dongles are integer handles from `LicDongleOpen`; the library holds 32 at a
  time, so a loop that forgets `LicDongleClose` will notice.
- Results are associations (`LicDongleInfo`, `LicDongleVerifyGenuine`,
  `LicDongleDevices`, `LicDongleRecords`); bytes are `ByteArray`s, and every
  call taking bytes also takes a `String` for its UTF-8.
- Failures are `Failure["LicDongleError", ...]` objects carrying `"Status"`
  (the C status code), `"Operation"` and `"Detail"`, so
  `FailureQ` gates and `#["Status"]` branches.
- `LicDongleGenuineQ[h]` is the non-failing form for a gate and **fails
  closed**: every failure gives `False`.
- `LicDongleEraseAllRecords` is deliberately separate from
  `LicDongleEraseRecord`: an accidentally empty name must not wipe the dongle.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `If[!LicDongleGenuineQ[h], Abort[]]` is one line to
> delete, and Wolfram Language ships as source, encoded or not. What cannot be
> deleted is data the notebook needs and only the dongle can decrypt:
> `LicDongleAppEncrypt` at licence-issue time, `LicDongleAppDecrypt` in the
> shipped code.

## Tests

`wolframscript -f Tests/StubTests.wls` with `KEYNUB_LICDONGLE_FLAT_LIBRARY`
naming a flat library built over the SDK's C ABI stand-in runs every call
without a dongle. Wolfram Engine 13.1 or later; the free Wolfram Engine for
developers is enough.

## Links

- [KeyNub License Dongle for the Wolfram Language](https://www.keynub.com/developers/wolfram/): the product,
  and how to order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
