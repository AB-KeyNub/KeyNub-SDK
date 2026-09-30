# KeyNub SDK - PowerShell sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
# so that from the next session onward only your key can write records, erase
# them or increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#     openssl ecparam -name prime256v1 -genkey -noout |
#       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#     Install-PSResource KeyNub.LicenseDongle      (or Install-Module KeyNub.LicenseDongle)
#     pwsh samples/powershell/rotate_write_key.ps1 keys/keynub-shipping-writeauth.key.der my-key.der
#
# Runs on Windows PowerShell 5.1 and PowerShell 7. Targets real hardware: with
# no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It
# cannot be recovered from the dongle, and a unit rotated to a key you have
# lost has to come back to be re-provisioned.

param(
    [Parameter(Mandatory)][string]$CurrentKey,
    [Parameter(Mandatory)][string]$NewKey
)

$ErrorActionPreference = 'Stop'
Import-Module KeyNub.LicenseDongle

try {
    if (@(Get-KeyNubDongle).Count -eq 0) {
        'Connect a KeyNub dongle and re-run.'
        exit 0
    }
    $dongle = Connect-KeyNubDongle
    try {
        "Dongle $($dongle.GetSerial())"
        if ((Get-KeyNubDongleInfo -Dongle $dongle).WriteAuthRotated) {
            "This dongle's write key has already been rotated away from the factory one."
        }
        Invoke-KeyNubSession $dongle {
            param($session)
            Grant-KeyNubWriteAccess -Session $session -KeyPath $CurrentKey         # the key the dongle accepts today
            Set-KeyNubWriteKey -Session $session -KeyPath $NewKey -Confirm:$false  # from the next session: only the new one
        }
        $rotated = if ((Get-KeyNubDongleInfo -Dongle $dongle).WriteAuthRotated) { 'yes' } else { 'no' }
        "Write key rotated: $rotated"
    } finally {
        Disconnect-KeyNubDongle -Dongle $dongle
    }
} catch [KeyNub.LicenseDongle.LicenseDongleException] {
    "KeyNub error: $($_.Exception.Message)"
    exit 1
}
