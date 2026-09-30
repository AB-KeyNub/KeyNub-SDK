@{
    RootModule           = 'KeyNub.LicenseDongle.psm1'
    ModuleVersion        = '1.1.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID                 = '76684519-c72d-4b13-b403-d65eb8c4c49e'
    Author               = 'KeyNub'
    CompanyName          = 'KeyNub'
    Copyright            = 'Copyright (c) KeyNub'
    Description          = 'Client for the KeyNub USB license dongle: proves that a dongle is genuine, reads and writes the license records it holds, reads and increments its monotonic counters, and encrypts data that only a dongle can decrypt. Includes the native library for Windows, Linux and macOS; no driver to install.'
    PowerShellVersion    = '5.1'
    DotNetFrameworkVersion = '4.7.2'
    RequiredAssemblies   = @('lib/KeyNub.LicenseDongle.dll')
    FunctionsToExport    = @(
        'Get-KeyNubLibraryVersion'
        'Set-KeyNubTrustRoot'
        'Get-KeyNubDongle'
        'Connect-KeyNubDongle'
        'Disconnect-KeyNubDongle'
        'Get-KeyNubDongleInfo'
        'Test-KeyNubDongle'
        'Confirm-KeyNubDongle'
        'Open-KeyNubSession'
        'Close-KeyNubSession'
        'Invoke-KeyNubSession'
        'Grant-KeyNubWriteAccess'
        'Set-KeyNubWriteKey'
        'Get-KeyNubRecord'
        'Read-KeyNubRecord'
        'Write-KeyNubRecord'
        'Remove-KeyNubRecord'
        'Clear-KeyNubRecord'
        'Get-KeyNubCounter'
        'Step-KeyNubCounter'
        'Protect-KeyNubData'
        'Unprotect-KeyNubData'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('KeyNub', 'license', 'licensing', 'dongle', 'usb', 'hid', 'copy-protection',
                             'hardware', 'security', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'Linux',
                             'MacOS')
            LicenseUri   = 'https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/BINARY-LICENSE.txt'
            ProjectUri   = 'https://www.keynub.com/developers/powershell/'
            ReleaseNotes = 'https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/bindings/powershell/CHANGELOG.md'
        }
    }
}
