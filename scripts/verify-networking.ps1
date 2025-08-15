[CmdletBinding()]
param(
  [string]$Vmnet8Subnet   = "192.168.37.0",
  [string]$Vmnet8Mask     = "255.255.255.0",
  [string]$Vmnet8HostIp   = "192.168.37.1",
  [string]$Vmnet8Gw       = "192.168.37.2",
  [string]$Vmnet20Subnet  = "172.22.10.0",
  [string]$Vmnet21Subnet  = "172.22.20.0",
  [string]$Vmnet22Subnet  = "172.22.30.0",
  [string]$Vmnet23Subnet  = "172.22.40.0",
  [string]$HostOnlyMask   = "255.255.255.0"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail($m){ Write-Error $m; $script:failed = $true }

$script:failed = $false

# Services
foreach($s in "VMware NAT Service","VMnetDHCP"){
  $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
  if (-not $svc){ Fail "Service '$s' not found. Repair VMware Workstation."; continue }
  if ($svc.StartType -eq 'Disabled'){ Fail "Service '$s' is Disabled. Set to Automatic and Start it."; continue }
  if ($svc.Status -ne 'Running'){ Fail "Service '$s' is not Running. Start it in Services.msc."; }
}

# Config files
if (-not (Test-Path "C:\ProgramData\VMware\vmnetnat.conf"))  { Fail "vmnetnat.conf missing." }
if (-not (Test-Path "C:\ProgramData\VMware\vmnetdhcp.conf")) { Fail "vmnetdhcp.conf missing." }

# Adapters
$adapters = @("VMware Network Adapter VMnet8","VMware Network Adapter VMnet20","VMware Network Adapter VMnet21","VMware Network Adapter VMnet22","VMware Network Adapter VMnet23")
foreach($a in $adapters){
  $ad = Get-NetAdapter -Name $a -ErrorAction SilentlyContinue
  if (-not $ad){ Fail "Adapter '$a' not found."; continue }
  if ($ad.Status -ne 'Up'){ Fail "Adapter '$a' not Up."; }
}

# IPs (basic presence/consistency)
function Expect-IP($alias,$ipStartsWith){
  $cfg = Get-NetIPConfiguration -InterfaceAlias $alias -ErrorAction SilentlyContinue
  if (-not $cfg -or -not $cfg.IPv4Address){ Fail "No IPv4 on '$alias'."; return }
  $ip = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
  if (-not $ip.StartsWith($ipStartsWith)){ Fail "Host IP for '$alias' ($ip) not in expected subnet prefix '$ipStartsWith'." }
}
Expect-IP "VMware Network Adapter VMnet8" ($Vmnet8Subnet -replace '\.0$','.')
Expect-IP "VMware Network Adapter VMnet20" ($Vmnet20Subnet -replace '\.0$','.')
Expect-IP "VMware Network Adapter VMnet21" ($Vmnet21Subnet -replace '\.0$','.')
Expect-IP "VMware Network Adapter VMnet22" ($Vmnet22Subnet -replace '\.0$','.')
Expect-IP "VMware Network Adapter VMnet23" ($Vmnet23Subnet -replace '\.0$','.')

# DHCP OFF on host-only vmnets (by scanning vmnetdhcp.conf)
$dhcp = Get-Content "C:\ProgramData\VMware\vmnetdhcp.conf" -Raw
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
  if ($dhcp -match [regex]::Escape("subnet $s netmask $HostOnlyMask")){
    Fail "DHCP pool present for host-only subnet $s. Re-run configure-vmnet.ps1 to disable."
  }
}

# Hyper-V advisory
$hv = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue)
if ($hv -and $hv.State -eq 'Enabled'){
  Write-Warning "Hyper-V is enabled. Bridged behavior may vary under Hyper-V/WHv."
}

if ($script:failed){ exit 1 } else { 
  Write-Host "Networking verification: OK" -ForegroundColor Green
  exit 0
}
