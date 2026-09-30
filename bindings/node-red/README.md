# KeyNub License Dongle — Node-RED Nodes

Node-RED nodes for the [KeyNub](https://www.keynub.com/) USB-C license dongle: prove that
a genuine dongle is attached, read and write the licence records it holds, read and
increment its monotonic counters, and encrypt data that only a dongle can decrypt. For
flows sold or licensed with an instrument, a test bench or a machine: the flow runs where
the dongle is, and not elsewhere.

## Install

In Node-RED, **Menu ▸ Manage palette ▸ Install**, and search for
`@keynub/node-red-licdongle`; or in your Node-RED user directory (usually `~/.node-red`):

```
npm install @keynub/node-red-licdongle
```

Node-RED 3.0 or later on Node.js 18 or later, on Windows, Linux (x64 and Arm64) and
macOS. The dongle needs no driver. On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md) once, so that
Node-RED can open the dongle without root.

## Nodes

| Node | Does |
| --- | --- |
| **keynub genuine** | Proves the dongle genuine: output 1 with `{ genuine: true, serial, provisionedDate }`, output 2 with `{ genuine: false, code, detail }` for every failure, a missing dongle included |
| **keynub record** | `list`, `read`, `write` or `erase` a licence record; the name comes from the node or `msg.topic`; `read` gives a Buffer or a UTF-8 string |
| **keynub counter** | `read` or `increment` a monotonic counter (`msg.counter` overrides the node's id) |
| **keynub crypto** | `encrypt` data so that only a dongle can decrypt it (scope *developer*: any dongle you have issued; *device*: this one), and `decrypt` it |
| **keynub-dongle** (configuration) | Which dongle (the first one, or by serial), and the file holding its write key |

Writing and erasing records and incrementing counters need the dongle's write key, a P-256
private key in PKCS#8 DER: its file goes in the **keynub-dongle** configuration and is kept
with the flow's credentials. A new dongle accepts the public factory key until you replace it
with yours; see the SDK's
[`samples`](https://github.com/AB-KeyNub/KeyNub-SDK/tree/master/samples). Keep the write key
on the machines that issue licences, not on the ones that run the flow.

Every failure goes to Node-RED's error handling, so a **Catch** node receives the message,
with `msg.keynub.code` set to the SDK's code (`KEYNUB_NO_DEVICE`, `KEYNUB_RECORD_NOT_FOUND`,
`KEYNUB_TAG_MISMATCH`, ...) and `msg.keynub.detail` to its diagnostic text. The example flow
under **Menu ▸ Import ▸ Examples** checks the dongle and lists its records.

> A flow that only branches on **keynub genuine** is easy to rewire. Encrypt the parameters
> the protected part of the flow needs with **keynub crypto**, ship only the encrypted form,
> and decrypt them after **keynub genuine**: then the flow cannot run without the dongle.
> [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> explains the pattern.

## Tests

`npm install && npm test` in `bindings/node-red` runs every node in a Node-RED runtime
against a stand-in for the C ABI (`bindings/julia/test/stub/licd_stub.c`), compiled with the C
compiler on the path; it needs no dongle.

## Links

- [KeyNub License Dongle](https://www.keynub.com/developers/nodejs/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [`@keynub/licdongle`](https://www.npmjs.com/package/@keynub/licdongle), the Node.js binding
  these nodes use
