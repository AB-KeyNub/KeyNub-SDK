# KeyNub License Dongle — Node.js / Electron binding

`@keynub/licdongle` — the KeyNub dongle from Node.js, with TypeScript types.
Node 18+, Windows / Linux / macOS, no drivers.

```js
const { Context, Scope } = require('@keynub/licdongle');

const ctx = new Context();
const dongle = ctx.open();          // first dongle, or pass a serial
dongle.verifyGenuine();             // throws unless genuine
const session = dongle.openSession();
const data = session.appDecrypt(blob);   // <- build your licence check on this
session.close();
dongle.close();
ctx.close();
```

Or with explicit resource management, where your runtime supports it:

```js
using ctx = new Context();
using dongle = ctx.open();
using session = dongle.openSession();
```

> **Read [`../../docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> first.** `if (isLicensed())` is one line to delete, and in an Electron app the
> attacker has your source: `app.asar` is a container, not encryption, and
> unpacking it takes one command. What cannot be deleted is data the application
> needs and only the dongle can decrypt — put it through
> `appEncrypt`/`appDecrypt`.

## Why koffi, not a native addon

The binding calls the C core through [koffi](https://koffi.dev), an FFI, rather
than being a compiled N-API addon. For an Electron dependency that is the
difference between working and being a support burden: no `node-gyp`, no Python
and no compiler on every developer's machine, and — the one that matters — **no
rebuild per Electron ABI**. A native addon has to be recompiled for every Electron
version your app upgrades to; an FFI binding does not.

The trade is that the C signatures live in
[`lib/native.js`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/bindings/nodejs/lib/native.js) as strings that no compiler checks, which is
exactly why every single one of them is written out by hand against a software
dongle.

## Everything is synchronous

A dongle round trip is a millisecond or two of USB HID, so these calls are
blocking and there is no `async` variant. In a CLI that is correct. **In Electron,
call from the main process** (or a worker) — never on the renderer's event loop,
where even a few milliseconds per call will show up as jank. The usual shape is an
IPC handler:

```js
ipcMain.handle('licence:check', () => {
  const ctx = new Context();
  try {
    return ctx.open().isGenuine();
  } finally {
    ctx.close();
  }
});
```

## Errors

Failures throw `LicenseDongleError` or one of its subclasses, each carrying
`.status` (the numeric `licd_status`), `.code` (a stable string like
`KEYNUB_NO_DEVICE`) and `.detail` (the SDK's diagnostic text).

```js
try {
  dongle.verifyGenuine();
} catch (err) {
  if (err.code === 'KEYNUB_NO_DEVICE') showPleaseInsertDongle();
  else if (err instanceof CertificateInvalidError) showCounterfeitWarning(err.detail);
  else throw err;
}
```

`dongle.isGenuine()` is the non-throwing form for a gate: it returns
`{ genuine, code }` and **fails closed** — a missing dongle, an I/O error and an
invalid certificate all report `genuine: false`, with `code` telling them apart.

## Shipping the native library

The binding looks for the core library, in order:

1. `KEYNUB_LICDONGLE_LIBRARY` (an absolute path to a specific library)
2. `prebuilds/<platform>-<arch>/` inside the package
3. alongside the package
4. next to the application executable — where an Electron build puts it
5. the system search path

For Electron, put the platform's native in `prebuilds/` and mark the package as
unpacked (`asarUnpack`), because a shared library cannot be loaded from inside an
asar archive.

## License

Apache-2.0, like the rest of the SDK — [`LICENSE`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/LICENSE),
[`NOTICE`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NOTICE),
[`THIRD-PARTY-NOTICES.txt`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/THIRD-PARTY-NOTICES.txt). koffi is
MIT; the native library statically links Mbed TLS (Apache-2.0 elected) and hidapi
(BSD-style elected).

## Links

- [KeyNub License Dongle for Node.js and Electron](https://www.keynub.com/developers/nodejs/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
