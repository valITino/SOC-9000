[CmdletBinding()]
param(
  [string]$EnvPath,
  [string]$OutFile,
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-DotEnv([string]$Path){
  $m=@{}; if(Test-Path $Path){
    Get-Content $Path | Where-Object {$_ -and $_ -notmatch '^\s*#'} | ForEach-Object {
      if($_ -match '^([^=]+)=(.*)$'){ $m[$matches[1].Trim()]=$matches[2].Trim() }
    }
  }; $m
}
function ThrowIfFalse($cond,[string]$msg){ if(-not $cond){ throw $msg } }
function Is-IPv4([string]$ip){
  if($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$'){ return $false }
  foreach($oct in $ip -split '\.'){ if([int]$oct -gt 255){ return $false } }
  return $true
}
function Is-IPv4Mask([string]$mask){
  if(-not (Is-IPv4 $mask)){ return $false }
  $bytes=[Net.IPAddress]::Parse($mask).GetAddressBytes()
  $bits = ($bytes|%{[Convert]::ToString($_,2).PadLeft(8,'0')}) -join ''
  return ($bits -notmatch '01')
}
function Is-Network24([string]$subnet){
  if(-not (Is-IPv4 $subnet)){ return $false }
  $oct = $subnet -split '\.'
  return ($oct[3] -eq '0')
}
function HostOnlyIP([string]$subnet){
  $oct = $subnet -split '\.'; "$($oct[0]).$($oct[1]).$($oct[2]).1"
}
$repoRoot = Split-Path $PSScriptRoot -Parent
$envFile  = if($EnvPath){ $EnvPath } elseif (Test-Path (Join-Path $repoRoot '.env')) { Join-Path $repoRoot '.env' } elseif (Test-Path (Join-Path $repoRoot '.env.example')) { Join-Path $repoRoot '.env.example' } else { $null }
$envMap   = if($envFile){ Read-DotEnv $envFile } else { @{} }
$Vmnet8Subnet  = $envMap['VMNET8_SUBNET'];  if(-not $Vmnet8Subnet){  $Vmnet8Subnet  = '192.168.37.0' }
$Vmnet8Mask    = $envMap['VMNET8_MASK'];    if(-not $Vmnet8Mask){    $Vmnet8Mask    = '255.255.255.0' }
$Vmnet8HostIp  = $envMap['VMNET8_HOSTIP'];  if(-not $Vmnet8HostIp){  $Vmnet8HostIp  = '192.168.37.1' }
$Vmnet8Gateway = $envMap['VMNET8_GATEWAY']; if(-not $Vmnet8Gateway){ $Vmnet8Gateway = '192.168.37.2' }
$HostOnlyMask  = $envMap['HOSTONLY_MASK'];  if(-not $HostOnlyMask){  $HostOnlyMask  = '255.255.255.0' }
$Vmnet20Subnet = $envMap['VMNET20_SUBNET']; if(-not $Vmnet20Subnet){ $Vmnet20Subnet = '172.22.10.0' }
$Vmnet21Subnet = $envMap['VMNET21_SUBNET']; if(-not $Vmnet21Subnet){ $Vmnet21Subnet = '172.22.20.0' }
$Vmnet22Subnet = $envMap['VMNET22_SUBNET']; if(-not $Vmnet22Subnet){ $Vmnet22Subnet = '172.22.30.0' }
$Vmnet23Subnet = $envMap['VMNET23_SUBNET']; if(-not $Vmnet23Subnet){ $Vmnet23Subnet = '172.22.40.0' }
ThrowIfFalse (Is-Network24 $Vmnet8Subnet)   "VMNET8_SUBNET is invalid (must be A.B.C.0)."
ThrowIfFalse (Is-IPv4Mask $Vmnet8Mask)      "VMNET8_MASK is invalid."
ThrowIfFalse (Is-IPv4 $Vmnet8HostIp)        "VMNET8_HOSTIP is invalid."
ThrowIfFalse (Is-IPv4 $Vmnet8Gateway)       "VMNET8_GATEWAY is invalid."
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
  ThrowIfFalse (Is-Network24 $s) "Host-only subnet '$s' is invalid (must be A.B.C.0)."
}
ThrowIfFalse (Is-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK is invalid."
$lines = @()
$lines += @(
  "add vnet vmnet8",
  "set vnet vmnet8 addr $Vmnet8Subnet",
  "set vnet vmnet8 mask $Vmnet8Mask",
  "set adapter vmnet8 addr $Vmnet8HostIp",
  "set nat vmnet8 internalipaddr $Vmnet8Gateway",
  "update adapter vmnet8",
  "update nat vmnet8",
  "update dhcp vmnet8",
  ""
)
foreach($def in @(@{n=20;s=$Vmnet20Subnet},@{n=21;s=$Vmnet21Subnet},@{n=22;s=$Vmnet22Subnet},@{n=23;s=$Vmnet23Subnet})) {
  $hn = "vmnet$($def.n)"; $hip = HostOnlyIP $def.s
  $lines += @(
    "add vnet $hn",
    "set vnet $hn addr $($def.s)",
    "set vnet $hn mask $HostOnlyMask",
    "set adapter $hn addr $hip",
    "update adapter $hn",
    ""
  )
}
$text = ($lines -join "`r`n")
$art = Join-Path $repoRoot 'artifacts\network'
if (-not $OutFile) { $OutFile = Join-Path $art 'vmnet-profile.txt' }
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
Set-Content -Path $OutFile -Value $text -Encoding ASCII
$logDir = Join-Path $repoRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"; $logCopy = Join-Path $logDir "vmnet-profile-$ts.txt"
Set-Content -Path $logCopy -Value $text -Encoding ASCII
Write-Host "VMnet profile written: $OutFile"
if ($PassThru) { $text }