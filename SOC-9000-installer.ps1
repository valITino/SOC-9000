[CmdletBinding()]
param(
  [switch]$SkipNetworking,
  [switch]$SkipVerify
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Admin {
  $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null
    exit 0
  }
}

function Read-DotEnv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @{} }
  $map = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($v -ne $null) { $map[$k.Trim()] = $v.Trim() }
  }
  $map
}

Ensure-Admin

$root  = Split-Path -Parent $PSCommandPath
$logs  = Join-Path $root "logs"
$isos  = Join-Path $root "isos"
$art   = Join-Path $root "artifacts"
$tempd = Join-Path $root "temp"
New-Item -ItemType Directory -Force -Path $logs,$isos,$art,$tempd | Out-Null

try { Stop-Transcript | Out-Transcript } catch {}
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logs "installer-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# Unblock repo (safe no-op if ADS missing)
Get-ChildItem -Recurse -File $root | ForEach-Object {
  try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {}
}

# .env hydration
$envPath = Join-Path $root ".env"
$envExample = Join-Path $root ".env.example"
if (-not (Test-Path $envPath) -and (Test-Path $envExample)) {
  Copy-Item $envExample $envPath -Force
}
$envMap = Read-DotEnv -Path $envPath
$envMap["LAB_ROOT"]  = $envMap["LAB_ROOT"]  ?? $root
$envMap["REPO_ROOT"] = $envMap["REPO_ROOT"] ?? $root
$envMap["ISO_DIR"]   = $envMap["ISO_DIR"]   ?? $isos
$lines = $envMap.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
Set-Content -Path $envPath -Value $lines -Encoding UTF8

if (-not $SkipNetworking) {
  $cfg = Join-Path $root "scripts\configure-vmnet.ps1"
  if (Test-Path $cfg){
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $cfg -Verbose
    if ($LASTEXITCODE -ne 0) { throw "configure-vmnet.ps1 failed. See $log for details." }
  } else {
    throw "scripts\configure-vmnet.ps1 missing."
  }
}

if (-not $SkipVerify) {
  $ver = Join-Path $root "scripts\verify-networking.ps1"
  if (Test-Path $ver){
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ver
    if ($LASTEXITCODE -ne 0) { throw "verify-networking.ps1 reported issues. Check output above." }
  }
}

# ISO summary (non-fatal)
$needed = @()
if ($envMap.ISO_UBUNTU)  { if (-not (Test-Path (Join-Path $isos $envMap.ISO_UBUNTU)))  { $needed += (Join-Path $isos $envMap.ISO_UBUNTU) } }
if ($envMap.ISO_WINDOWS) { if (-not (Test-Path (Join-Path $isos $envMap.ISO_WINDOWS))) { $needed += (Join-Path $isos $envMap.ISO_WINDOWS) } }

Write-Host ""
Write-Host "====================== SOC-9000 :: SUMMARY =====================" -ForegroundColor White
Write-Host "Repo root  : $root"
Write-Host "Log        : $log"
Write-Host "ISOs dir   : $isos"
if ($needed.Count -gt 0) {
  Write-Warning "Place the following missing ISO(s) then re-run if needed:"
  $needed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
} else {
  Write-Host "ISOs       : OK or not configured"
}
Write-Host "================================================================" -ForegroundColor White

Stop-Transcript | Out-Null
