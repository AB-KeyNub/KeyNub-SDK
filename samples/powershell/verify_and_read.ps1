# KeyNub SDK - PowerShell sample: verify a dongle and read what it holds.
#
#     Install-PSResource KeyNub.LicenseDongle      (or Install-Module KeyNub.LicenseDongle)
#     pwsh samples/powershell/verify_and_read.ps1
#
# Runs on Windows PowerShell 5.1 and PowerShell 7. Targets real hardware: with
# no dongle attached it prints guidance and exits 0.

$ErrorActionPreference = 'Stop'
Import-Module KeyNub.LicenseDongle

function Show-Dongle {
    param($Dongle)
    $i = Get-KeyNubDongleInfo -Dongle $Dongle
    "Protocol v$($i.ProtocolVersion), firmware v$($i.FirmwareVersion), $($i.DataFree) of $($i.DataCapacity) bytes free."
    # The only trace a firmware hang leaves behind. Worth reporting to support.
    if ($i.WatchdogReboot) {
        "WARNING: this dongle's previous boot ended in a watchdog reset."
    }
    $g = Confirm-KeyNubDongle -Dongle $Dongle
    "Genuine: yes (serial $($g.Serial), provisioned $($g.ProvisionedDate))"
}

function Show-Record {
    param($Session)
    $records = @(Get-KeyNubRecord -Session $Session)
    "$($records.Count) record(s) on the dongle:"
    foreach ($r in $records) {
        '  {0,-16} {1} bytes' -f $r.Name, $r.Size
    }
    # A missing record is a normal state, not an error.
    if ($records.Name -contains 'license') {
        $license = Read-KeyNubRecord -Session $Session -Name license
        "Read $($license.Length) bytes from the license record."
    }
}

# The part that protects something. At licence-issue time you would call
# Protect-KeyNubData once, with a developer dongle, and ship only the sealed
# data; the script then cannot proceed without a dongle, because it holds no
# other copy. -Scope Developer lets any dongle you have issued decrypt it, so
# one file serves every customer; -Scope Device locks it to one dongle.
function Test-Protection {
    param($Session)
    $needed = 'the data this script cannot run without'
    $sealed = Protect-KeyNubData -Session $Session -Scope Developer -Data $needed
    $recovered = Unprotect-KeyNubData -Session $Session -Data $sealed -AsString
    $verdict = if ($recovered -eq $needed) { 'recovered intact' } else { 'MISMATCH' }
    "App-crypto round trip: $($needed.Length) bytes -> $($sealed.Length) sealed -> $verdict"
}

try {
    "KeyNub library v$(Get-KeyNubLibraryVersion)"
    if (@(Get-KeyNubDongle).Count -eq 0) {
        'Connect a KeyNub dongle and re-run.'
        exit 0
    }
    $dongle = Connect-KeyNubDongle          # the first dongle, or: Connect-KeyNubDongle <serial>
    try {
        Show-Dongle -Dongle $dongle
        Invoke-KeyNubSession $dongle {      # the session is closed on every exit path
            param($session)
            Show-Record -Session $session
            Test-Protection -Session $session
        }
    } finally {
        Disconnect-KeyNubDongle -Dongle $dongle
    }
} catch [KeyNub.LicenseDongle.LicenseDongleException] {
    "KeyNub error: $($_.Exception.Message)"
    exit 1
}
