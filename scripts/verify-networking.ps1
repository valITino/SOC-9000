[CmdletBinding()]
param(
  [string]$Vmnet8Subnet   = "192.168.37.0",
  [string]$Vmnet8Mask     = "255.255.255.0",
  [string]$Vmnet8HostIp   = "192.168.37.1",
  [string]$Vmnet8Gateway  = "192.168.37.2",
  [string]$Vmnet20Subnet  = "172.22.10.0",
  [string]$Vmnet21Subnet  = "172.22.20.0",
  [string]$Vmnet22Subnet  = "172.22.30.0",
  [string]$Vmnet23Subnet  = "172.22.40.0",
  [string]$HostOnlyMask   = "255.255.255.0"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function MaskToPrefix([string]$mask){
  $bytes=[Net.IPAddress]::Parse($mask).GetAddressBytes()
  $bits=($bytes|%{[Convert]::ToString($_,2).PadLeft(8,'0')}) -join ''
  ($bits -split '0')[0].Length
}
function HostOnlyIP([string]$s){ $o=$s -split '\.'; "$($o[0]).$($o[1]).$($o[2]).1" }
function fail($m){ Write-Error $m; $script:bad=$true }

$script:bad=$false

# Services
foreach($svcName in "VMware NAT Service","VMnetDHCP"){
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if (-not $svc){ fail "Service '$svcName' not found."; continue }
  if ($svc.StartType -eq 'Disabled'){ fail "Service '$svcName' is Disabled. Set to Automatic and start."; continue }
  if ($svc.Status -ne 'Running'){ fail "Service '$svcName' is not Running."; }
}

# Config files
if (-not (Test-Path "C:\ProgramData\VMware\vmnetnat.conf"))  { fail "vmnetnat.conf missing." }
if (-not (Test-Path "C:\ProgramData\VMware\vmnetdhcp.conf")) { fail "vmnetdhcp.conf missing." }

# Adapters + IPs
$targets = @(
  @{Alias="VMware Network Adapter VMnet8";  IP=$Vmnet8HostIp; Mask=$Vmnet8Mask},
  @{Alias="VMware Network Adapter VMnet20"; IP=(HostOnlyIP $Vmnet20Subnet); Mask=$HostOnlyMask},
  @{Alias="VMware Network Adapter VMnet21"; IP=(HostOnlyIP $Vmnet21Subnet); Mask=$HostOnlyMask},
  @{Alias="VMware Network Adapter VMnet22"; IP=(HostOnlyIP $Vmnet22Subnet); Mask=$HostOnlyMask},
  @{Alias="VMware Network Adapter VMnet23"; IP=(HostOnlyIP $Vmnet23Subnet); Mask=$HostOnlyMask}
)
foreach($t in $targets){
  $ad = Get-NetAdapter -Name $t.Alias -ErrorAction SilentlyContinue
  if (-not $ad){ fail "Adapter '$($t.Alias)' missing."; continue }
  if ($ad.Status -ne 'Up'){ fail "Adapter '$($t.Alias)' not Up."; }
  $ip = Get-NetIPAddress -InterfaceAlias $t.Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $ip){ fail "No IPv4 on '$($t.Alias)'."; continue }
  if ($ip.IPAddress -ne $t.IP){ fail "'$($t.Alias)' IP is $($ip.IPAddress) expected $($t.IP)." }
  if ($ip.PrefixLength -ne (MaskToPrefix $t.Mask)){ fail "'$($t.Alias)' mask mismatch." }
}

# Hyper-V advisory
$hv = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue)
if ($hv -and $hv.State -eq 'Enabled'){ Write-Warning "Hyper-V enabled; bridged may be quirky." }

if ($script:bad){ exit 1 } else { Write-Host "Networking verification: OK" -ForegroundColor Green; exit 0 }
