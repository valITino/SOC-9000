[CmdletBinding()]
param(
    [string]$EnvPath,
    [string]$OutFile,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DotEnvMap([string]$Path){
    $m=@{}; if(Test-Path $Path){
        Get-Content $Path | Where-Object {$_ -and $_ -notmatch '^\s*#'} | ForEach-Object {
            if($_ -match '^([^=]+)=(.*)$'){ $m[$matches[1].Trim()]=$matches[2].Trim() }
        }
    }; $m
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
    return ($bits -notmatch '01')
}
function Test-Network24([string]$subnet){
    if(-not (Test-IPv4Address $subnet)){ return $false }
    $oct = $subnet -split '\.'
    return ($oct[3] -eq '0')
}
function Get-HostOnlyGatewayIp([string]$subnet){
    $oct = $subnet -split '\.'; "$($oct[0]).$($oct[1]).$($oct[2]).1"
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile  = if($EnvPath){ $EnvPath } elseif (Test-Path (Join-Path $RepoRoot '.env')) { Join-Path $RepoRoot '.env' } elseif (Test-Path (Join-Path $RepoRoot '.env.example')) { Join-Path $RepoRoot '.env.example' } else { $null }
$envMap   = if($envFile){ Get-DotEnvMap $envFile } else { @{} }

# InstallRoot & default locations
$EExists = Test-Path 'E:\'
$DefaultInstallRoot = $(if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path $env:SystemDrive 'SOC-9000-Install' })
$InstallRoot = $DefaultInstallRoot
if ($envMap.ContainsKey('INSTALL_ROOT') -and $envMap['INSTALL_ROOT']) { $InstallRoot = $envMap['INSTALL_ROOT'] }

$DefaultProfileDir = Join-Path $InstallRoot 'config\network'
$LogDir            = Join-Path $InstallRoot 'logs\installation'
New-Item -ItemType Directory -Force -Path $DefaultProfileDir,$LogDir | Out-Null

# addressing from env or defaults
$Vmnet8Subnet  = $envMap['VMNET8_SUBNET'];  if(-not $Vmnet8Subnet){  $Vmnet8Subnet  = '192.168.37.0' }
$Vmnet8Mask    = $envMap['VMNET8_MASK'];    if(-not $Vmnet8Mask){    $Vmnet8Mask    = '255.255.255.0' }
$Vmnet8HostIp  = $envMap['VMNET8_HOSTIP'];  if(-not $Vmnet8HostIp){  $Vmnet8HostIp  = '192.168.37.1' }
$Vmnet8Gateway = $envMap['VMNET8_GATEWAY']; if(-not $Vmnet8Gateway){ $Vmnet8Gateway = '192.168.37.2' }
$HostOnlyMask  = $envMap['HOSTONLY_MASK'];  if(-not $HostOnlyMask){  $HostOnlyMask  = '255.255.255.0' }
$Vmnet20Subnet = $envMap['VMNET20_SUBNET']; if(-not $Vmnet20Subnet){ $Vmnet20Subnet = '172.22.10.0' }
$Vmnet21Subnet = $envMap['VMNET21_SUBNET']; if(-not $Vmnet21Subnet){ $Vmnet21Subnet = '172.22.20.0' }
$Vmnet22Subnet = $envMap['VMNET22_SUBNET']; if(-not $Vmnet22Subnet){ $Vmnet22Subnet = '172.22.30.0' }
$Vmnet23Subnet = $envMap['VMNET23_SUBNET']; if(-not $Vmnet23Subnet){ $Vmnet23Subnet = '172.22.40.0' }

# validate
Test-ConditionOrThrow (Test-Network24 $Vmnet8Subnet)      "VMNET8_SUBNET is invalid (must be A.B.C.0)."
Test-ConditionOrThrow (Test-IPv4Mask $Vmnet8Mask)         "VMNET8_MASK is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8HostIp)    "VMNET8_HOSTIP is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8Gateway)   "VMNET8_GATEWAY is invalid."
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
    Test-ConditionOrThrow (Test-Network24 $s) "Host-only subnet '$s' is invalid (must be A.B.C.0)."
}
Test-ConditionOrThrow (Test-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK is invalid."

# build profile
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
    $hn = "vmnet$($def.n)"; $hip = Get-HostOnlyGatewayIp $def.s
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

# write output to InstallRoot\config\network (or user-specified)
if (-not $OutFile) {
    $OutFile = Join-Path $DefaultProfileDir 'vmnet-profile.txt'
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
}
Set-Content -Path $OutFile -Value $text -Encoding ASCII

# copy to InstallRoot\logs\installation for traceability (not in repo)
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$logCopy = Join-Path $LogDir "vmnet-profile-$ts.txt"
Set-Content -Path $logCopy -Value $text -Encoding ASCII

Write-Host "VMnet profile written: $OutFile"
if ($PassThru) { $text }