# Every command of the module against a stand-in for the C ABI
# (bindings/julia/test/stub/licd_stub.c): one imaginary dongle held in memory,
# so the whole module runs without hardware. Run it with Windows PowerShell 5.1
# and with PowerShell 7:
#
#     powershell -File bindings/powershell/tests/standin_test.ps1
#     pwsh -File bindings/powershell/tests/standin_test.ps1
#
# It stages the module in a temporary folder with the KeyNub.LicenseDongle
# assembly built from bindings/dotnet (the .NET SDK, dotnet, on the path) and
# compiles the stand-in with the C compiler on the path (cc, gcc, clang, zig cc
# or cl). -ModulePath names an already staged module folder instead;
# KEYNUB_SDK_ROOT names the SDK sources when the script is not inside a clone.

[CmdletBinding()]
param([string]$ModulePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$windows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$macos = (-not $windows) -and $IsMacOS

function Find-SdkRoot {
    if ($env:KEYNUB_SDK_ROOT) {
        return $env:KEYNUB_SDK_ROOT
    }
    $dir = $PSScriptRoot
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir 'bindings/flat/licd_flat.c')) {
            return $dir
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) {
            break
        }
        $dir = $parent
    }
    throw 'the SDK sources were not found above this script; set KEYNUB_SDK_ROOT'
}

function Invoke-Native {
    # Runs a program; $true when it exits with 0. Its output is dropped.
    param([string]$Program, [string[]]$Arguments, [string]$Directory)
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command $Program -CommandType Application -ErrorAction SilentlyContinue)) {
        return $false
    }
    Push-Location -LiteralPath $Directory
    try {
        & $Program @Arguments 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}

function Build-StandIn {
    param([string]$Root, [string]$Directory)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    # Windows PowerShell binds the assembly's imports by the library's own file
    # name, so on Windows the stand-in takes that name, alone in its own folder.
    $name = if ($windows) { 'keynub_licdongle.dll' }
            elseif ($macos) { 'libkeynub_licdongle_standin.dylib' }
            else { 'libkeynub_licdongle_standin.so' }
    $output = Join-Path $Directory $name
    $include = Join-Path $Root 'core/include'
    if (-not (Test-Path -LiteralPath (Join-Path $include 'licdongle.h'))) {
        $include = Join-Path $Root 'include'
    }
    $source = Join-Path $Root 'bindings/julia/test/stub/licd_stub.c'
    $gcc = @('-shared', '-O1', '-DLICD_BUILD_SHARED', "-I$include", '-o', $output, $source)
    if (-not $windows) {
        $gcc += '-fPIC'
    }
    $cl = @('/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', "/I$include", "/Fe:$output", $source)
    foreach ($try in @(@('cc', $gcc), @('gcc', $gcc), @('clang', $gcc), @('zig', (@('cc') + $gcc)), @('cl', $cl))) {
        if ((Invoke-Native -Program $try[0] -Arguments $try[1] -Directory $Directory) -and (Test-Path -LiteralPath $output)) {
            return $output
        }
    }
    throw 'the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path'
}

function Build-Module {
    param([string]$Root, [string]$Directory)
    $module = Join-Path $Directory 'KeyNub.LicenseDongle'
    Copy-Item -Recurse -LiteralPath (Join-Path $Root 'bindings/powershell/KeyNub.LicenseDongle') -Destination $module
    # The assembly is built from a copy, so the source tree gains no bin/ or obj/.
    $project = Join-Path $Directory 'dotnet'
    New-Item -ItemType Directory -Force -Path $project | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $Root 'bindings/dotnet/KeyNub.LicenseDongle') |
        Where-Object { $_.Name -notin 'bin', 'obj' } |
        Copy-Item -Destination $project -Recurse
    $out = Join-Path $Directory 'assembly'
    $ok = Invoke-Native -Program 'dotnet' -Directory $project -Arguments @(
        'build', (Join-Path $project 'KeyNub.LicenseDongle.csproj'), '-c', 'Release', '-f', 'netstandard2.0',
        '-o', $out, '-nologo')
    if (-not $ok) {
        throw 'dotnet build of the KeyNub.LicenseDongle assembly failed'
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $module 'lib') | Out-Null
    Copy-Item -LiteralPath (Join-Path $out 'KeyNub.LicenseDongle.dll') -Destination (Join-Path $module 'lib')
    $module
}

# --- checks ------------------------------------------------------------------

function Check {
    param([bool]$Condition, [string]$What)
    if (-not $Condition) {
        throw "FAILED: $What"
    }
}

# Runs the block, requires a terminating error whose exception is of the given
# type (and, for a KeyNub error, has the given status); returns the error.
function Fails {
    param([scriptblock]$Block, [type]$Type, [string]$Status, [string]$What)
    $caught = $null
    try {
        & $Block | Out-Null
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        throw "FAILED: ${What}: nothing was raised"
    }
    $e = $caught.Exception
    if ($e -isnot $Type) {
        throw "FAILED: ${What}: raised $($e.GetType().FullName) ($($e.Message)), not $($Type.FullName)"
    }
    if ($Status) {
        Check ($e.Status.ToString() -eq $Status) "${What}: status $($e.Status), expected $Status"
        Check ($caught.FullyQualifiedErrorId -like "KeyNub.$Status,*") "${What}: error id $($caught.FullyQualifiedErrorId)"
    }
    $caught
}

function Same {
    param([byte[]]$A, [byte[]]$B)
    ($A.Length -eq $B.Length) -and ([Convert]::ToBase64String($A) -eq [Convert]::ToBase64String($B))
}

function Utf8 {
    param([string]$Text)
    , [System.Text.Encoding]::UTF8.GetBytes($Text)
}

$Serial = '04A1B2C3D4E5F6'
$FactoryKey = [byte[]](0x30, 0x10, 0x01, 0x02, 0x03)
$ReplacementKey = [byte[]](0x30, 0x11, 0x09, 0x08, 0x07, 0x06)

function Test-Discovery {
    Check ((Get-KeyNubLibraryVersion) -eq [version]'9.8.7') 'the stand-in reports 9.8.7'
    $devices = @(Get-KeyNubDongle)
    Check ($devices.Count -eq 1) 'one dongle attached'
    Check ($devices[0].Serial -eq $Serial) 'its serial'
    Check ($devices[0].Path -eq 'stub:0') 'its path'
    Check ($devices[0].VendorId -eq 0x1234 -and $devices[0].ProductId -eq 0xABCD) 'its USB ids'

    $err = Fails { Connect-KeyNubDongle -Serial nope } ([KeyNub.LicenseDongle.DeviceNotFoundException]) 'NoDevice' 'an unknown serial'
    Check ($err.Exception.Message -like '*no device*') 'the message carries the status text'
    Check ($err.Exception.Detail -eq 'no dongle with that serial') 'the exception carries the detail'
    Check ($err.Exception.Message -like '*no dongle with that serial*') 'the message carries the detail'
    Check ($err.CategoryInfo.Category -eq 'ObjectNotFound') 'a missing dongle is ObjectNotFound'
    Fails { Connect-KeyNubDongle -DevicePath 'stub:9' } ([KeyNub.LicenseDongle.DeviceNotFoundException]) 'NoDevice' 'an unknown path' | Out-Null

    $typed = $false
    try {
        Connect-KeyNubDongle -Serial nope | Out-Null
    } catch [KeyNub.LicenseDongle.DeviceNotFoundException] {
        $typed = $true
    }
    Check $typed 'catch [KeyNub.LicenseDongle.DeviceNotFoundException] catches it'
    $base = $false
    try {
        Connect-KeyNubDongle -Serial nope | Out-Null
    } catch [KeyNub.LicenseDongle.LicenseDongleException] {
        $base = $true
    }
    Check $base 'catch [KeyNub.LicenseDongle.LicenseDongleException] catches it'

    foreach ($d in @((Connect-KeyNubDongle), (Connect-KeyNubDongle $Serial), (Connect-KeyNubDongle -DevicePath 'stub:0'),
                     (Get-KeyNubDongle | Connect-KeyNubDongle))) {
        Check ($d -is [KeyNub.LicenseDongle.Dongle]) 'Connect-KeyNubDongle returns a Dongle'
        Check ($d.GetSerial() -eq $Serial) 'the opened dongle'
        Disconnect-KeyNubDongle -Dongle $d
    }
}

function Test-InfoAndGenuine {
    $d = Connect-KeyNubDongle
    try {
        $i = Get-KeyNubDongleInfo -Dongle $d
        Check ($i.ProtocolVersion -eq [version]'1.0' -and $i.FirmwareVersion -eq [version]'2.3.4') 'versions'
        Check ($i.SeReady -and $i.Provisioned -and $i.Isolated) 'status flags set'
        Check (-not ($i.WatchdogReboot -or $i.WriteAuthRotated)) 'status flags clear'
        Check ($i.DataCapacity -eq 1048576 -and $i.DataFree -eq 1000000) 'storage'
        Check (($d | Get-KeyNubDongleInfo).FirmwareVersion -eq [version]'2.3.4') 'info from the pipeline'

        Check ((Test-KeyNubDongle -Dongle $d) -eq $true) 'Test-KeyNubDongle: genuine'
        $g = Confirm-KeyNubDongle -Dongle $d
        Check ($g.IsGenuine -and $g.Serial -eq $Serial -and $g.ProvisionedDate -eq '2026-08-15') 'Confirm-KeyNubDongle'
    } finally {
        Disconnect-KeyNubDongle -Dongle $d
    }
    Check ((Test-KeyNubDongle -Dongle $d) -eq $false) 'Test-KeyNubDongle fails closed on a closed dongle'
}

function Test-RecordStore {
    $d = Connect-KeyNubDongle
    $s = Open-KeyNubSession -Dongle $d
    try {
        $payload = 'license-blob-0123456789'
        $auth = [KeyNub.LicenseDongle.WriteAuthorizationRequiredException]
        $err = Fails { Write-KeyNubRecord -Session $s -Name lic -Value $payload } $auth 'AuthRequired' 'writing needs the write role'
        Check ($err.CategoryInfo.Category -eq 'PermissionDenied') 'the write role is PermissionDenied'
        Fails { Remove-KeyNubRecord -Session $s -Name lic } $auth 'AuthRequired' 'erasing needs the write role' | Out-Null
        Fails { Clear-KeyNubRecord -Session $s -Confirm:$false } $auth 'AuthRequired' 'erasing all needs the write role' | Out-Null
        Fails { Step-KeyNubCounter -Session $s -Id 0 } $auth 'AuthRequired' 'incrementing needs the write role' | Out-Null
        Fails { Grant-KeyNubWriteAccess -Session $s -Key ([byte[]](0x30, 0x00)) } ([KeyNub.LicenseDongle.NotGenuineException]) 'NotGenuine' 'a wrong key' | Out-Null

        $keyFile = Join-Path $script:Work 'factory.der'
        [System.IO.File]::WriteAllBytes($keyFile, $FactoryKey)
        Grant-KeyNubWriteAccess -Session $s -KeyPath $keyFile

        Write-KeyNubRecord -Session $s -Name lic -Value $payload
        Check ((Read-KeyNubRecord -Session $s -Name lic -AsString) -eq $payload) 'a string round-trips'
        $bytes = Read-KeyNubRecord -Session $s -Name lic
        Check ($bytes -is [byte[]]) 'Read-KeyNubRecord returns one byte array'
        Check (Same $bytes (Utf8 $payload)) 'the bytes are the UTF-8 of the string'
        Write-KeyNubRecord -Session $s -Name cfg -Value (Utf8 'cfgdata')
        $records = @(Get-KeyNubRecord -Session $s | Sort-Object Name)
        Check (($records.Name -join ',') -eq 'cfg,lic') 'two records listed'
        Check ($records[1].Size -eq $payload.Length) 'with their sizes'
        Check (Same (Read-KeyNubRecord -Session $s cfg) (Utf8 'cfgdata')) 'bytes round-trip'

        $notFound = [KeyNub.LicenseDongle.RecordNotFoundException]
        Fails { Read-KeyNubRecord -Session $s -Name nope } $notFound 'NotFound' 'reading a missing record' | Out-Null
        Fails { Remove-KeyNubRecord -Session $s -Name nope } $notFound 'NotFound' 'erasing a missing record' | Out-Null
        Fails { Read-KeyNubRecord -Session $s -Name '' } ([System.Management.Automation.ParameterBindingException]) '' 'an empty name' | Out-Null
        Fails { Remove-KeyNubRecord -Session $s -Name '' } ([System.Management.Automation.ParameterBindingException]) '' 'an empty name is never "erase all"' | Out-Null
        Check (@(Get-KeyNubRecord -Session $s).Count -eq 2) 'nothing erased by the empty name'

        Write-KeyNubRecord -Session $s -Name lic -Value 'changed' -WhatIf
        Check ((Read-KeyNubRecord -Session $s -Name lic -AsString) -eq $payload) '-WhatIf writes nothing'
        Remove-KeyNubRecord -Session $s -Name cfg
        Check ((@(Get-KeyNubRecord -Session $s).Name -join ',') -eq 'lic') 'one record erased'

        Write-KeyNubRecord -Session $s -Name empty -Value ([byte[]]@())
        $empty = Read-KeyNubRecord -Session $s -Name empty
        Check ($empty -is [byte[]] -and $empty.Length -eq 0) 'an empty record is an empty byte array'
        Write-KeyNubRecord -Session $s -Name empty -Value ''
        Check ((Read-KeyNubRecord -Session $s -Name empty -AsString) -eq '') 'an empty string'

        $big = [byte[]](0..2999 | ForEach-Object { ($_ * 31 + 5) % 256 })
        Write-KeyNubRecord -Session $s -Name big -Value $big
        Check (Same (Read-KeyNubRecord -Session $s -Name big) $big) 'a record bigger than one transfer'
        Fails { Write-KeyNubRecord -Session $s -Name bad -Value 42 } ([System.ArgumentException]) '' 'a number is not record data' | Out-Null

        Clear-KeyNubRecord -Session $s -Confirm:$false
        Check (@(Get-KeyNubRecord -Session $s).Count -eq 0) 'Clear-KeyNubRecord erases every record'
    } finally {
        Close-KeyNubSession -Session $s
        Disconnect-KeyNubDongle -Dongle $d
    }
}

function Test-CounterValue {
    $d = Connect-KeyNubDongle
    try {
        Invoke-KeyNubSession $d {
            param($s)
            Grant-KeyNubWriteAccess -Session $s -Key $FactoryKey
            $before = Get-KeyNubCounter -Session $s -Id 0
            Check ((Step-KeyNubCounter -Session $s -Id 0) -eq $before + 1) 'Step-KeyNubCounter returns the new value'
            Check ((Get-KeyNubCounter -Session $s 0) -eq $before + 1) 'and it stays'
            Step-KeyNubCounter -Session $s -Id 1 -WhatIf
            Check ((Get-KeyNubCounter -Session $s -Id 1) -eq 0) '-WhatIf increments nothing'
            Fails { Get-KeyNubCounter -Session $s -Id 7 } $LicdException 'Range' 'a counter the dongle does not have' | Out-Null
            Fails { Step-KeyNubCounter -Session $s -Id 7 } $LicdException 'Range' 'incrementing it' | Out-Null
        }
    } finally {
        Disconnect-KeyNubDongle -Dongle $d
    }
}

function Test-Protect {
    $d = Connect-KeyNubDongle
    try {
        Invoke-KeyNubSession $d {
            param($s)
            $secret = [byte[]](0..99 | ForEach-Object { (3 * $_ + 7) % 256 })
            foreach ($scope in 'Device', 'Developer') {
                $blob = Protect-KeyNubData -Session $s -Scope $scope -Data $secret
                Check ($blob -is [byte[]] -and $blob.Length -gt $secret.Length) "the $scope envelope"
                Check ($blob[0] -eq [int][KeyNub.LicenseDongle.Scope]$scope) "it names the $scope scope"
                Check (Same (Unprotect-KeyNubData -Session $s -Data $blob) $secret) "the $scope round trip"
                $tampered = [byte[]]$blob.Clone()
                $tampered[$tampered.Length - 1] = $tampered[$tampered.Length - 1] -bxor 1
                Fails { Unprotect-KeyNubData -Session $s -Data $tampered } $LicdException 'TagMismatch' 'a tampered envelope' | Out-Null
            }
            $sealed = Protect-KeyNubData -Session $s -Scope Developer -Data 'the data'
            Check ((Unprotect-KeyNubData -Session $s $sealed -AsString) -eq 'the data') 'a string round-trips'
            $none = Unprotect-KeyNubData -Session $s -Data (Protect-KeyNubData -Session $s -Scope Device -Data ([byte[]]@()))
            Check ($none -is [byte[]] -and $none.Length -eq 0) 'empty data'
        }
    } finally {
        Disconnect-KeyNubDongle -Dongle $d
    }
}

function Test-Rotation {
    $d = Connect-KeyNubDongle
    try {
        Invoke-KeyNubSession $d {
            param($s)
            Fails { Set-KeyNubWriteKey -Session $s -Key $ReplacementKey -Confirm:$false } ([KeyNub.LicenseDongle.WriteAuthorizationRequiredException]) 'AuthRequired' 'rotation needs the write role' | Out-Null
            Grant-KeyNubWriteAccess -Session $s -Key $FactoryKey
            Set-KeyNubWriteKey -Session $s -Key $ReplacementKey -WhatIf
            Check (-not (Get-KeyNubDongleInfo -Dongle $d).WriteAuthRotated) '-WhatIf rotates nothing'
            Set-KeyNubWriteKey -Session $s -Key $ReplacementKey -Confirm:$false
            Write-KeyNubRecord -Session $s -Name lic -Value 'still-writable'
        }
        Check ((Get-KeyNubDongleInfo -Dongle $d).WriteAuthRotated) 'the rotation flag is set'
        Invoke-KeyNubSession $d {
            param($s)
            Fails { Grant-KeyNubWriteAccess -Session $s -Key $FactoryKey } ([KeyNub.LicenseDongle.NotGenuineException]) 'NotGenuine' 'the factory key no longer elevates' | Out-Null
            Grant-KeyNubWriteAccess -Session $s -Key $ReplacementKey
            Write-KeyNubRecord -Session $s -Name lic -Value 'new-key-writes'
            Check ((Read-KeyNubRecord -Session $s -Name lic -AsString) -eq 'new-key-writes') 'the new key writes'
        }
    } finally {
        Disconnect-KeyNubDongle -Dongle $d
    }
}

function Test-SessionLifetime {
    $d = Connect-KeyNubDongle
    $value = Invoke-KeyNubSession $d { param($s) $script:Kept = $s; 42 }
    Check ($value -eq 42) 'Invoke-KeyNubSession returns what the block returns'
    Check $script:Kept.IsClosed 'and closes the session'
    $caught = $null
    try {
        Invoke-KeyNubSession $d { param($s) $script:Kept = $s; throw 'inside' }
    } catch {
        $caught = $_
    }
    Check ($null -ne $caught -and $caught.Exception.Message -eq 'inside') 'an error inside the block propagates'
    Check $script:Kept.IsClosed 'and the session is closed after it'

    $s = Open-KeyNubSession -Dongle $d
    Fails { Open-KeyNubSession -Dongle $d } ([System.Exception]) '' 'a second session on the same dongle' | Out-Null
    Close-KeyNubSession -Session $s
    Close-KeyNubSession -Session $s
    Check $s.IsClosed 'Close-KeyNubSession, twice'
    $orphan = $d | Open-KeyNubSession
    Disconnect-KeyNubDongle -Dongle $d
    Check $orphan.IsClosed 'a session ends with its dongle'
    Disconnect-KeyNubDongle -Dongle $d
}

function Test-TrustRoot {
    $d = Connect-KeyNubDongle
    try {
        Fails { Set-KeyNubTrustRoot -Certificate ([byte[]](0x02, 0x01, 0x00)) } ([KeyNub.LicenseDongle.CertificateInvalidException]) 'CertificateInvalid' 'a malformed root' | Out-Null
        $root = [byte[]]::new(132)
        $root[0] = 0x30; $root[1] = 0x82; $root[2] = 0x01; $root[3] = 0x00
        for ($k = 4; $k -lt $root.Length; $k++) { $root[$k] = 0xAB }
        Set-KeyNubTrustRoot -Certificate $root
        $err = Fails { Confirm-KeyNubDongle -Dongle $d } ([KeyNub.LicenseDongle.CertificateInvalidException]) 'CertificateInvalid' 'a chain to another root'
        Check ($err.CategoryInfo.Category -eq 'SecurityError') 'a failed proof is SecurityError'
        Check ((Test-KeyNubDongle -Dongle $d) -eq $false) 'Test-KeyNubDongle fails closed'
        for ($k = 4; $k -lt $root.Length; $k++) { $root[$k] = 0x01 }
        Set-KeyNubTrustRoot -Certificate $root
        Check ((Test-KeyNubDongle -Dongle $d) -eq $true) 'the matching root'
    } finally {
        Disconnect-KeyNubDongle -Dongle $d
    }
}

# --- run ---------------------------------------------------------------------

$root = Find-SdkRoot
$script:Work = Join-Path ([System.IO.Path]::GetTempPath()) "keynub-standin-powershell-$PID"
New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
try {
    if (-not $ModulePath) {
        $ModulePath = Build-Module -Root $root -Directory $script:Work
    }
    $env:KEYNUB_LICDONGLE_LIBRARY = Build-StandIn -Root $root -Directory (Join-Path $script:Work 'standin')
    Import-Module (Join-Path $ModulePath 'KeyNub.LicenseDongle.psd1') -Force
    $LicdException = [KeyNub.LicenseDongle.LicenseDongleException]

    Test-Discovery
    Test-InfoAndGenuine
    Test-RecordStore
    Test-CounterValue
    Test-Protect
    Test-Rotation
    Test-SessionLifetime
    Test-TrustRoot

    # The module can be removed and imported again in the same process.
    Remove-Module KeyNub.LicenseDongle
    Import-Module (Join-Path $ModulePath 'KeyNub.LicenseDongle.psd1')
    Check ((Get-KeyNubLibraryVersion) -eq [version]'9.8.7') 'the module works after it is imported again'
    Check (@(Get-KeyNubDongle).Count -eq 1) 'with a fresh context'

    $exported = @((Get-Module KeyNub.LicenseDongle).ExportedFunctions.Keys)
    Check ($exported.Count -eq 22) "22 commands exported, found $($exported.Count)"

    "KeyNub.LicenseDongle: every call passed against the ABI stand-in (PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition))"
} finally {
    Remove-Module KeyNub.LicenseDongle -ErrorAction SilentlyContinue
    Remove-Item Env:KEYNUB_LICDONGLE_LIBRARY -ErrorAction SilentlyContinue
    # The loaded stand-in cannot be deleted while this process holds it.
    Remove-Item -Recurse -Force -LiteralPath $script:Work -ErrorAction SilentlyContinue
}
