# KeyNub License Dongle for PowerShell: commands over the KeyNub.LicenseDongle
# .NET assembly (lib/), which calls the native library for the platform
# (runtimes/<platform>/native/).

Set-StrictMode -Version 3.0

$script:Context = $null
$script:LibraryPath = $null

$ExecutionContext.SessionState.Module.OnRemove = {
    if ($null -ne $script:Context) {
        $script:Context.Dispose()
        $script:Context = $null
    }
}

# --- the native library ------------------------------------------------------

function Get-NativeLibraryCandidate {
    # The library this process should load: KEYNUB_LICDONGLE_LIBRARY, else the
    # one inside the module for this platform and architecture.
    if ($env:KEYNUB_LICDONGLE_LIBRARY) {
        return $env:KEYNUB_LICDONGLE_LIBRARY
    }
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        $arch = if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $env:PROCESSOR_ARCHITECTURE
        } else {
            [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        }
        $rid = switch ($arch) {
            { $_ -in 'AMD64', 'X64' } { 'win-x64' }
            { $_ -in 'x86', 'X86' } { 'win-x86' }
            { $_ -in 'ARM64', 'Arm64' } { 'win-arm64' }
            default { "win-$arch" }
        }
        $file = 'keynub_licdongle.dll'
    } elseif ($IsMacOS) {
        $rid = 'osx'
        $file = 'libkeynub_licdongle.dylib'
    } else {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        $rid = if ($arch -eq 'Arm64') { 'linux-arm64' } else { 'linux-x64' }
        $file = 'libkeynub_licdongle.so'
    }
    Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot 'runtimes') $rid) 'native') $file
}

function Initialize-NativeLibrary {
    # Loads the native library once per process, before the assembly's first
    # call into it. Windows PowerShell binds the assembly's imports to a library
    # already loaded under the name keynub_licdongle.dll; PowerShell 7 routes
    # them to the file through a resolver.
    param([Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet)

    if ($null -ne $script:LibraryPath) {
        return
    }
    $path = Get-NativeLibraryCandidate
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
            [System.IO.FileNotFoundException]::new("The KeyNub native library was not found at '$path'.", $path),
            'KeyNub.LibraryNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $path))
    }
    $path = (Resolve-Path -LiteralPath $path).ProviderPath

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        if ([System.IO.Path]::GetFileName($path) -ne 'keynub_licdongle.dll') {
            $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new("Windows PowerShell loads the KeyNub library only under the file name keynub_licdongle.dll, not '$path'."),
                'KeyNub.LibraryName', [System.Management.Automation.ErrorCategory]::InvalidArgument, $path))
        }
        if (-not ('KeyNub.LicenseDongle.PowerShell.Kernel32' -as [type])) {
            Add-Type -Namespace 'KeyNub.LicenseDongle.PowerShell' -Name 'Kernel32' -MemberDefinition @'
[DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr LoadLibraryW(string path);
'@
        }
        $handle = [KeyNub.LicenseDongle.PowerShell.Kernel32]::LoadLibraryW($path)
        if ($handle -eq [IntPtr]::Zero) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.ComponentModel.Win32Exception]::new($code, "Could not load the KeyNub library '$path' (Windows error $code)."),
                'KeyNub.LibraryLoad', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $path))
        }
    } else {
        if (-not ('KeyNub.LicenseDongle.PowerShell.NativeResolver' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace KeyNub.LicenseDongle.PowerShell
{
    public static class NativeResolver
    {
        private static IntPtr handle;

        // Once per process: the assembly stays loaded when the module is
        // removed and imported again, and takes one resolver only.
        public static void Register(Assembly assembly, string path)
        {
            if (handle != IntPtr.Zero)
            {
                return;
            }
            handle = NativeLibrary.Load(path);
            NativeLibrary.SetDllImportResolver(assembly,
                (name, requester, searchPath) => name == "keynub_licdongle" ? handle : IntPtr.Zero);
        }
    }
}
'@
        }
        try {
            [KeyNub.LicenseDongle.PowerShell.NativeResolver]::Register(
                [KeyNub.LicenseDongle.LicenseDongleContext].Assembly, $path)
        } catch {
            $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.DllNotFoundException]::new("Could not load the KeyNub library '$path': $($_.Exception.InnerException.Message)"),
                'KeyNub.LibraryLoad', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $path))
        }
    }
    $script:LibraryPath = $path
}

# --- errors ------------------------------------------------------------------

function Write-LicdError {
    # Ends the calling command with the error a call into the assembly raised.
    # A LicenseDongleException becomes the error's Exception, so its type,
    # Status and Detail reach the caller (its message carries the detail);
    # anything else is raised again as it came.
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [object]$Target
    )
    $e = $ErrorRecord.Exception
    while ($null -ne $e -and $e -isnot [KeyNub.LicenseDongle.LicenseDongleException]) {
        $e = $e.InnerException
    }
    if ($null -eq $e) {
        $Cmdlet.ThrowTerminatingError($ErrorRecord)
    }
    $category = switch ($e.Status.ToString()) {
        'NoDevice' { 'ObjectNotFound' }
        'NotFound' { 'ObjectNotFound' }
        'NotGenuine' { 'SecurityError' }
        'CertificateInvalid' { 'SecurityError' }
        'AuthRequired' { 'PermissionDenied' }
        'AccessDenied' { 'PermissionDenied' }
        'InvalidArgument' { 'InvalidArgument' }
        'Range' { 'InvalidArgument' }
        'Timeout' { 'OperationTimeout' }
        'Busy' { 'ResourceBusy' }
        'StorageFull' { 'LimitsExceeded' }
        'SessionExpired' { 'InvalidOperation' }
        default { 'NotSpecified' }
    }
    $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new($e,
        "KeyNub.$($e.Status)", [System.Management.Automation.ErrorCategory]::$category, $Target))
}

function ConvertTo-LicdByteArray {
    # A byte array as it is; a string as its UTF-8 bytes.
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [AllowNull()][object]$Value,
        [string]$Name
    )
    if ($null -eq $Value) {
        return , [byte[]]::new(0)
    }
    if ($Value -is [byte[]]) {
        return , $Value
    }
    if ($Value -is [string]) {
        return , [System.Text.Encoding]::UTF8.GetBytes($Value)
    }
    if ($Value -is [System.Array]) {
        return , [byte[]]$Value
    }
    $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
        [System.ArgumentException]::new("$Name must be a byte array or a string.", $Name),
        'KeyNub.InvalidData', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Value))
}

function Get-LicdContext {
    # The one context this module opens per PowerShell session, with the
    # native library loaded.
    param([Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet)
    Initialize-NativeLibrary -Cmdlet $Cmdlet
    if ($null -eq $script:Context) {
        try {
            $script:Context = [KeyNub.LicenseDongle.LicenseDongleContext]::Create()
        } catch {
            Write-LicdError -Cmdlet $Cmdlet -ErrorRecord $_
        }
    }
    $script:Context
}

function Read-KeyFile {
    param([Parameter(Mandatory)][string]$Path)
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    , [System.IO.File]::ReadAllBytes($full)
}

# --- library and context -----------------------------------------------------

function Get-KeyNubLibraryVersion {
    <#
    .SYNOPSIS
    The version of the KeyNub native library in use.
    .DESCRIPTION
    Loads the native library if no command has yet, and returns its version,
    which is the version of the SDK it was built from.
    .OUTPUTS
    System.Version
    .EXAMPLE
    Get-KeyNubLibraryVersion
    #>
    [CmdletBinding()]
    [OutputType([System.Version])]
    param()
    Initialize-NativeLibrary -Cmdlet $PSCmdlet
    try {
        [KeyNub.LicenseDongle.LicenseDongleContext]::LibraryVersion
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
    }
}

function Set-KeyNubTrustRoot {
    <#
    .SYNOPSIS
    Replaces the root certificate that dongle certificates are verified against.
    .DESCRIPTION
    Applications do not need this: the native library embeds the KeyNub
    production root. It exists for dongles provisioned against a different CA,
    and for vendor tooling. It applies to every later verification in this
    PowerShell session.
    .PARAMETER Certificate
    The root certificate, DER-encoded.
    .EXAMPLE
    Set-KeyNubTrustRoot -Certificate ([System.IO.File]::ReadAllBytes("$PWD/root.der"))
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([Parameter(Mandatory)][byte[]]$Certificate)
    $ctx = Get-LicdContext -Cmdlet $PSCmdlet
    if ($PSCmdlet.ShouldProcess('the KeyNub context', 'Replace the trust root')) {
        try {
            $ctx.SetTrustRoot($Certificate)
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

function Get-KeyNubDongle {
    <#
    .SYNOPSIS
    Lists the KeyNub dongles attached to this computer.
    .DESCRIPTION
    Enumerates without opening anything. Each result has Serial, Path (the
    operating system's device path), VendorId and ProductId, and can be piped to
    Connect-KeyNubDongle.
    .OUTPUTS
    KeyNub.LicenseDongle.DeviceInfo
    .EXAMPLE
    Get-KeyNubDongle
    #>
    [CmdletBinding()]
    [OutputType([KeyNub.LicenseDongle.DeviceInfo])]
    param()
    $ctx = Get-LicdContext -Cmdlet $PSCmdlet
    try {
        $ctx.Enumerate()
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
    }
}

function Connect-KeyNubDongle {
    <#
    .SYNOPSIS
    Opens a KeyNub dongle.
    .DESCRIPTION
    Opens the first attached dongle, the one with the given serial, or the one
    at the given device path. Close it with Disconnect-KeyNubDongle; one that is
    not closed is released when PowerShell exits or the module is removed.
    .PARAMETER Serial
    The serial of the dongle to open, as Get-KeyNubDongle shows it.
    .PARAMETER DevicePath
    The device path from Get-KeyNubDongle. Binds from the Path property of
    piped input.
    .OUTPUTS
    KeyNub.LicenseDongle.Dongle
    .EXAMPLE
    $dongle = Connect-KeyNubDongle
    .EXAMPLE
    Get-KeyNubDongle | Select-Object -First 1 | Connect-KeyNubDongle
    #>
    [CmdletBinding(DefaultParameterSetName = 'Serial')]
    [OutputType([KeyNub.LicenseDongle.Dongle])]
    param(
        [Parameter(ParameterSetName = 'Serial', Position = 0)]
        [string]$Serial,
        [Parameter(ParameterSetName = 'Path', Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Path')]
        [string]$DevicePath
    )
    process {
        $ctx = Get-LicdContext -Cmdlet $PSCmdlet
        try {
            if ($PSCmdlet.ParameterSetName -eq 'Path') {
                $ctx.OpenByPath($DevicePath)
            } elseif ($Serial) {
                $ctx.Open($Serial)
            } else {
                # [NullString]: PowerShell would pass $null to a string parameter as "".
                $ctx.Open([NullString]::Value)
            }
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_ -Target $(if ($DevicePath) { $DevicePath } else { $Serial })
        }
    }
}

function Disconnect-KeyNubDongle {
    <#
    .SYNOPSIS
    Closes a dongle opened with Connect-KeyNubDongle.
    .DESCRIPTION
    Ends any session still open on it and releases the dongle for other
    programs. Safe to call more than once.
    .PARAMETER Dongle
    The dongle to close.
    .EXAMPLE
    Disconnect-KeyNubDongle -Dongle $dongle
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, ValueFromPipeline)][KeyNub.LicenseDongle.Dongle]$Dongle)
    process {
        $Dongle.Dispose()
    }
}

function Get-KeyNubDongleInfo {
    <#
    .SYNOPSIS
    The dongle's firmware and protocol versions, storage and status flags.
    .PARAMETER Dongle
    An open dongle.
    .OUTPUTS
    KeyNub.LicenseDongle.DongleInfo
    .EXAMPLE
    (Get-KeyNubDongleInfo -Dongle $dongle).FirmwareVersion
    #>
    [CmdletBinding()]
    [OutputType([KeyNub.LicenseDongle.DongleInfo])]
    param([Parameter(Mandatory, ValueFromPipeline)][KeyNub.LicenseDongle.Dongle]$Dongle)
    process {
        try {
            $Dongle.GetInfo()
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

function Test-KeyNubDongle {
    <#
    .SYNOPSIS
    Whether the dongle is genuine: $true or $false.
    .DESCRIPTION
    Verifies the dongle's certificate chain against the trusted root and runs a
    live challenge-response against the key inside the dongle. Fails closed:
    every failure, a closed dongle included, gives $false. For the serial and
    provisioning date, or the reason for a failure, use Confirm-KeyNubDongle.

    A script that ends on "if (-not (Test-KeyNubDongle ...)) { exit }" is one
    line to delete. Put data the script needs through Protect-KeyNubData, and
    ship only the protected form.
    .PARAMETER Dongle
    An open dongle.
    .OUTPUTS
    System.Boolean
    .EXAMPLE
    Test-KeyNubDongle -Dongle $dongle
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, ValueFromPipeline)][KeyNub.LicenseDongle.Dongle]$Dongle)
    process {
        try {
            $Dongle.VerifyGenuine().IsGenuine
        } catch {
            $false
        }
    }
}

function Confirm-KeyNubDongle {
    <#
    .SYNOPSIS
    Proves that the dongle is genuine, or raises an error.
    .DESCRIPTION
    Verifies the dongle's certificate chain against the trusted root and runs a
    live challenge-response against the key inside the dongle. Returns the
    identity from the verified certificate; a dongle that fails raises a
    terminating error whose exception is a KeyNub.LicenseDongle.NotGenuineException
    or CertificateInvalidException.
    .PARAMETER Dongle
    An open dongle.
    .OUTPUTS
    KeyNub.LicenseDongle.GenuineResult
    .EXAMPLE
    (Confirm-KeyNubDongle -Dongle $dongle).Serial
    #>
    [CmdletBinding()]
    [OutputType([KeyNub.LicenseDongle.GenuineResult])]
    param([Parameter(Mandatory, ValueFromPipeline)][KeyNub.LicenseDongle.Dongle]$Dongle)
    process {
        try {
            $Dongle.VerifyGenuine()
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

# --- sessions ----------------------------------------------------------------

function Open-KeyNubSession {
    <#
    .SYNOPSIS
    Opens the encrypted session that records, counters and data protection need.
    .DESCRIPTION
    Verifies the dongle, then sets up an encrypted, authenticated channel to it
    (P-256 ECDH, HKDF-SHA256, AES-256-GCM). One session per dongle at a time;
    close it with Close-KeyNubSession, or use Invoke-KeyNubSession, which closes
    it on every path.
    .PARAMETER Dongle
    An open dongle.
    .OUTPUTS
    KeyNub.LicenseDongle.Session
    .EXAMPLE
    $session = Open-KeyNubSession -Dongle $dongle
    #>
    [CmdletBinding()]
    [OutputType([KeyNub.LicenseDongle.Session])]
    param([Parameter(Mandatory, ValueFromPipeline)][KeyNub.LicenseDongle.Dongle]$Dongle)
    process {
        try {
            $Dongle.OpenSession()
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

function Close-KeyNubSession {
    <#
    .SYNOPSIS
    Ends a session. Safe to call more than once.
    .PARAMETER Session
    The session to close.
    .EXAMPLE
    Close-KeyNubSession -Session $session
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, ValueFromPipeline)][KeyNub.LicenseDongle.Session]$Session)
    process {
        try {
            $Session.Close()
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

function Invoke-KeyNubSession {
    <#
    .SYNOPSIS
    Runs a script block inside a session and closes the session afterwards.
    .DESCRIPTION
    Opens a session on the dongle, runs the script block with the session as its
    only argument, and closes the session whatever happens, errors included.
    Returns what the script block returns.
    .PARAMETER Dongle
    An open dongle.
    .PARAMETER ScriptBlock
    The commands to run; the session arrives as the first argument.
    .EXAMPLE
    Invoke-KeyNubSession -Dongle $dongle -ScriptBlock { param($s) Get-KeyNubRecord -Session $s }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][KeyNub.LicenseDongle.Dongle]$Dongle,
        [Parameter(Mandatory, Position = 1)][scriptblock]$ScriptBlock
    )
    try {
        $session = $Dongle.OpenSession()
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
    }
    try {
        & $ScriptBlock $session
    } finally {
        $session.Close()
    }
}

function Grant-KeyNubWriteAccess {
    <#
    .SYNOPSIS
    Unlocks writing, erasing and counter increments for the rest of the session.
    .DESCRIPTION
    Elevates the session to the write role with the dongle's write key, a P-256
    private key in PKCS#8 DER. This belongs in your licence-issuing tooling;
    never ship that key with what your users run. A key the dongle does not
    accept raises a NotGenuineException.
    .PARAMETER Session
    An open session.
    .PARAMETER Key
    The write key, DER-encoded.
    .PARAMETER KeyPath
    A file holding the write key, DER-encoded.
    .EXAMPLE
    Grant-KeyNubWriteAccess -Session $session -KeyPath ./write-key.der
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]]$Key,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$KeyPath
    )
    $der = if ($PSCmdlet.ParameterSetName -eq 'Path') { Read-KeyFile -Path $KeyPath } else { $Key }
    try {
        $Session.AuthorizeWrite($der)
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
    }
}

function Set-KeyNubWriteKey {
    <#
    .SYNOPSIS
    Replaces the dongle's write key with one you hold.
    .DESCRIPTION
    Needs the write role, so run Grant-KeyNubWriteAccess with the current key
    first. The session keeps the write role; from the next session on only the
    new key elevates, and the old one no longer works on this dongle. Do this
    once per dongle, when it arrives: the factory key is public.
    .PARAMETER Session
    An open session with the write role.
    .PARAMETER Key
    The new write key, a P-256 private key in PKCS#8 DER.
    .PARAMETER KeyPath
    A file holding the new write key.
    .EXAMPLE
    Set-KeyNubWriteKey -Session $session -KeyPath ./my-write-key.der
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Path')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]]$Key,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$KeyPath
    )
    $der = if ($PSCmdlet.ParameterSetName -eq 'Path') { Read-KeyFile -Path $KeyPath } else { $Key }
    if ($PSCmdlet.ShouldProcess('the dongle', 'Replace the write key')) {
        try {
            $Session.RotateWriteKey($der)
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

# --- records -----------------------------------------------------------------

function Get-KeyNubRecord {
    <#
    .SYNOPSIS
    Lists the records on the dongle, with their sizes in bytes.
    .PARAMETER Session
    An open session.
    .OUTPUTS
    KeyNub.LicenseDongle.RecordInfo
    .EXAMPLE
    Get-KeyNubRecord -Session $session
    #>
    [CmdletBinding()]
    [OutputType([KeyNub.LicenseDongle.RecordInfo])]
    param([Parameter(Mandatory, ValueFromPipeline)][KeyNub.LicenseDongle.Session]$Session)
    process {
        try {
            $Session.ListRecords()
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

function Read-KeyNubRecord {
    <#
    .SYNOPSIS
    Reads a record: its bytes, or with -AsString its UTF-8 text.
    .DESCRIPTION
    A record that does not exist raises a terminating error whose exception is a
    KeyNub.LicenseDongle.RecordNotFoundException.
    .PARAMETER Session
    An open session.
    .PARAMETER Name
    The record name.
    .PARAMETER AsString
    Returns the record decoded as UTF-8 text.
    .OUTPUTS
    System.Byte[], or System.String with -AsString
    .EXAMPLE
    Read-KeyNubRecord -Session $session -Name license -AsString
    #>
    [CmdletBinding()]
    [OutputType([byte[]], [string])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string]$Name,
        [switch]$AsString
    )
    try {
        $data = $Session.ReadRecord($Name, $null, [System.Threading.CancellationToken]::None)
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_ -Target $Name
    }
    if ($AsString) {
        [System.Text.Encoding]::UTF8.GetString($data)
    } else {
        # The comma keeps the array one object on the pipeline.
        , $data
    }
}

function Write-KeyNubRecord {
    <#
    .SYNOPSIS
    Creates or replaces a record.
    .DESCRIPTION
    Needs the write role (Grant-KeyNubWriteAccess). The record is replaced
    atomically.
    .PARAMETER Session
    An open session with the write role.
    .PARAMETER Name
    The record name.
    .PARAMETER Value
    The contents: a byte array, or a string, which is stored as UTF-8.
    .EXAMPLE
    Write-KeyNubRecord -Session $session -Name license -Value 'expires 2027-12-31'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][object]$Value
    )
    $bytes = ConvertTo-LicdByteArray -Cmdlet $PSCmdlet -Value $Value -Name 'Value'
    if ($PSCmdlet.ShouldProcess($Name, 'Write record')) {
        try {
            $Session.WriteRecord($Name, $bytes, $null, [System.Threading.CancellationToken]::None)
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_ -Target $Name
        }
    }
}

function Remove-KeyNubRecord {
    <#
    .SYNOPSIS
    Erases one record.
    .DESCRIPTION
    Needs the write role (Grant-KeyNubWriteAccess). Clear-KeyNubRecord erases
    every record.
    .PARAMETER Session
    An open session with the write role.
    .PARAMETER Name
    The record to erase.
    .EXAMPLE
    Remove-KeyNubRecord -Session $session -Name trial
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string]$Name
    )
    if ($PSCmdlet.ShouldProcess($Name, 'Erase record')) {
        try {
            $Session.EraseRecord($Name)
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_ -Target $Name
        }
    }
}

function Clear-KeyNubRecord {
    <#
    .SYNOPSIS
    Erases every record on the dongle.
    .DESCRIPTION
    Needs the write role (Grant-KeyNubWriteAccess). Asks for confirmation
    unless -Confirm:$false is given.
    .PARAMETER Session
    An open session with the write role.
    .EXAMPLE
    Clear-KeyNubRecord -Session $session -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param([Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session)
    if ($PSCmdlet.ShouldProcess('every record on the dongle', 'Erase')) {
        try {
            $Session.EraseAllRecords()
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
        }
    }
}

# --- counters ----------------------------------------------------------------

function Get-KeyNubCounter {
    <#
    .SYNOPSIS
    Reads a monotonic counter.
    .PARAMETER Session
    An open session.
    .PARAMETER Id
    The counter, from 0 upwards.
    .OUTPUTS
    System.UInt32
    .EXAMPLE
    Get-KeyNubCounter -Session $session -Id 0
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, Position = 0)][byte]$Id
    )
    try {
        $Session.ReadCounter($Id)
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_ -Target $Id
    }
}

function Step-KeyNubCounter {
    <#
    .SYNOPSIS
    Increments a monotonic counter and returns its new value.
    .DESCRIPTION
    Needs the write role (Grant-KeyNubWriteAccess). A counter only ever goes
    up; an increment cannot be undone.
    .PARAMETER Session
    An open session with the write role.
    .PARAMETER Id
    The counter, from 0 upwards.
    .OUTPUTS
    System.UInt32
    .EXAMPLE
    Step-KeyNubCounter -Session $session -Id 0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, Position = 0)][byte]$Id
    )
    if ($PSCmdlet.ShouldProcess("counter $Id", 'Increment')) {
        try {
            $Session.IncrementCounter($Id)
        } catch {
            Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_ -Target $Id
        }
    }
}

# --- data only a dongle can decrypt ------------------------------------------

function Protect-KeyNubData {
    <#
    .SYNOPSIS
    Encrypts data so that only a dongle can decrypt it.
    .DESCRIPTION
    The pair to build a licence check on. Put something the script needs through
    this, such as its configuration, and ship only the protected form; then
    removing the check removes the data. -Scope Developer lets any dongle you
    have issued decrypt the data, so one file serves every customer; -Scope
    Device locks it to the one dongle that encrypted it.
    .PARAMETER Session
    An open session.
    .PARAMETER Scope
    Device or Developer.
    .PARAMETER Data
    The plaintext: a byte array, or a string, which is encrypted as UTF-8.
    .OUTPUTS
    System.Byte[]
    .EXAMPLE
    $sealed = Protect-KeyNubData -Session $session -Scope Developer -Data 'the data'
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Scope]$Scope,
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][object]$Data
    )
    $bytes = ConvertTo-LicdByteArray -Cmdlet $PSCmdlet -Value $Data -Name 'Data'
    try {
        , $Session.AppEncrypt($Scope, $bytes)
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
    }
}

function Unprotect-KeyNubData {
    <#
    .SYNOPSIS
    Decrypts data from Protect-KeyNubData.
    .PARAMETER Session
    An open session.
    .PARAMETER Data
    The protected data.
    .PARAMETER AsString
    Returns the plaintext decoded as UTF-8 text.
    .OUTPUTS
    System.Byte[], or System.String with -AsString
    .EXAMPLE
    Unprotect-KeyNubData -Session $session -Data $sealed -AsString
    #>
    [CmdletBinding()]
    [OutputType([byte[]], [string])]
    param(
        [Parameter(Mandatory)][KeyNub.LicenseDongle.Session]$Session,
        [Parameter(Mandatory, Position = 0)][byte[]]$Data,
        [switch]$AsString
    )
    try {
        $plain = $Session.AppDecrypt($Data)
    } catch {
        Write-LicdError -Cmdlet $PSCmdlet -ErrorRecord $_
    }
    if ($AsString) {
        [System.Text.Encoding]::UTF8.GetString($plain)
    } else {
        , $plain
    }
}
