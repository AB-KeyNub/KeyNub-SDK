# KeyNub License Dongle — PowerShell Module

```powershell
Install-PSResource KeyNub.LicenseDongle      # or: Install-Module KeyNub.LicenseDongle

$dongle = Connect-KeyNubDongle               # the first dongle, or Connect-KeyNubDongle <serial>
Confirm-KeyNubDongle -Dongle $dongle         # raises unless genuine
$data = Invoke-KeyNubSession $dongle {       # the session is closed on every exit path
    param($session)
    Unprotect-KeyNubData -Session $session -Data $sealed   # <- build the licence check on this
}
Disconnect-KeyNubDongle -Dongle $dongle
```

Commands for scripts, test benches and licence-issuing tools, on Windows
PowerShell 5.1 and PowerShell 7 on Windows, Linux and macOS. The module
carries the KeyNub.LicenseDongle .NET assembly (the one on NuGet) and the
native library for Windows (x64, x86, Arm64), Linux (x64, Arm64) and macOS,
so there is nothing else to install and no driver. On Linux, install the udev
rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Commands

| Command | Does |
| --- | --- |
| `Get-KeyNubDongle` | Lists the attached dongles (serial, device path, USB ids) |
| `Connect-KeyNubDongle`, `Disconnect-KeyNubDongle` | Open by serial, device path or the first one; close |
| `Get-KeyNubDongleInfo` | Firmware and protocol versions, storage, status flags |
| `Test-KeyNubDongle` | `$true` or `$false`; **fails closed** |
| `Confirm-KeyNubDongle` | Proves the dongle genuine and returns its serial and provisioning date, or raises |
| `Open-KeyNubSession`, `Close-KeyNubSession`, `Invoke-KeyNubSession` | The encrypted session that everything below needs |
| `Get-KeyNubRecord`, `Read-KeyNubRecord` | List the records; read one as bytes or, with `-AsString`, as UTF-8 text |
| `Write-KeyNubRecord`, `Remove-KeyNubRecord`, `Clear-KeyNubRecord` | Write (bytes or a string), erase one, erase every record |
| `Get-KeyNubCounter`, `Step-KeyNubCounter` | Read and increment a monotonic counter |
| `Protect-KeyNubData`, `Unprotect-KeyNubData` | Encrypt data that only a dongle can decrypt, and decrypt it |
| `Grant-KeyNubWriteAccess`, `Set-KeyNubWriteKey` | The write role, and replacing the dongle's write key with yours |
| `Get-KeyNubLibraryVersion`, `Set-KeyNubTrustRoot` | The native library's version; a different CA root |

`Get-Help <command> -Full` describes each one.

## Notes

- Writing, erasing and incrementing need the write role:
  `Grant-KeyNubWriteAccess -Session $s -KeyPath write-key.der`, with the
  dongle's write key (a P-256 private key in PKCS#8 DER). That belongs in your
  licence-issuing tooling, never in what your users run. A new dongle accepts
  the public factory key until `Set-KeyNubWriteKey` replaces it with yours; do
  that once per dongle, when it arrives.
- The commands that change the dongle support `-WhatIf` and `-Confirm`.
  `Clear-KeyNubRecord` and `Set-KeyNubWriteKey` ask before they run; pass
  `-Confirm:$false` in a script.
- Every failure is a terminating error whose exception is the .NET binding's:
  `KeyNub.LicenseDongle.LicenseDongleException` with a `Status` and a `Detail`,
  and a subclass for the cases a script branches on
  (`DeviceNotFoundException`, `NotGenuineException`,
  `CertificateInvalidException`, `WriteAuthorizationRequiredException`,
  `SessionExpiredException`, `RecordNotFoundException`). So
  `catch [KeyNub.LicenseDongle.DeviceNotFoundException] { ... }` catches one
  case; the error id is `KeyNub.<Status>`.
- Record data and keys are byte arrays; `Write-KeyNubRecord` and
  `Protect-KeyNubData` also take a string, stored as UTF-8.
- One context per PowerShell session, opened on the first command. A process
  loads the native library once. `KEYNUB_LICDONGLE_LIBRARY` in the
  environment names a different file before that (Windows PowerShell loads it
  only under its own name, `keynub_licdongle.dll`).

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if (-not (Test-KeyNubDongle -Dongle $d)) { exit }`
> is one line, and deleting a line from a script is no effort at all. Route
> something the script needs through `Protect-KeyNubData` and
> `Unprotect-KeyNubData`, so removing the check removes the data.

## Tests

`pwsh bindings/powershell/tests/standin_test.ps1` (and the same with
`powershell` for Windows PowerShell 5.1) runs without a dongle: it builds the
.NET assembly from `bindings/dotnet` with `dotnet`, compiles a stand-in for the
C ABI (`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path,
and runs every command against it. `KEYNUB_SDK_ROOT` names the SDK sources when
the script is not inside a clone. The samples are under `samples/powershell`.

## Links

- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
- [KeyNub License Dongle for PowerShell](https://www.keynub.com/developers/powershell/): the product, and how to
  order one
