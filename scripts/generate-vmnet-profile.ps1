[CmdletBinding()]
param(
    [string]$EnvPath,
    [string]$OutFile,
    [switch]$PassThru,
    [switch]$CopyToLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DotEnvMap([string]$Path){
    if (-not $Path -or -not (Test-Path $Path)) { return @{} }
    $m=@{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k,$v = $_ -split '=',2
        if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
    }
    return $m
}
function Test-ConditionOrThrow($cond,[string]$msg){ if(-not $cond){ throw $msg } }
function Test-IPv4Address([string]$ip){
    if($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$'){ return $false }
    foreach($oct in $ip -split '\.'){ if([int]$oct -gt 255){ return $false } }
    return $true
}
function Test-IPv4Mask([string]$mask){
    if(-not (Test-IPv4Address $mask)){ return $false }
    $bytes=[Net.IPAddress]::Parse($mask).GetAddressBytes()
    $bits = ($bytes | ForEach-Object { [Convert]::ToString($_,2).PadLeft(8,'0') }) -join ''
    return ($bits -notmatch '01')  # all 1s then all 0s
}
function Test-Network24([string]$subnet){
    if(-not (Test-IPv4Address $subnet)){ return $false }
    $oct = $subnet -split '\.'
    return ($oct[3] -eq '0')
}
function Get-HostOnlyGatewayIp([string]$subnet){
    $o = $subnet -split '\.'; "$($o[0]).$($o[1]).$($o[2]).1"
}

# Resolve roots
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvFile  = if($EnvPath){ $EnvPath }
elseif (Test-Path (Join-Path $RepoRoot '.env')) { Join-Path $RepoRoot '.env' }
elseif (Test-Path (Join-Path $RepoRoot '.env.example')) { Join-Path $RepoRoot '.env.example' }
else { $null }
$EnvMap   = if($EnvFile){ Get-DotEnvMap $EnvFile } else { @{} }

$EExists  = Test-Path 'E:\'
$DefaultInstallRoot = if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path $env:SystemDrive 'SOC-9000-Install' }
$InstallRoot = if ($EnvMap['INSTALL_ROOT']) { $EnvMap['INSTALL_ROOT'] } else { $DefaultInstallRoot }

$ProfileDir = Join-Path $InstallRoot 'config\network'
$LogDir     = Join-Path $InstallRoot 'logs\installation'
New-Item -ItemType Directory -Force -Path $ProfileDir,$LogDir | Out-Null

# Addressing (env overrides or defaults)
$Vmnet8Subnet  = $EnvMap['VMNET8_SUBNET'];  if(-not $Vmnet8Subnet){  $Vmnet8Subnet  = '192.168.37.0' }
$Vmnet8Mask    = $EnvMap['VMNET8_MASK'];    if(-not $Vmnet8Mask){    $Vmnet8Mask    = '255.255.255.0' }
$Vmnet8HostIp  = $EnvMap['VMNET8_HOSTIP'];  if(-not $Vmnet8HostIp){  $Vmnet8HostIp  = '192.168.37.1' }
$Vmnet8Gateway = $EnvMap['VMNET8_GATEWAY']; if(-not $Vmnet8Gateway){ $Vmnet8Gateway = '192.168.37.2' }

$HostOnlyMask  = $EnvMap['HOSTONLY_MASK'];  if(-not $HostOnlyMask){  $HostOnlyMask  = '255.255.255.0' }
$Vmnet20Subnet = $EnvMap['VMNET20_SUBNET']; if(-not $Vmnet20Subnet){ $Vmnet20Subnet = '172.22.10.0' }
$Vmnet21Subnet = $EnvMap['VMNET21_SUBNET']; if(-not $Vmnet21Subnet){ $Vmnet21Subnet = '172.22.20.0' }
$Vmnet22Subnet = $EnvMap['VMNET22_SUBNET']; if(-not $Vmnet22Subnet){ $Vmnet22Subnet = '172.22.30.0' }
$Vmnet23Subnet = $EnvMap['VMNET23_SUBNET']; if(-not $Vmnet23Subnet){ $Vmnet23Subnet = '172.22.40.0' }

# Validate
Test-ConditionOrThrow (Test-Network24   $Vmnet8Subnet)    "VMNET8_SUBNET is invalid (must be A.B.C.0)."
Test-ConditionOrThrow (Test-IPv4Mask    $Vmnet8Mask)      "VMNET8_MASK is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8HostIp)    "VMNET8_HOSTIP is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8Gateway)   "VMNET8_GATEWAY is invalid."
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
    Test-ConditionOrThrow (Test-Network24 $s) "Host-only subnet '$s' is invalid (must be A.B.C.0)."
}
Test-ConditionOrThrow (Test-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK is invalid."

# Build vnetlib import text (create first, then update)
$lines = @()
$lines += @(
    "add adapter vmnet8",
    "add vnet vmnet8",
    "set vnet vmnet8 addr $Vmnet8Subnet",
    "set vnet vmnet8 mask $Vmnet8Mask",
    "set adapter vmnet8 addr $Vmnet8HostIp",
    "add nat vmnet8",
    "set nat vmnet8 internalipaddr $Vmnet8Gateway",
    "add dhcp vmnet8",
    "update adapter vmnet8",
    "update nat vmnet8",
    "update dhcp vmnet8",
    ""
)
# Read preferred host-only IDs (default to 9-12)
$hostOnlyIds = @()
if ($EnvMap.ContainsKey('HOSTONLY_VMNET_IDS') -and $EnvMap['HOSTONLY_VMNET_IDS']) {
    $hostOnlyIds = $EnvMap['HOSTONLY_VMNET_IDS'] -split ',' | ForEach-Object { [int]($_.Trim()) }
} else {
    $hostOnlyIds = 9,10,11,12
}

$hostOnlySubnets = @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)

for ($i=0; $i -lt $hostOnlySubnets.Count; $i++) {
    $id  = $hostOnlyIds[$i]
    $s   = $hostOnlySubnets[$i]
    $hip = Get-HostOnlyGatewayIp $s
    $hn  = "vmnet$($id)"
    $lines += @(
        "add adapter $hn",
        "add vnet $hn",
        "set vnet $hn addr $s",
        "set vnet $hn mask $HostOnlyMask",
        "set adapter $hn addr $hip",
        "update adapter $hn",
        ""
    )
}
{
    $hn  = "vmnet$($def.n)"
    $hip = Get-HostOnlyGatewayIp $def.s
    $lines += @(
        "add adapter $hn",
        "add vnet $hn",
        "set vnet $hn addr $($def.s)",
        "set vnet $hn mask $HostOnlyMask",
        "set adapter $hn addr $hip",
        "update adapter $hn",
        ""
    )
}
$text = ($lines -join "`r`n")

# Write canonical profile
if (-not $OutFile) {
    $OutFile = Join-Path $ProfileDir 'vmnet-profile.txt'
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
}
Set-Content -Path $OutFile -Value $text -Encoding ASCII
Write-Host "VMnet profile written: $OutFile"

# Optional snapshot to logs (for auditing)
if ($CopyToLogs) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $logCopy = Join-Path $LogDir "vmnet-profile-$ts.txt"
    Set-Content -Path $logCopy -Value $text -Encoding ASCII
    Write-Host "VMnet profile snapshot copied to: $logCopy"
}

if ($PassThru) { $text }