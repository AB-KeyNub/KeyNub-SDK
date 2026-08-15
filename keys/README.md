# The factory write-auth key

`keynub-shipping-writeauth.key.der` is the P-256 private key that **every KeyNub
dongle leaves the factory holding**. It is published here on purpose.

PKCS#8 DER, 138 bytes. Its public half — the value actually installed in a dongle,
as raw `X‖Y` — is:

```
9a9f9089975a99c83d87466527f803ba5957a194ad3d77e808b181f8c64e9421
ec7e2d923d837123618d1a4cd456e944563370b1d115a9e7932bbefef4fd9477
```

## Why a private key is in a public repository

Every customer needs it. A dongle's write role — writing records, erasing them,
incrementing counters — is granted by proving possession of the dongle's current
write-auth key, and rotation to your own key needs that proof too. So this key
goes to everyone who buys a dongle, which means it is not a secret and there is
nothing to be gained by pretending otherwise. Publishing it makes the samples run
out of the box and makes the situation plain instead of implied.

## What it grants, and what it does not

Holding this key lets someone take the write role on a dongle that **has not been
rotated yet**, if they have it in their hand. On such a dongle they can:

* write, overwrite and erase records — including your licence records
* increment counters, which cannot be undone
* **rotate the key to one of their own**, after which you cannot write to that
  dongle again and there is no recovery short of replacing the hardware

It grants nothing at all on a dongle that has been rotated, and it never grants:

* reading or forging another customer's licence data — app-crypto keys are
  derived per customer, so a blob sealed for one customer does not open for
  another
* anything without physical possession of the dongle
* anything about the dongle's identity: `verify_genuine` is unaffected

## So: rotate on receipt

```
python rotate_write_key.py --current keys/keynub-shipping-writeauth.key.der \
                           --generate my-key.der
```

There is a `rotate_write_key` sample in every language — see
[`../README.md`](../README.md). After rotating, keep your own key the way you keep
your licence-signing key: it cannot be recovered from a dongle.

**Check before you ship.** `get_info` reports `writeauth_rotated`. A dongle
reporting false still answers to the key in this folder, so make your
licence-issuing tool refuse it, and check the whole delivery before it leaves
you:

```python
info = dongle.get_info()
if not info.writeauth_rotated:
    raise SystemExit(f"{dongle.get_serial()} is still on the factory key")
```
