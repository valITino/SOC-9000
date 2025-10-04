<#
.SYNOPSIS
  Build a Windows 11 ISO with Autounattend.xml and no UEFI prompt (UEFI+BIOS).

.NOTES
  - Requires Windows ADK (Deployment Tools) for oscdimg.exe.
  - Run **elevated** (needed for Mount-DiskImage).
#>

[CmdletBinding()]
param(
  [string]$IsoDir        = 'E:\SOC-9000-Install\isos',
  [string]$IsoName       = 'Win11_24H2_EnglishInternational_x64.iso',
  [string]$Autounattend  = "$PSScriptRoot\..\packer\windows-victim\answer\Autounattend.xml",
  [string]$OutName       = 'Win11_24H2_noprompt_autounattend_uefi.iso',
  [string]$Label         = 'WIN11_AUTO'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal $id
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please run this script from an elevated PowerShell session (Run as Administrator)."
  }
}

function Get-OscdimgPath {
  $candidates = @(
    'C:\Program Files (x86)\Windows Kits\11\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe',
    'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  throw "oscdimg.exe not found. Install Windows ADK + Deployment Tools."
}

function Mount-IsoGetDriveLetter([string]$isoPath) {
  $img = Mount-DiskImage -ImagePath $isoPath -PassThru
  # Wait for the Volume to appear and get a drive letter
  $timeout = [DateTime]::UtcNow.AddSeconds(15)
  $vol = $null
  while ([DateTime]::UtcNow -lt $timeout) {
    try {
      $vol = ($img | Get-Volume)
      if ($vol -and $vol.DriveLetter) { break }
    } catch { Start-Sleep -Milliseconds 300 }
    Start-Sleep -Milliseconds 200
  }
  if (-not ($vol -and $vol.DriveLetter)) {
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
    throw "Failed to mount ISO or obtain a drive letter for: $isoPath"
  }
  return "$($vol.DriveLetter):"
}

function Update-PackerConfigWithHash {
  param(
    [string]$Hash,
    [string]$PackerConfigPath = "$PSScriptRoot\..\packer\windows-victim\windows.pkr.hcl"
  )
  
  if (Test-Path $PackerConfigPath) {
    $content = Get-Content -Path $PackerConfigPath -Raw
    # Update the variable default instead of the source block
    $newContent = $content -replace 'iso_checksum\s*\{\s*type\s*=\s*string\s*default\s*=\s*"sha256:[a-fA-F0-9]+"\s*\}', "iso_checksum = { type = string default = `"sha256:$Hash`" }"
    Set-Content -Path $PackerConfigPath -Value $newContent -Force
    Write-Host "Updated Packer configuration with new hash: sha256:$Hash"
  } else {
    Write-Warning "Packer configuration file not found at: $PackerConfigPath"
  }
}
function Save-ChecksumToFile {
  param(
    [string]$Hash,
    [string]$ChecksumDir = "$PSScriptRoot\..\packer\windows-victim\Custom ISO",
    [string]$FileName = "checksum.txt"
  )
  
  if (-not (Test-Path $ChecksumDir)) {
    New-Item -ItemType Directory -Path $ChecksumDir -Force | Out-Null
  }
  
  $checksumPath = Join-Path $ChecksumDir $FileName
  Set-Content -Path $checksumPath -Value "SHA256($OutName)= $Hash"
  Write-Host "Checksum saved to: $checksumPath"
}

Assert-Admin

# Resolve input paths
$isoPath = Join-Path $IsoDir $IsoName
if (!(Test-Path $isoPath)) { throw "Windows ISO not found: $isoPath" }
if (!(Test-Path $Autounattend)) { Write-Warning "Autounattend not found: $Autounattend (continuing without it)"; }

$oscdimg = Get-OscdimgPath

# Working dir
$work = Join-Path ([IO.Path]::GetTempPath()) ("winiso-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null

$destIso = Join-Path $IsoDir $OutName
if (Test-Path $destIso) { Remove-Item $destIso -Force }

Write-Host "Mounting ISO: $(Split-Path $isoPath -Leaf)"
$srcDrive = Mount-IsoGetDriveLetter -isoPath $isoPath

try {
  Write-Host "Copying ISO contents to working directory..."
  # Mirror with robocopy; retry fast
  & robocopy "$srcDrive\" "$work\" /MIR /R:1 /W:1 | Out-Null

  Write-Host "Clearing read-only/system/hidden attributes..."
  & attrib -r -s -h "$work\*" /S /D | Out-Null

  if (Test-Path $Autounattend) {
    Write-Host "Placing Autounattend.xml at ISO root..."
    Copy-Item -Path $Autounattend -Destination (Join-Path $work 'Autounattend.xml') -Force
  }

  # Boot images (BIOS + UEFI no-prompt)
  $biosBoot     = Join-Path $work 'boot\etfsboot.com'
  $efiNoPrompt  = Join-Path $work 'efi\microsoft\boot\efisys_noprompt.bin'
  if (!(Test-Path $biosBoot)) { throw "Missing BIOS boot image: $biosBoot" }

  if (!(Test-Path $efiNoPrompt)) {
    $efiNoPrompt = Join-Path $work 'efi\microsoft\boot\efisys.bin'
    if (!(Test-Path $efiNoPrompt)) { throw "Missing UEFI boot image: efi\microsoft\boot\efisys[_noprompt].bin" }
    else { Write-Warning "efisys_noprompt.bin not found - using efisys.bin (a UEFI menu may appear)." }
  }

  # oscdimg label must be <=32 ASCII chars
  $Label = ($Label.Substring(0, [Math]::Min(32, $Label.Length))).ToUpperInvariant()

  # Build the -bootdata argument with proper quoting for file paths
  $bootData = "2#p0,e,b`"$biosBoot`"#pEF,e,b`"$efiNoPrompt`""

  Write-Host "Rebuilding ISO ($OutName) with dual-boot and no UEFI prompt..."
  $args = @(
    '-m','-o','-u2','-udfver102',
    "-l$Label",
    "-bootdata:$bootData",
    $work,
    $destIso
  )

  $p = Start-Process -FilePath $oscdimg -ArgumentList $args -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "oscdimg failed with exit code $($p.ExitCode)" }

  if (!(Test-Path $destIso) -or ((Get-Item $destIso).Length -lt 500MB)) {
    throw "Output ISO missing or unexpectedly small: $destIso"
  }

  Write-Host "ISO ready: $destIso"
  
  # Calculate SHA256 hash
  Write-Host "Calculating SHA256 hash of the new ISO..."
  $hash = (Get-FileHash -Path $destIso -Algorithm SHA256).Hash
  Write-Host "SHA256 Hash: $hash"
  
  # Update Packer configuration
  Update-PackerConfigWithHash -Hash $hash
  
  # Save checksum to file
  Save-ChecksumToFile -Hash $hash
}
finally {
  Write-Host "Dismounting original ISO..."
  Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
  if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

return $hash