# licd-tool — KeyNub License Dongle on the Command Line

```
licd-tool list                                   the attached dongles
licd-tool info                                   firmware, storage, whether the write key is still the factory one
licd-tool verify                                 proves the dongle genuine (exit 0) or not (exit 2)
licd-tool records list
licd-tool records read license -o license.bin
licd-tool --write-key my-key.der records write license license.bin
licd-tool counter read
licd-tool appcrypto encrypt parameters.json -o parameters.sealed --scope developer
licd-tool appcrypto decrypt parameters.sealed
licd-tool --write-key factory.der rotate-write-key my-key.der --yes
```

One executable with the KeyNub core library built in: it needs no KeyNub
library beside it and no driver. For licence-issuing scripts, support ("what
is this dongle, and is it genuine?") and test benches. `--json` gives
machine-readable output on stdout; `licd-tool --help` lists every command.

## Getting It

- **Windows:** `natives/win-x64/licd-tool.exe` and `natives/win-x86/licd-tool.exe`
  in this repository, Authenticode-signed; the x64 one also runs on Windows on
  Arm.
- **Python:** `pip install keynub-licdongle` brings a `licd-tool` with the same
  commands.
- **Build it:** from a clone, against the static library in `natives/`:

```
cmake -S tools/licd-tool -B build-licd-tool
cmake --build build-licd-tool --config Release
```

On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Commands that change the dongle (`records write`, `records erase`,
  `counter increment`, `rotate-write-key`) need its write key:
  `--write-key <key.der>`, a P-256 private key in PKCS#8 DER. A new dongle
  accepts the public factory key
  ([`keys/keynub-shipping-writeauth.key.der`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/keys/keynub-shipping-writeauth.key.der))
  until `rotate-write-key` replaces it with yours.
- Irreversible commands also need `--yes`: `records erase --all`,
  `counter increment`, `rotate-write-key`.
- `records write` reads the record back and compares it before it reports
  success.
- `-` as a file name is stdin; without `-o`, `records read` and `appcrypto`
  write the bytes to stdout unchanged.
- Exit status: 0 success, 1 failure (and `list` with no dongle attached), 2 a
  usage error or a dongle that is not genuine.
- `--trust-root <ca.der>` verifies against a CA root other than the KeyNub
  root that is built in.

## Tests

`python tools/licd-tool/tests/standin_test.py` runs without a dongle: it
compiles `licd_tool.c` together with a stand-in for the C ABI
(`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
runs every command, checking output and exit status.

## Links

- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [KeyNub License Dongle](https://www.keynub.com/): the product, and how to order one
