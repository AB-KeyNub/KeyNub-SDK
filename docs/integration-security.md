# Integrating KeyNub securely

**Read this before you write your licensing check.** The dongle is strong hardware,
but hardware cannot fix a weak integration — and the most common integration is a
weak one. This document is normative guidance for developers building KeyNub into
an application.

The one-sentence version: **never let a boolean returned by this SDK be the thing
that protects your product.** Make something your application genuinely needs pass
through the dongle.

## 1. The threat model you are actually up against

The attacker is not a stranger on the network. It is the person the software was
sold to, running it on a machine they fully own, with a debugger, root/admin, and
unlimited time. They can read your binary, hook your calls, and replace any library
you load.

That reality is baked into the KeyNub design: the dongle holds an ECC private key
inside a secure element that never exports it, presents an X.509 certificate
chaining to KeyNub's root, and proves possession by signing a fresh challenge. What
the dongle guarantees is therefore precise and worth stating exactly:

> A genuine KeyNub dongle, with this serial, is attached to this machine right now,
> and the session bytes came from it.

That is a strong guarantee, and it is **not** the same as "this software is licensed."
Nothing the dongle can do stops the attacker from editing the code that asks the
question. So:

- The SDK is **not** an obfuscator, a packer, or an anti-debug layer.
- The SDK's return values are **not** a trust boundary — they arrive inside the
  attacker's own process.
- Publishing this SDK openly costs you nothing here. An attacker who controls the
  host can read the exported symbols of the shipped library and watch the USB
  traffic regardless. The protection is the key in the secure element, not secrecy
  about how to talk to it.

## 2. The anti-pattern

This is the integration to avoid, in every language:

```csharp
// DO NOT DO THIS.
if (dongle.VerifyGenuine().IsGenuine)
    Application.Run();        // <-- one branch, one byte to flip
else
    Environment.Exit(1);
```

Two cheap attacks defeat it, and neither one touches the cryptography:

1. **Patch the branch.** Invert or delete the conditional. One byte, no keys needed.
2. **Replace the library.** Drop in a stand-in `keynub_licdongle.dll` /
   `.so` / `.dylib` that exports the same handful of symbols and returns
   `LICD_OK` with a plausible `licd_genuine_result`. The SDK is loaded by name from
   a path the attacker controls, so nothing prevents this — and because the check's
   only output is a boolean, a fake that always says "yes" is a complete forgery.

Both attacks work because the *value* of the check is one bit. Raise the cost by
making the check produce something that cannot be guessed.

## 3. The pattern: make the dongle hold something you need

Use [`licd_app_encrypt` / `licd_app_decrypt`](../include/licdongle.h)
(protocol §5.4). The SDK generates a random AES-256 key, encrypts your payload on
the host, and has the dongle wrap the key; decryption requires the dongle to unwrap
it. Bulk data never crosses USB, so payload size costs you nothing.

Now the attack surface changes shape. A fake library can still return `LICD_OK`
from `licd_app_decrypt` — but it must also return the **plaintext**, and it does not
have the key. The forgery has to produce data it cannot compute.

Encrypt something whose absence stops the program from working:

- Configuration, model data, rules, calibration tables, map data, content packs —
  whatever your application cannot run without.
- Assets that would have to be re-authored to replace.
- A signed license payload (entitlements, expiry, seat count) that your code
  *parses*, rather than a flag it tests.

Pick the scope deliberately:

| Scope | Who can decrypt | Use for |
| --- | --- | --- |
| `LICD_SCOPE_DEVICE` | only that one physical dongle | per-customer data, node-locked content |
| `LICD_SCOPE_DEVELOPER` | any dongle from your batch | data shipped once to all customers |

`LICD_SCOPE_DEVELOPER` is the right default for content you ship in the installer;
`LICD_SCOPE_DEVICE` for anything issued to one customer. Both require only the read
role, so deployed applications can use them freely — no master key on the customer's
machine.

## 4. Practical hardening

Ordered by how much they buy you:

1. **Put dongle-derived data on the critical path.** Everything else on this list is
   a delay tactic; this one changes what the attacker must *produce*. If your
   program still runs correctly when every SDK call is stubbed, no other item here
   will save you.
2. **Decrypt late, repeatedly, and where the work happens.** One decrypt at startup
   is one place to attack. Decrypt each asset at the point of use, so removing the
   dongle degrades the program continuously rather than at a single gate.
3. **Do not cache the plaintext to disk.** A cache is a licence-free copy, and it
   converts your careful design back into the anti-pattern.
4. **Bind counters to entitlements you enforce.** `licd_counter_read` /
   `licd_counter_increment` are monotonic and hardware-backed — useful for
   activation counts and trial consumption, and they cannot be rolled back by
   restoring a disk image. Increment requires the write role.
5. **Verify the serial against your own records** when it matters. `verify_genuine`
   proves the dongle is real; only your licence records say whether *that* dongle is
   entitled to *this* product version.
6. **Handle absence as a normal state, not an assertion.** `LICD_E_NO_DEVICE`
   happens when a user unplugs a dongle or a USB hub resets. Report it clearly and
   let the user re-plug; do not crash, and do not silently continue in a degraded
   mode that turns out to be the full product.
7. **Keep the developer master key out of your application.** `licd_write_auth`
   elevates a session to the write role and belongs only in your licence-issuing
   tool. A master key shipped to customers is the one mistake that compromises your
   whole product line rather than one seat.

## 5. What KeyNub protects, and what it does not

| Attack | Outcome |
| --- | --- |
| Cloning a dongle | Infeasible — the private key never leaves the secure element. |
| Forging a device certificate | Infeasible without KeyNub's root CA key (HSM-held). |
| Replaying a genuineness proof | Fails — each proof signs a fresh host challenge. |
| Reading or tampering with session traffic | Fails — AES-256-GCM over an ECDH session. |
| Rolling back a counter | Fails — monotonic in hardware. |
| Exploiting a memory-safety bug in the dongle's own USB or parsing code | Contained — see §6. That code runs isolated and cannot address a key. |
| Reading the wire protocol / this SDK's source | No benefit — both are public by design. |
| **Patching the host application** | **Not prevented.** Mitigated only by §3. |
| **Substituting a fake SDK library** | **Not prevented.** Mitigated only by §3. |

The bottom two rows are the whole reason this document exists. They are properties
of *your* integration, not of the dongle, and §3 is how you address them.

## 6. What the device does to contain its own bugs

Everything above is about attacks on the cryptography or on your integration. A
security reviewer will also ask the question the rest of this document does not
answer: **what if the dongle's own firmware has a bug?**

It is a fair question, and the honest form of it is specific. Every byte you send
arrives as a USB packet and is reassembled into a protocol frame. A USB stack and a
parser are where a memory-safety defect is most likely to live, and they are the only
part of the firmware an attacker can reach at all. So that is the code that is fenced
off:

| Runs isolated | Stays protected |
| --- | --- |
| USB stack, HID transport, frame reassembly | device key, session keys, at-rest key, the secure element, license storage, firmware update |

On the dongle's Arm Cortex-M33 this split is made by **TrustZone**: the exposed code
runs in the Non-secure world, unprivileged, with its RAM execute-never and its own
code read-only. The separation is enforced by hardware rather than by convention, and
it is fail-closed — that world is granted its own RAM, the USB controller and a timer,
and every other address and peripheral is denied by default, including the secure
element's bus, flash programming and the one-time-programmable memory. What it needs
from the protected side it must ask for through a small set of gateway calls, which
validate every pointer they are handed against the hardware's own view of what that
world could legitimately reach.

The consequence of a defect in the code that parses your traffic is therefore bounded:
code execution in a world that can talk to USB and cannot read a key.

**You do not have to take this on trust.** `licd_get_info` reports it as
`licd_info.isolated` (`Isolated`, `isolated`, `IsIsolated` — whatever your binding
calls it). The firmware does not derive that flag from its own build configuration;
at boot it asks the hardware how an access from the isolated world *would* be
attributed, for the keys, the storage and its own memory, and reports what the
hardware answered. A build whose containment is not what it claims does not set it.
Note that the software simulator reports `false`, deliberately — it has no hardware
to fence anything off, and a test double able to claim the property could satisfy a
check that only real containment should pass.

**What this does not do.** It does not make your licence check harder to bypass. Both
attacks in §2 are entirely unaffected, because they happen on the host, inside your
process, where the dongle has no reach. Device-side containment is about the dongle
keeping the promise in §1 — *this key never leaves the secure element* — even if its
own firmware turns out to be defective. It is not a substitute for §3, and if you take
one thing from this document it should still be §3.

## 7. Note on the simulator

The SDK ships an in-process software dongle (`keynub_licdongle_sim`) so you can
develop and run your full test suite before hardware arrives, and evaluate the
integration before buying anything. It is a test double: it fakes a genuine device
using fixture keys.

It is deliberately kept out of the production library — the released
`keynub_licdongle` exports none of its entry points — and it must never be shipped
in an application. Note also what its existence demonstrates: a fake dongle is easy
to build, which is exactly why §3 matters. An integration that the simulator can
satisfy is an integration an attacker can satisfy.

## 8. Reporting a vulnerability

Found a weakness in the protocol, the SDK, or the firmware? Please report it
privately — see [`SECURITY.md`](../SECURITY.md).
