# SOC-9000 - build-installer.ps1
<##
    Bundles scripts/standalone-installer.ps1 and install-prereqs.ps1 into a single
    SOC-9000-installer.ps1 script. Works on PowerShell 5.1 and PowerShell 7.
    Run from the repository root or provide -Source/-Output paths.
##>

[CmdletBinding()]
param(
    [string]$Source = "scripts/standalone-installer.ps1",
    [string]$Output = "SOC-9000-installer.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve paths (allow relative input)
try {
    $resolvedSource = (Resolve-Path -Path $Source).Path
} catch {
    Write-Error "Source script not found at '$Source'."
    exit 1
}
$resolvedOutput = [System.IO.Path]::GetFullPath($Output)
$scriptDir     = Split-Path -Parent $resolvedSource
$prereqScript  = Join-Path $scriptDir 'install-prereqs.ps1'
if (-not (Test-Path $prereqScript)) {
    Write-Error "Prerequisite script not found at '$prereqScript'."
    exit 1
}

# Inject prerequisite installer into the source script
$installerContent = Get-Content -Path $resolvedSource -Raw
$prereqContent    = Get-Content -Path $prereqScript -Raw
$embeddedSource   = $installerContent.Replace('__INSTALL_PREREQS_EMBEDDED__', $prereqContent)
Set-Content -Path $resolvedOutput -Value $embeddedSource -Encoding UTF8

Write-Host "Installer script created: $(Resolve-Path -Path $resolvedOutput)" -ForegroundColor Green
