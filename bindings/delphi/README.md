# KeyNub License Dongle — Delphi / Free Pascal binding

[`LicDongle.pas`](LicDongle.pas) is a direct translation of the C ABI
(`include/licdongle.h`) — a thin header, no protocol or crypto logic. It
compiles under **Delphi** and under **Free Pascal** (`{$MODE DELPHI}`), on
Windows, Linux, and macOS. Unlike the .NET/Python/Java bindings there is no
higher-level object wrapper; you call the C functions directly.

## Use

Add `LicDongle.pas` to your project (or its directory to the unit search path).
Lazarus users can instead open [`keynub_licdongle.lpk`](keynub_licdongle.lpk) with
**Package ▸ Open Package File** and add it to the project's requirements. Either
way, ensure the native `keynub_licdongle` library is loadable at runtime
(`keynub_licdongle.dll` on `PATH` / next to the exe; `libkeynub_licdongle.so`
with the shipped udev rule on Linux; `libkeynub_licdongle.dylib` on macOS).

```pascal
uses LicDongle;
var
  ctx: TLicdCtx;
  dev: TLicdDevice;
  g: TLicdGenuineResult;
begin
  if licd_init(ctx) <> LICD_OK then Halt(1);
  if licd_open(ctx, nil, dev) = LICD_OK then
  begin
    if licd_verify_genuine(dev, g) = LICD_OK then
      WriteLn('genuine, serial ', StrPas(PAnsiChar(@g.serial[0])));
    licd_close(dev);
  end;
  licd_free(ctx);
end;
```

Status codes are the `LICD_OK` / `LICD_E_*` constants; every function returns one
(except the void ones). `size_t` maps to `NativeUInt`, so the header is correct on
both 32- and 64-bit targets.

## Sample

[`../../samples/delphi/VerifyAndRead.dpr`](../../samples/delphi/VerifyAndRead.dpr) —
verify, open a session, read a `license` record, and round-trip app-data encryption.

```
# Free Pascal (Delphi mode):
fpc -Mdelphi -Fu bindings/delphi samples/delphi/VerifyAndRead.dpr
# Delphi:
dcc32 -USDK\bindings\delphi SDK\samples\delphi\VerifyAndRead.dpr
```

## Lazarus demo

The package as distributed through the Lazarus Online Package Manager carries
`demo/`: a console project that requires the package and runs every call, with
a stand-in for the native library for each platform so that it works without a
dongle. `demo/README.md` there has the steps and the expected output.

## Security

Read [`docs/integration-security.md`](../../docs/integration-security.md) before
writing your licensing check. `licd_verify_genuine` proves a genuine dongle is
attached; it cannot stop an attacker from patching your application or dropping a
fake `keynub_licdongle` library next to it. Branch on a boolean and you will be
bypassed — put dongle-derived data (`licd_app_encrypt`/`licd_app_decrypt`) on the path
your application actually needs.

## License

Apache-2.0 — see [`LICENSE`](../../LICENSE), [`NOTICE`](../../NOTICE), and
[`THIRD-PARTY-NOTICES.txt`](../../THIRD-PARTY-NOTICES.txt); ship all three alongside
the native library you redistribute. It statically links Mbed TLS (Apache-2.0
elected) and hidapi (BSD-style elected); no GPL terms apply.
