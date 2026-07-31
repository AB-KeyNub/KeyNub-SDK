# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue.

- **Contact:** the contact form at <https://www.keynub.com/#contact>. Mark the
  message as a security report so it is routed rather than queued with sales
  enquiries. If you would rather use GitHub's private vulnerability reporting,
  that is enabled on this repository as well.
- Please include: affected component and version, what you observed, and enough
  detail to reproduce it.
- We will acknowledge receipt and keep you updated on the fix. Please give us a
  reasonable window to ship one before disclosing publicly.

## Scope

In scope:

- The SDK (`keynub_licdongle` core, the .NET/Python/Java/Delphi bindings).
- The wire protocol (the protocol specification) — design weaknesses as
  well as implementation bugs.
- The dongle firmware and its provisioning chain.

Out of scope — these are known, documented properties rather than vulnerabilities:

- **Patching a host application, or substituting a fake SDK library, to bypass a
  licence check.** Host code runs on hardware the attacker controls; this cannot be
  prevented by the dongle. See [`docs/integration-security.md`](docs/integration-security.md),
  which explains the integration pattern that makes such bypasses ineffective.
- The test simulator (`keynub_licdongle_sim`) impersonating a genuine dongle. That
  is its purpose. It is excluded from the released library.

Findings that let an attacker clone a dongle, extract a device key, forge a
certificate chain, decrypt or tamper with session traffic, roll back a monotonic
counter, or elevate to the write role without the developer master key are very much
in scope and are treated as serious.

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x | yes |

Security fixes land in the latest 1.x release. There is no separate long-term
branch: the C ABI is stable across 1.x, so a newer 1.x native library is a drop-in
replacement, and a managed binding is a version bump.

One thing worth knowing when you plan an update: a dongle already in the field does
not stop working because an SDK release has been superseded. Verification is local
and needs nothing from us, so there is no deadline attached to a release. What a
new release gives you is the fix itself, and taking it means rebuilding your
application against the newer library.
