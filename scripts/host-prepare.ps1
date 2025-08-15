[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal $id
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation required. Relaunching as Administrator..."
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null
    exit 0
  }
}

function Find-Exe {
  param([string[]]$Candidates)
  foreach ($p in $Candidates) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

Ensure-Admin

$logDir = Join-Path $PSScriptRoot "..\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

try { Stop-Transcript | Out-Null } catch {}
$ts  = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "host-prepare-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

try {
  $gen = Join-Path $PSScriptRoot 'generate-vmnet-profile.ps1'
  $out = Join-Path $PSScriptRoot '..\artifacts\network\vmnet-profile.txt'
  if (-not (Test-Path $gen)) { throw "Missing $gen" }

  & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $out
  if ($LASTEXITCODE -ne 0) { throw "generate-vmnet-profile.ps1 exited with code $LASTEXITCODE" }

  $vnetlib = Find-Exe @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
    "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
  )
  if (-not $vnetlib) { throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run." }

  & $vnetlib -- stop dhcp
  & $vnetlib -- stop nat
  & $vnetlib -- import $out
  if ($LASTEXITCODE -ne 0) { throw "vnetlib64 import failed: $LASTEXITCODE" }
  & $vnetlib -- start dhcp
  & $vnetlib -- start nat

  Write-Host "Host network prepared via import."
  Stop-Transcript | Out-Null
  exit 0
}
catch {
  Write-Error ("Host preparation FAILED: {0}" -f $_.Exception.Message)
  Write-Host  ("See transcript: {0}" -f $log)
  Stop-Transcript | Out-Null
  exit 1
}