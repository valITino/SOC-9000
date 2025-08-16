[CmdletBinding()]
param(
    [string]$EnvPath,
    [string]$OutFile,
    [switch]$PassThru,
    [switch]$CopyToLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-DotEnv([string]$Path){
    if (-not $Path -or -not (Test-Path $Path)) { return @{} }
    $map=@{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k,$v = $_ -split '=',2
        if ($null -ne $v) { $map[$k.Trim()] = $v.Trim() }
    }
    return $map
}
function Test-IPv4Address([string]$Ip){
    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach($oct in ($Ip -split '\.')){ if([int]$oct -gt 255){ return $false } }
    return $true
}
function Test-IPv4Mask([string]$Mask){
    if (-not (Test-IPv4Address $Mask)) { return $false }
    $bytes=[Net.IPAddress]::Parse($Mask).GetAddressBytes()
    $bits = ($bytes | ForEach-Object { [Convert]::ToString($_,2).PadLeft(8,'0') }) -join ''
    return ($bits -notmatch '01')
}
function Test-Network24([string]$Subnet){ if (-not (Test-IPv4Address $Subnet)) { return $false }; ($Subnet -split '\.')[3] -eq '0' }
function Get-HostOnlyGatewayIp([string]$Subnet){ $o=$Subnet -split '\.'; "$($o[0]).$($o[1]).$($o[2]).1" }

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile  = if ($EnvPath) { $EnvPath } elseif (Test-Path (Join-Path $RepoRoot '.env')) { Join-Path $RepoRoot '.env' } else { $null }
$envMap   = if ($envFile) { Read-DotEnv $envFile } else { @{} }

$EExists      = Test-Path 'E:\'
$InstallRoot  = if ($envMap['INSTALL_ROOT']) { $envMap['INSTALL_ROOT'] } else { if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path ${env:SystemDrive} 'SOC-9000-Install' } }
$ProfileDir   = Join-Path $InstallRoot 'config\network'
$LogDir       = Join-Path $InstallRoot 'logs\installation'
New-Item -ItemType Directory -Force -Path $ProfileDir,$LogDir | Out-Null

# Addresses (env overrides)
$Vmnet8Subnet  = if ($envMap['VMNET8_SUBNET'])  { $envMap['VMNET8_SUBNET'] }  else { '192.168.37.0' }
$Vmnet8Mask    = if ($envMap['VMNET8_MASK'])    { $envMap['VMNET8_MASK'] }    else { '255.255.255.0' }
$Vmnet8HostIp  = if ($envMap['VMNET8_HOSTIP'])  { $envMap['VMNET8_HOSTIP'] }  else { '192.168.37.1' }
$Vmnet8Gateway = if ($envMap['VMNET8_GATEWAY']) { $envMap['VMNET8_GATEWAY'] } else { '192.168.37.2' }

$HostOnlyMask  = if ($envMap['HOSTONLY_MASK'])  { $envMap['HOSTONLY_MASK'] }  else { '255.255.255.0' }
$Vmnet20Subnet = if ($envMap['VMNET20_SUBNET']) { $envMap['VMNET20_SUBNET'] } else { '172.22.10.0' }
$Vmnet21Subnet = if ($envMap['VMNET21_SUBNET']) { $envMap['VMNET21_SUBNET'] } else { '172.22.20.0' }
$Vmnet22Subnet = if ($envMap['VMNET22_SUBNET']) { $envMap['VMNET22_SUBNET'] } else { '172.22.30.0' }
$Vmnet23Subnet = if ($envMap['VMNET23_SUBNET']) { $envMap['VMNET23_SUBNET'] } else { '172.22.40.0' }

# Host-only VMnet IDs (configurable; default 9–12)
[int[]]$Ids = @()
if ($envMap.ContainsKey('HOSTONLY_VMNET_IDS') -and $envMap['HOSTONLY_VMNET_IDS']) {
    $Ids = $envMap['HOSTONLY_VMNET_IDS'] -split ',' | ForEach-Object { [int]($_.Trim()) }
} else { $Ids = 9,10,11,12 }

# Validate
if (-not (Test-Network24 $Vmnet8Subnet)) { throw "VMNET8_SUBNET invalid." }
if (-not (Test-IPv4Mask  $Vmnet8Mask))   { throw "VMNET8_MASK invalid." }
if (-not (Test-IPv4Address $Vmnet8HostIp))  { throw "VMNET8_HOSTIP invalid." }
if (-not (Test-IPv4Address $Vmnet8Gateway)) { throw "VMNET8_GATEWAY invalid." }
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
    if (-not (Test-Network24 $s)) { throw "Host-only subnet '$s' invalid." }
}
if (-not (Test-IPv4Mask $HostOnlyMask)) { throw "HOSTONLY_MASK invalid." }

$subs=@($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)
$lines=@(
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
for ($i=0; $i -lt $subs.Count; $i++) {
    $id  = $Ids[$i]; $s = $subs[$i]; $hip = Get-HostOnlyGatewayIp $s
    $lines += @(
        "add adapter vmnet$id",
        "add vnet vmnet$id",
        "set vnet vmnet$id addr $s",
        "set vnet vmnet$id mask $HostOnlyMask",
        "set adapter vmnet$id addr $hip",
        "update adapter vmnet$id",
        ""
    )
}
$text = ($lines -join "`r`n")

if (-not $OutFile) { $OutFile = Join-Path $ProfileDir 'vmnet-profile.txt' } else { New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null }
Set-Content -Path $OutFile -Value $text -Encoding ASCII
Write-Host "VMnet profile written: $OutFile"

if ($CopyToLogs) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $logCopy = Join-Path $LogDir "vmnet-profile-$ts.txt"
    Set-Content -Path $logCopy -Value $text -Encoding ASCII
    Write-Host "VMnet profile snapshot copied to: $logCopy"
}

if ($PassThru) { $text }