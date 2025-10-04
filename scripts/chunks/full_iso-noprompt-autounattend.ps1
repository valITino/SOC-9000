<#
.SYNOPSIS
    Creates a Windows 11 ISO with embedded autounattend.xml for unattended installation.

.DESCRIPTION
    Mounts a source Windows ISO, injects an autounattend.xml file into multiple locations
    including the boot.wim WinPE environment, and rebuilds a bootable ISO with no-prompt UEFI boot.

.PARAMETER SrcIso
    Path to the source Windows 11 ISO file.

.PARAMETER AnswerFile
    Path to the autounattend.xml file to inject.

.PARAMETER OutIso
    Path where the modified ISO will be created.

.PARAMETER WorkDir
    Temporary working directory for extracting and modifying ISO contents.

.PARAMETER IsoLabel
    Volume label for the output ISO (default: WIN11_24H2_NOPROMPT).

.PARAMETER OscdimgExe
    Path to oscdimg.exe. If not provided, searches common Windows ADK locations.

.EXAMPLE
    .\full_iso-noprompt-autounattend.ps1 -SrcIso "E:\isos\win11.iso" -AnswerFile ".\autounattend.xml" -OutIso "E:\isos\win11_auto.iso"

.NOTES
    Requires:
    - Administrator privileges
    - Windows ADK (oscdimg.exe)
    - DISM (built-in to Windows)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SrcIso,

    [Parameter(Mandatory=$true)]
    [string]$AnswerFile,

    [Parameter(Mandatory=$false)]
    [string]$OutIso,

    [Parameter(Mandatory=$false)]
    [string]$WorkDir = (Join-Path $env:TEMP 'Win-NoPrompt-src'),

    [Parameter(Mandatory=$false)]
    [string]$IsoLabel = 'WIN11_24H2_NOPROMPT',

    [Parameter(Mandatory=$false)]
    [string]$OscdimgExe
)

# ============================================================
# Configuration and Validation
# ============================================================

# Load .env file if available for default values
$envPath = Join-Path $PSScriptRoot '..\..\..\.env'
if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            Set-Variable -Name $key -Value $value -Scope Script -ErrorAction SilentlyContinue
        }
    }
}

# Set default SrcIso if not provided
if (-not $SrcIso) {
    $isoDir = if ($env:ISO_DIR) { $env:ISO_DIR } else { 'E:\SOC-9000\isos' }
    $SrcIso = Join-Path $isoDir 'Win11_24H2_noprompt_autounattend_uefi.iso'
}

# Set default OutIso if not provided
if (-not $OutIso) {
    $OutIso = $SrcIso  # Overwrite source ISO
}

# Find oscdimg.exe if not provided
if (-not $OscdimgExe) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    $OscdimgExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $OscdimgExe) {
        throw "oscdimg.exe not found. Install Windows ADK: https://go.microsoft.com/fwlink/?linkid=2271337"
    }
}

# Validate required paths
if (-not (Test-Path -LiteralPath $AnswerFile)) {
    throw "Answer file not found: $AnswerFile"
}

if (-not (Test-Path -LiteralPath $SrcIso)) {
    throw "Source ISO not found: $SrcIso"
}

if (-not (Test-Path -LiteralPath $OscdimgExe)) {
    throw "oscdimg.exe not found at: $OscdimgExe"
}

# ============================================================
# Administrator Privilege Check
# ============================================================

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this script in an elevated PowerShell (Run as Administrator)."
}

Write-Host "Starting Windows ISO modification process..." -ForegroundColor Cyan
Write-Host "  Source ISO:   $SrcIso" -ForegroundColor Gray
Write-Host "  Answer file:  $AnswerFile" -ForegroundColor Gray
Write-Host "  Output ISO:   $OutIso" -ForegroundColor Gray
Write-Host "  Work dir:     $WorkDir" -ForegroundColor Gray
Write-Host ""

# ============================================================
# Prepare Working Directory
# ============================================================

New-Item -Force -ItemType Directory -Path $WorkDir | Out-Null

# ============================================================
# Extract ISO Contents
# ============================================================

Write-Host "Mounting source ISO..." -ForegroundColor Yellow
$img = Mount-DiskImage -ImagePath $SrcIso -PassThru
$vol = ($img | Get-Volume).DriveLetter + ':'

Write-Host "Extracting ISO contents to working directory..." -ForegroundColor Yellow
robocopy "$vol\" "$WorkDir\" /MIR /NJH /NJS /NDL /NC /NS | Out-Null
Dismount-DiskImage -ImagePath $SrcIso | Out-Null

# IMPORTANT: remove read-only/system/hidden attributes copied from ISO
Write-Host "Removing read-only attributes..." -ForegroundColor Yellow
attrib -r -s -h (Join-Path $WorkDir '*') /s /d

# ============================================================
# Inject Answer Files
# ============================================================

Write-Host "Injecting answer files into ISO..." -ForegroundColor Yellow
# Place answer file on media (root + sources)
Copy-Item -Force $AnswerFile (Join-Path $WorkDir 'autounattend.xml')
Copy-Item -Force $AnswerFile (Join-Path $WorkDir 'sources\autounattend.xml')
Copy-Item -Force $AnswerFile (Join-Path $WorkDir 'sources\unattend.xml')

# ============================================================
# Modify boot.wim
# ============================================================

Write-Host "Modifying boot.wim to inject answer file into WinPE..." -ForegroundColor Yellow

# Clean up any stale mount and prep mount/scratch dirs
& dism /English /Cleanup-Mountpoints | Out-Null
$mountDir  = Join-Path $WorkDir 'mount'
$scratch   = Join-Path $WorkDir 'scratch'
New-Item -Force -ItemType Directory -Path $mountDir,$scratch | Out-Null

# Mount boot.wim (index 2 = Windows Setup) READ-WRITE
Write-Host "  Mounting boot.wim index 2..." -ForegroundColor Gray
& dism /English /Mount-Image /ImageFile:"$WorkDir\sources\boot.wim" /Index:2 /MountDir:"$mountDir" /ScratchDir:"$scratch" | Out-Null

try {
  # Put answer file inside WinPE so it is X:\autounattend.xml
  Copy-Item -Force $AnswerFile (Join-Path $mountDir 'autounattend.xml')

  # Optional: tiny log marker to prove WinPE started
  $startnet = Join-Path $mountDir 'Windows\System32\startnet.cmd'
  Set-Content -Encoding ASCII -Path $startnet -Value "@echo off`r`nwpeinit`r`necho Started > X:\pe-started.log"

  # Force WinPE to launch Setup with our answer file immediately
  $winpeshl = Join-Path $mountDir 'Windows\System32\winpeshl.ini'
  $ini = @'
[LaunchApps]
%SYSTEMDRIVE%\setup.exe,/unattend:%SYSTEMDRIVE%\autounattend.xml
'@
  Set-Content -Encoding ASCII -Path $winpeshl -Value $ini

  Write-Host "  Committing changes to boot.wim..." -ForegroundColor Gray
}
catch {
  # If anything above failed, discard changes
  Write-Host "  Error occurred, discarding changes..." -ForegroundColor Red
  & dism /English /Unmount-Image /MountDir:"$mountDir" /Discard | Out-Null
  throw
}

# Commit and unmount
& dism /English /Unmount-Image /MountDir:"$mountDir" /Commit | Out-Null
Remove-Item -Recurse -Force $mountDir,$scratch

# ============================================================
# Rebuild Bootable ISO
# ============================================================

Write-Host "Rebuilding bootable ISO..." -ForegroundColor Yellow

# Rebuild ISO with **no-prompt** UEFI boot image
$efiBoot  = Join-Path $WorkDir 'efi\microsoft\boot\efisys_noprompt.bin'
$biosBoot = Join-Path $WorkDir 'boot\etfsboot.com'

& "$OscdimgExe" -m -o -u2 -udfver102 -l$IsoLabel `
  -bootdata:2#p0,e,b"$biosBoot"#pEF,e,b"$efiBoot" `
  "$WorkDir" "$OutIso"

if ($LASTEXITCODE -ne 0) {
    throw "oscdimg.exe failed with exit code $LASTEXITCODE"
}

# ============================================================
# Completion
# ============================================================

Write-Host ""
Write-Host "ISO creation complete!" -ForegroundColor Green
Write-Host "  Output: $OutIso" -ForegroundColor Cyan

# Calculate and display checksum
Write-Host ""
Write-Host "Calculating SHA256 checksum..." -ForegroundColor Yellow
$hash = Get-FileHash -Path $OutIso -Algorithm SHA256
Write-Host "  SHA256: $($hash.Hash)" -ForegroundColor Gray

Write-Host ""
Write-Host "Done!" -ForegroundColor Green