[CmdletBinding()]
param(
  [string]$CacheDir,
  [int]$KeepDays = 30,
  [switch]$Aggressive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Line([string]$Text, [string]$Kind = 'info') {
  $fg = @{ info='Gray'; ok='Green'; warn='Yellow'; err='Red' }[$Kind]
  $tag = @{ info='[i]'; ok='[OK]'; warn='[!]'; err='[X]' }[$Kind]
  Write-Host ("  {0} {1}" -f $tag, $Text) -ForegroundColor $fg
}

# Resolve cache dir (default under SOC-9000-Install)
if (-not $CacheDir) {
  if ($env:PACKER_CACHE_DIR) { $CacheDir = $env:PACKER_CACHE_DIR }
  else {
    $root = if (Test-Path 'E:\') { 'E:\SOC-9000-Install' } else { 'C:\SOC-9000-Install' }
    $CacheDir = Join-Path $root 'cache\packer'
  }
}

if (-not (Test-Path $CacheDir)) {
  Line "Cache dir not found: $CacheDir" 'info'
  exit 0
}

# Never clean while packer is running
$packerProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -like 'packer*' -or ($_.Path -and $_.Path -match 'packer')
} | Select-Object -First 1
if ($packerProcs) {
  Line 'Packer appears to be running; skipping cache clean.' 'warn'
  exit 0
}

Line "Cleaning Packer cache: $CacheDir" 'info'

# 1) Remove the VMware plugin port reservations
$portDir = Join-Path $CacheDir 'port'
if (Test-Path $portDir) {
  try { Remove-Item -Recurse -Force -Path $portDir; Line 'Removed port reservations.' 'ok' }
  catch { Line "Failed to remove port dir: $_" 'warn' }
}

# 2) Delete old lock/tmp/plugin temp files
$cutoff = (Get-Date).AddDays(-$KeepDays)
Get-ChildItem -Path $CacheDir -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Extension -in '.lock','.tmp' -or
    $_.Name -match '^packer-plugin-.*\.exe(\.tmp)?$'
  } |
  Where-Object { $_.LastWriteTime -lt $cutoff } |
  Remove-Item -Force -ErrorAction SilentlyContinue

# 3) Aggressive mode: purge non-ISO artifacts older than N days (keeps ISOs/boxes)
if ($Aggressive) {
  Get-ChildItem -Path $CacheDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -notin '.iso','.box','.xz','.gz','.zip' -and $_.LastWriteTime -lt $cutoff } |
    Remove-Item -Force -ErrorAction SilentlyContinue

  # Remove empty directories left behind
  Get-ChildItem -Path $CacheDir -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { (Get-ChildItem -Path $_.FullName -Force | Measure-Object).Count -eq 0 } |
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue

  Line "Aggressive clean complete (kept ISOs/boxes)." 'ok'
} else {
  Line "Basic clean complete (locks/tmp/port only)." 'ok'
}