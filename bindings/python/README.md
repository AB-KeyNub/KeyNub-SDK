# KeyNub License Dongle — Python binding

`keynub-licdongle` is a thin [ctypes](https://docs.python.org/3/library/ctypes.html)
wrapper over the native `keynub_licdongle` core — no protocol or crypto logic in
Python. Pure Python (no compiler needed at install); the native library is bundled
per platform. Works on Windows, Linux, and macOS with no drivers.

## Install

```
pip install keynub-licdongle
```

## Use

```python
import keynub_licdongle as kn

with kn.LicenseDongleContext() as ctx:
    for d in ctx.enumerate():
        print(d.serial, d.path)

    dongle = ctx.open()                    # first attached dongle (or open(serial=...))
    print(dongle.get_serial())

    result = dongle.verify_genuine()       # cert chain + live challenge-response
    print("genuine:", result.is_genuine)

    with dongle.open_session() as session:  # ECDH -> HKDF -> AES-256-GCM
        license = session.read_record("license")            # read role

        # Developer/provisioning tools elevate to the write role:
        session.authorize_write(master_key_der)
        session.write_record("license", new_bytes)

        # App-data envelope encryption — unusable without a genuine dongle:
        blob = session.app_encrypt(kn.Scope.DEVICE, plaintext)
        assert session.app_decrypt(blob) == plaintext
```

- `LicenseDongleContext` — enumerate / open / logging (a context manager).
- `Dongle` — `get_info`, `get_serial`, `verify_genuine`, `open_session`.
- `Session` — records, counters, app-crypto, `authorize_write`.
- Failures raise `LicenseDongleError` (with a `.status`); common cases have
  subclasses (`NotGenuineError`, `WriteAuthorizationRequiredError`, `RecordNotFoundError`, …).
- `read_record` / `write_record` accept a `progress` callback `(TransferProgress) -> bool`;
  return `False` to cancel (raises `OperationCancelledError`).

## Native library resolution

The binding loads, in order: `$KEYNUB_LICDONGLE_LIBRARY` (explicit path), the
bundled `keynub_licdongle/_libs/<lib>`, a copy next to the package, then the
system search path. Linux additionally needs the shipped udev rule (a permission
rule, not a driver).

## `licd-tool` — the command line

Installing the wheel also installs **`licd-tool`**, which drives the same
production core an application would. Useful for licence issuance, for support
("what is this dongle and is it genuine?"), and for reproducing what an
application sees without the application.

```
licd-tool list                                   # attached dongles
licd-tool info                                   # firmware, storage, provisioning state
licd-tool --trust-root ca.der verify             # prove it is genuine

# Anything inside a session needs --trust-root; anything that writes needs the
# developer master key.
licd-tool --trust-root ca.der records list
licd-tool --trust-root ca.der --master-key mk.der records write license lic.bin
licd-tool --trust-root ca.der records read license -o lic.bin
licd-tool --trust-root ca.der counter read

# Envelope-encrypt data so it only decrypts with a dongle attached.
licd-tool --trust-root ca.der appcrypto encrypt assets.bin -o assets.enc --scope developer
licd-tool --trust-root ca.der appcrypto decrypt assets.enc -o assets.bin
```

`--json` makes every command emit machine-readable output on stdout, so it drops
into a licence-issuing script. Irreversible operations refuse to run without
`--yes`: incrementing a monotonic counter cannot be undone, and `records erase
--all` wipes the dongle. Record writes are read back and compared before the tool
reports success, because a silent truncation would otherwise surface at the
customer.

Factory provisioning is deliberately **not** in this tool — it lives with the CA
in the firmware repo's `tools/provision`, is vendor-internal, and has irreversible
steps.

## Security

Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md) before
writing your licensing check. `verify_genuine()` proves a genuine dongle is attached;
it cannot stop an attacker from patching your application or pointing
`KEYNUB_LICDONGLE_LIBRARY` at a fake library. Branch on a boolean and you will be
bypassed — put dongle-derived data (`app_encrypt`/`app_decrypt`) on the path your
application actually needs.

## Tests

`python tests/test_standin.py` runs without a dongle: it compiles a stand-in for
the C ABI (`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the
path and exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK
sources when the package is not inside a clone; `KEYNUB_LICDONGLE_LIBRARY` names
a compiled stand-in instead.

## License

Apache-2.0 — see [`LICENSE`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/LICENSE), [`NOTICE`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NOTICE), and
[`THIRD-PARTY-NOTICES.txt`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/THIRD-PARTY-NOTICES.txt) (all three ship inside the
wheel, under `.dist-info/licenses/`). The bundled native statically links Mbed TLS
(Apache-2.0 elected) and hidapi (BSD-style elected); no GPL terms apply.

## Links

- [KeyNub License Dongle for Python](https://www.keynub.com/developers/python/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
