$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Keeps the executable for this machine's architecture; Chocolatey creates the
# licd-tool shim for it.
if ((Get-OSArchitectureWidth 64) -and $env:ChocolateyForceX86 -ne 'true') {
    $unused = 'x86'
} else {
    $unused = 'x64'
}
Remove-Item -Path (Join-Path $toolsDir "$unused\licd-tool.exe") -Force
