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

function Read-DotEnv([string]$Path){
  if (-not (Test-Path $Path)) { return @{} }
  $m=@{}; Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($v -ne $null){ $m[$k.Trim()]=$v.Trim() }
  }; $m
}

Ensure-Admin

$root = Split-Path -Parent $PSCommandPath
$logs = Join-Path $root "logs"; $isos = Join-Path $root "isos"
$art  = Join-Path $root "artifacts"; $tmp = Join-Path $root "temp"
New-Item -ItemType Directory -Force -Path $logs,$isos,$art,$tmp | Out-Null
try{ Stop-Transcript | Out-Null }catch{}
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logs "installer-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# Unblock repo
Get-ChildItem -Recurse -File $root | ForEach-Object { try{ Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }catch{} }

# .env hydration
$envPath = Join-Path $root ".env"
$envExample = Join-Path $root ".env.example"
if (-not (Test-Path $envPath) -and (Test-Path $envExample)) { Copy-Item $envExample $envPath -Force }
$envMap = Read-DotEnv $envPath
$envMap["LAB_ROOT"]  = $envMap["LAB_ROOT"]  ?? $root
$envMap["REPO_ROOT"] = $envMap["REPO_ROOT"] ?? $root
$envMap["ISO_DIR"]   = $envMap["ISO_DIR"]   ?? $isos
$lines = $envMap.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
Set-Content -Path $envPath -Value $lines -Encoding UTF8

if (-not $SkipNetworking) {
  $cfg = Join-Path $root "scripts\configure-vmnet.ps1"
  if (-not (Test-Path $cfg)) { throw "scripts\configure-vmnet.ps1 missing." }
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $cfg -Verbose
  if ($LASTEXITCODE -ne 0) { throw "configure-vmnet.ps1 failed. See $log for details." }
}

if (-not $SkipVerify) {
  $ver = Join-Path $root "scripts\verify-networking.ps1"
  if ((Test-Path $ver)) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ver
    if ($LASTEXITCODE -ne 0) { throw "verify-networking.ps1 reported issues. See output above." }
  }
}

# Missing ISO summary (non-fatal)
$needed=@()
foreach($k in @("ISO_PFSENSE","ISO_UBUNTU","ISO_WINDOWS")){
  if ($envMap[$k]) {
    $p = Join-Path $envMap["ISO_DIR"] $envMap[$k]
    if (-not (Test-Path $p)) { $needed += $p }
  }
}

Write-Host "`n====================== SOC-9000 :: SUMMARY =====================" -ForegroundColor White
Write-Host "Repo root  : $root"
Write-Host "Log        : $log"
Write-Host "ISOs dir   : $($envMap["ISO_DIR"])"
if ($needed.Count -gt 0){
  Write-Warning "Place the following missing ISO(s):"
  $needed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}else{
  Write-Host "ISOs       : OK or not configured"
}
Write-Host "================================================================" -ForegroundColor White
Stop-Transcript | Out-Null
