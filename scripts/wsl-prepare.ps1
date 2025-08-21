
[CmdletBinding()]
param(
  [string]$DistroName = "Ubuntu"   # Change if you prefer a different image
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) { throw "Run elevated (Administrator)." }

Write-Host "WSL preflight..." -ForegroundColor Cyan

# 1) Ensure optional features
$feat1 = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
$feat2 = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
$needReboot = $false
foreach ($f in @($feat1,$feat2)) {
  if ($f.State -ne 'Enabled') {
    Write-Host "Enabling $($f.FeatureName)..." -ForegroundColor Yellow
    Enable-WindowsOptionalFeature -Online -FeatureName $f.FeatureName -NoRestart | Out-Null
    $needReboot = $true
  }
}
if ($needReboot) {
  Write-Warning "Windows features enabled. Please reboot once, then rerun setup."
  exit 2
}

# 2) Install WSL platform if missing (kernel + wsl.exe)
try {
  wsl.exe --version | Out-Null
} catch {
  Write-Host "Installing WSL platform..." -ForegroundColor Yellow
  wsl.exe --install --no-distribution --web-download
  Write-Warning "WSL platform installed. Please reboot once, then rerun setup."
  exit 2
}

# 3) Ensure the target distro is installed (do not launch/init it yet)
$dlist = (& wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
if ($dlist -notcontains $DistroName) {
  Write-Host "Installing $DistroName..." -ForegroundColor Yellow
  # Prefer web download to avoid Store prompts on some hosts
  wsl.exe --install -d $DistroName --no-launch --web-download
}

# 4) Confirm registration presence
$dlist = (& wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
if ($dlist -notcontains $DistroName) {
  throw "WSL distro '$DistroName' not present after install attempt."
}

Write-Host "WSL preflight OK (distro registered: $DistroName)." -ForegroundColor Green
exit 0
