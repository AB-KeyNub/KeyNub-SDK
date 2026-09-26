<#
.SYNOPSIS
    Every public function of KeyNubLicDongle.bas, run in Excel against a stand-in
    for the flat C API.

.DESCRIPTION
    Compiles bindings/flat/licd_flat.c over bindings/julia/test/stub/licd_stub.c
    (one imaginary dongle held in memory) as keynub_licdongle_flat.dll with a C
    compiler from the path (cl, gcc, clang or zig cc) - built for the bitness of
    Excel - then imports KeyNubLicDongle.bas and StandinTest.bas into a new
    workbook in a hidden Excel, runs StandinRun and closes the workbook without
    saving. Exit code 0 when every check passed.

    Excel must allow access to the VBA project object model: File > Options >
    Trust Center > Trust Center Settings > Macro Settings > "Trust access to the
    VBA project object model".

        powershell -ExecutionPolicy Bypass -File bindings/vba/tests/run_standin_test.ps1
#>
param([string] $SdkRoot)

$ErrorActionPreference = 'Stop'
if (-not $SdkRoot) { $SdkRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }

$include = Join-Path $SdkRoot 'core\include'
if (-not (Test-Path (Join-Path $include 'licdongle.h'))) { $include = Join-Path $SdkRoot 'include' }
$flat = Join-Path $SdkRoot 'bindings\flat'
$sources = @((Join-Path $flat 'licd_flat.c'), (Join-Path $SdkRoot 'bindings\julia\test\stub\licd_stub.c'))

$work = Join-Path ([IO.Path]::GetTempPath()) ('keynub-vba-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$dll = Join-Path $work 'keynub_licdongle_flat.dll'

# --- the stand-in ---------------------------------------------------------------
$gcc = @('-shared', '-O1', '-DLICDF_BUILD_SHARED', "-I$include", "-I$flat", '-o', $dll) + $sources
$cl = @('/nologo', '/LD', '/O1', '/DLICDF_BUILD_SHARED', "/I$include", "/I$flat", "/Fe:$dll") + $sources
$compilers = @(@('cl', $cl), @('gcc', $gcc), @('clang', $gcc), @('zig', (@('cc') + $gcc)))
Push-Location $work
try {
    foreach ($c in $compilers) {
        if (-not (Get-Command $c[0] -ErrorAction SilentlyContinue)) { continue }
        $ErrorActionPreference = 'Continue'
        & $c[0] @($c[1]) *> $null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dll)) { break }
    }
} finally {
    Pop-Location
}
if (-not (Test-Path $dll)) {
    throw 'the flat stand-in could not be compiled: no C compiler (cl, gcc, clang, zig cc) on the path'
}

# --- the modules, copied with CRLF line endings, as the VBA editor exports them ---
$modules = @((Join-Path $SdkRoot 'bindings\vba\KeyNubLicDongle.bas'), (Join-Path $PSScriptRoot 'StandinTest.bas'))
$staged = foreach ($m in $modules) {
    $text = [IO.File]::ReadAllText($m) -replace "`r`n", "`n" -replace "`n", "`r`n"
    $target = Join-Path $work (Split-Path $m -Leaf)
    [IO.File]::WriteAllText($target, $text, [Text.Encoding]::ASCII)
    $target
}

# --- Excel ------------------------------------------------------------------------
$result = ''
$excel = New-Object -ComObject Excel.Application
try {
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $book = $excel.Workbooks.Add()
    # Without that setting the property reads as nothing (or raises, depending on
    # the host), so test for both.
    $components = $null
    try { $components = $book.VBProject.VBComponents } catch { }
    if ($null -eq $components) {
        throw ('Excel refuses access to the VBA project object model; enable "Trust access to the VBA ' +
               'project object model" in the Trust Center macro settings and run again')
    }
    foreach ($s in $staged) { $null = $components.Import($s) }
    $result = [string] $excel.Run("'" + $book.Name + "'!StandinTest.StandinRun", $dll)
    $book.Close($false)
} finally {
    $excel.Quit()
    [void] [Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

$result -split "`n" | ForEach-Object { Write-Output $_ }
if ($result -match 'every call passed against the ABI stand-in') { exit 0 }
exit 1
