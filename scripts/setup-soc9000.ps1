[CmdletBinding()]
param([switch]$ManualNetwork)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Admin {
  $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation required. Relaunching as Administrator..."
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null
    exit 0
  }
}

function Read-DotEnv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @{} }
  $m = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { continue }
    $k,$v = $_ -split '=',2
    if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
  }
  return $m
}

function Require-DriveE {
  if (-not (Test-Path 'E:\')) {
    throw "Drive E:\ was not found. Please attach/create an E: volume, then re-run."
  }
}

function Ensure-Dirs {
  param([string]$InstallRoot,[string]$RepoRoot)
  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot 'isos') | Out-Null
  New-Item -ItemType Directory -Force -Path $RepoRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'artifacts\network') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'logs') | Out-Null
}

function Get-RequiredIsos {
  param([hashtable]$EnvMap,[string]$IsoDir)
  $pairs = @()
  foreach ($key in $EnvMap.Keys) {
    if ($key -like 'ISO_*' -or $key -eq 'NESSUS_DEB') {
      $name = $EnvMap[$key]
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $pairs += [pscustomobject]@{
        Key      = $key
        FileName = $name
        FullPath = (Join-Path $IsoDir $name)
        Exists   = (Test-Path (Join-Path $IsoDir $name))
      }
    }
  }
  return $pairs
}

function Prompt-MissingIsosLoop {
  param([pscustomobject[]]$IsoList, [string]$IsoDir)
  while ($true) {
    $missing = $IsoList | Where-Object { -not $_.Exists }
    if ($missing.Count -eq 0) { return }
    Write-Warning "You need to download the following ISOs/packages before continuing:"
    $missing | ForEach-Object {
      Write-Host ("  - {0}  ->  {1}" -f $_.Key, $_.FileName)
    }
    Write-Host ("Store them here: {0}" -f $IsoDir)
    $ans = Read-Host "[L] re-check or [A] abort?"
    if ($ans -match '^[Aa]') { Write-Host "Aborting as requested."; exit 1 }
    foreach ($x in $IsoList) { $x.Exists = Test-Path $x.FullPath }
  }
}

function Find-Exe {
  param([string[]]$Candidates)
  foreach ($p in $Candidates) { if (Test-Path $p) { return $p } }
  return $null
}

function Import-VMnetProfile {
  $repoRoot = 'E:\SOC-9000'
  $gen = Join-Path $repoRoot 'scripts\generate-vmnet-profile.ps1'
  if (-not (Test-Path $gen)) { throw "Missing $gen" }

  $out = Join-Path $repoRoot 'artifacts\network\vmnet-profile.txt'
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $out
  if ($LASTEXITCODE -ne 0) { throw "generate-vmnet-profile.ps1 failed." }

  if ($ManualNetwork) { throw "Forced manual networking" }

  $vnetlib = Find-Exe @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
    "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
  )
  if (-not $vnetlib) {
    throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run."
  }

  Write-Host "Importing VMnet profile via vnetlib64 ..."
  & $vnetlib -- stop dhcp
  if ($LASTEXITCODE -ne 0) { Write-Warning "stop dhcp returned $LASTEXITCODE" }
  & $vnetlib -- stop nat
  if ($LASTEXITCODE -ne 0) { Write-Warning "stop nat returned $LASTEXITCODE" }

  & $vnetlib -- import $out
  if ($LASTEXITCODE -ne 0) { throw "vnetlib64 import failed ($LASTEXITCODE)." }

  & $vnetlib -- start dhcp
  if ($LASTEXITCODE -ne 0) { Write-Warning "start dhcp returned $LASTEXITCODE" }
  & $vnetlib -- start nat
  if ($LASTEXITCODE -ne 0) { Write-Warning "start nat returned $LASTEXITCODE" }

  Write-Host "VMware networking: OK (import applied)"
}

# ----------------- main flow -----------------
Ensure-Admin
Require-DriveE

$InstallRoot = 'E:\SOC-9000-Install'
$RepoRoot    = 'E:\SOC-9000'
$IsoDir      = Join-Path $InstallRoot 'isos'

Ensure-Dirs -InstallRoot $InstallRoot -RepoRoot $RepoRoot

$envPath = Join-Path $RepoRoot '.env'
if (-not (Test-Path $envPath)) {
  $envExample = Join-Path $RepoRoot '.env.example'
  if (Test-Path $envExample) {
    Copy-Item $envExample $envPath -Force
    Write-Host "No .env found; seeded it from .env.example."
  }
}

$envMap = Read-DotEnv $envPath
if (-not $envMap.ContainsKey('ISO_DIR')) { $envMap['ISO_DIR'] = $IsoDir }

$isoList = Get-RequiredIsos -EnvMap $envMap -IsoDir $envMap['ISO_DIR']
if ($isoList.Count -gt 0) {
  Prompt-MissingIsosLoop -IsoList $isoList -IsoDir $envMap['ISO_DIR']
} else {
  Write-Host "No required ISO keys were found in .env - skipping ISO check."
}

try {
  Import-VMnetProfile
}
catch {
  Write-Warning ("Automatic network import failed: {0}" -f $_.Exception.Message)
  Write-Host "Please configure the VMnets manually in the Virtual Network Editor, then close it to continue."
  $vmnetcfg = Find-Exe @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfg.exe",
    "C:\Program Files\VMware\VMware Workstation\vmnetcfg.exe"
  )
  if ($vmnetcfg) {
    Start-Process -FilePath $vmnetcfg -Wait
  } else {
    Write-Warning "vmnetcfg.exe was not found. Open VMware Workstation -> Edit -> Virtual Network Editor, configure, then come back."
    Read-Host "Press ENTER to continue after you have configured the networks"
  }
}

function Run-IfExists { param([string]$ScriptPath,[string]$FriendlyName)
if (Test-Path $ScriptPath) {
  Write-Host ("Running {0} ..." -f $FriendlyName)
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Verbose
  if ($LASTEXITCODE -ne 0) { throw ("{0} exited with code {1}" -f $FriendlyName,$LASTEXITCODE) }
  Write-Host ("{0}: OK" -f $FriendlyName)
}
}

try {
  Run-IfExists (Join-Path $RepoRoot 'scripts\wsl-prepare.ps1')       'wsl-prepare.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\wsl-bootstrap.ps1')     'wsl-bootstrap.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\host-prepare.ps1')      'host-prepare.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\verify-networking.ps1') 'verify-networking.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\lab-up.ps1')            'lab-up.ps1'
}
catch {
  Write-Error ("A follow-up step failed: {0}" -f $_.Exception.Message)
  Write-Host "Fix the issue above and re-run this script. Nothing destructive was done."
  exit 1
}

Write-Host ""
Write-Host 'All requested steps completed.'
