# path: scripts/configure-vmnet.ps1
<#
.SYNOPSIS
  Declarative VMware VMnet setup for Workstation Pro 17.x (Windows 11).
.DESCRIPTION
  Validates inputs, backs up current config, generates a vnetlib import file,
  imports atomically (stop→import→start), disables DHCP on host-only VMnets,
  and verifies adapters/services. Idempotent and PS 5.1 / 7 compatible.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Vmnet8Subnet   = "192.168.37.0",
  [string]$Vmnet8Mask     = "255.255.255.0",
  [string]$Vmnet8HostIp   = "192.168.37.1",
  [string]$Vmnet8Gateway  = "192.168.37.2",
  [string]$Vmnet20Subnet  = "172.22.10.0",
  [string]$Vmnet21Subnet  = "172.22.20.0",
  [string]$Vmnet22Subnet  = "172.22.30.0",
  [string]$Vmnet23Subnet  = "172.22.40.0",
  [string]$HostOnlyMask   = "255.255.255.0",
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- helpers ---
function Ensure-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p =New-Object Security.Principal.WindowsPrincipal $id
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null; exit 0
  }
}
function Read-DotEnv([string]$Path){
  if(-not (Test-Path $Path)){return @{}}
  $m=@{}; Get-Content $Path | ForEach-Object {
    if($_ -match '^\s*#' -or $_ -match '^\s*$'){return}
    $k,$v = $_ -split '=',2; if($v -ne $null){$m[$k.Trim()]=$v.Trim()}
  }; $m
}
function TrySetFromEnv([hashtable]$envMap,[string]$key,[ref]$target){
  if($envMap.ContainsKey($key) -and $envMap[$key]){ $target.Value = $envMap[$key] }
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
  # valid mask = all 1s then all 0s
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

function Find-VNetLib {
  foreach($p in @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
    "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
  )){ if(Test-Path $p){ return $p } }
  $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
  if($cmd){ return $cmd.Source }
  throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run."
}
function Invoke-VMnet([string[]]$Args){
  Write-Verbose ("vnetlib64 -- " + ($Args -join ' '))
  & $script:VNetLib -- @Args
  if($LASTEXITCODE -ne 0){ throw "vnetlib failed ($LASTEXITCODE): $($Args -join ' ')" }
}
function Export-VMnetProfile([string]$Path){ Invoke-VMnet @("export",$Path) }

function Build-ImportCommands {
  param(
    [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,[string]$Vmnet8Gateway,
    [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,[string]$HostOnlyMask
  )
  $L = New-Object System.Collections.Generic.List[string]
  # NAT VMnet8 (DHCP ON)
  $L.Add("add vnet vmnet8")
  $L.Add("set vnet vmnet8 addr $Vmnet8Subnet")
  $L.Add("set vnet vmnet8 mask $Vmnet8Mask")
  $L.Add("set adapter vmnet8 addr $Vmnet8HostIp")
  $L.Add("set nat vmnet8 internalipaddr $Vmnet8Gateway")
  $L.Add("update adapter vmnet8")
  $L.Add("update nat vmnet8")
  $L.Add("update dhcp vmnet8")
  # Host-only VMnets (DHCP OFF)
  foreach($def in @(
    @{n=20;s=$Vmnet20Subnet},
    @{n=21;s=$Vmnet21Subnet},
    @{n=22;s=$Vmnet22Subnet},
    @{n=23;s=$Vmnet23Subnet}
  )){
    $hn = "vmnet$($def.n)"; $hip = HostOnlyIP $def.s
    $L.Add("add vnet $hn")
    $L.Add("set vnet $hn addr $($def.s)")
    $L.Add("set vnet $hn mask $HostOnlyMask")
    $L.Add("set adapter $hn addr $hip")
    $L.Add("update adapter $hn")
  }
  ($L -join "`r`n") + "`r`n"
}
function Prune-HostOnlyDhcp([string[]]$Subnets,[string]$Mask){
  $dhcp="C:\ProgramData\VMware\vmnetdhcp.conf"
  if(-not (Test-Path $dhcp)){ return }
  $raw = Get-Content $dhcp -Raw
  foreach($s in $Subnets){
    $pat = "subnet\s+$([regex]::Escape($s))\s+netmask\s+$([regex]::Escape($Mask))\s*\{[^}]*\}"
    $raw = [regex]::Replace($raw,$pat,"","Singleline,IgnoreCase")
  }
  Set-Content -Path $dhcp -Value $raw -Encoding ASCII
}
function Test-SvcsOk {
  $n=Get-Service "VMware NAT Service" -ErrorAction SilentlyContinue
  $d=Get-Service "VMnetDHCP" -ErrorAction SilentlyContinue
  return ($n -and $d -and $n.Status -eq 'Running' -and $d.Status -eq 'Running')
}
function Verify-State {
  param(
    [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,
    [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,[string]$HostOnlyMask
  )
  $rows=@()
  foreach($row in @(
    @{V="VMnet8";  T="NAT";      S=$Vmnet8Subnet;  M=$Vmnet8Mask;  IP=$Vmnet8HostIp},
    @{V="VMnet20"; T="HostOnly"; S=$Vmnet20Subnet; M=$HostOnlyMask; IP=(HostOnlyIP $Vmnet20Subnet)},
    @{V="VMnet21"; T="HostOnly"; S=$Vmnet21Subnet; M=$HostOnlyMask; IP=(HostOnlyIP $Vmnet21Subnet)},
    @{V="VMnet22"; T="HostOnly"; S=$Vmnet22Subnet; M=$HostOnlyMask; IP=(HostOnlyIP $Vmnet22Subnet)},
    @{V="VMnet23"; T="HostOnly"; S=$Vmnet23Subnet; M=$HostOnlyMask; IP=(HostOnlyIP $Vmnet23Subnet)}
  )){
    $alias = "VMware Network Adapter $($row.V)"
    $ad = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    $ip = (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $rows += [pscustomobject]@{
      VMnet=$row.V; Type=$row.T; Subnet=$row.S; Mask=$row.M;
      ExpectedIP=$row.IP; ActualIP=($ip ?? "");
      AdapterUp = ($ad -and $ad.Status -eq 'Up');
      ServicesOK = (Test-SvcsOk)
    }
  }
  $rows
}
function Print-Summary([object[]]$Rows,[string]$BackupFile,[string]$ImportFile){
  Write-Host "`n================== VMware VMnet Summary ==================" -ForegroundColor White
  "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-15} {6,-8}" -f "VMnet","Type","Subnet","Mask","ExpectedIP","ActualIP","Services" | Write-Host
  $bad=$false
  foreach($r in $Rows){
    $svc = if($r.ServicesOK){"OK"}else{"FAIL"}
    $okLine = ($r.AdapterUp -and $r.ServicesOK -and ($r.ExpectedIP -eq $r.ActualIP))
    $line = "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-15} {6,-8}" -f $r.VMnet,$r.Type,$r.Subnet,$r.Mask,$r.ExpectedIP,($r.ActualIP ?? "-"),$svc
    if($okLine){ Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Yellow; $bad=$true }
  }
  Write-Host "Backup file : $BackupFile"
  Write-Host "Import file : $ImportFile"
  Write-Host "==========================================================" -ForegroundColor White
  if ($bad){
    throw "One or more checks failed. Validate .env IPs/masks, ensure 'VMware NAT Service' and 'VMnetDHCP' are Running, then re-run."
  }
}

# --- main ---
Ensure-Admin
$root   = Split-Path -Parent $PSCommandPath
$logDir = Join-Path $root "..\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try{ Stop-Transcript | Out-Null }catch{}
$ts  = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "configure-vmnet-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# .env overrides (PS 5/7 safe)
$envMap = Read-DotEnv (Join-Path $root "..\.env")
TrySetFromEnv $envMap 'VMNET8_SUBNET'   ([ref]$Vmnet8Subnet)
TrySetFromEnv $envMap 'VMNET8_MASK'     ([ref]$Vmnet8Mask)
TrySetFromEnv $envMap 'VMNET8_HOSTIP'   ([ref]$Vmnet8HostIp)
TrySetFromEnv $envMap 'VMNET8_GATEWAY'  ([ref]$Vmnet8Gateway)
TrySetFromEnv $envMap 'VMNET20_SUBNET'  ([ref]$Vmnet20Subnet)
TrySetFromEnv $envMap 'VMNET21_SUBNET'  ([ref]$Vmnet21Subnet)
TrySetFromEnv $envMap 'VMNET22_SUBNET'  ([ref]$Vmnet22Subnet)
TrySetFromEnv $envMap 'VMNET23_SUBNET'  ([ref]$Vmnet23Subnet)
TrySetFromEnv $envMap 'HOSTONLY_MASK'   ([ref]$HostOnlyMask)

# validate inputs (no more "index out of bounds")
ThrowIfFalse (Is-Network24 $Vmnet8Subnet)   "VMNET8_SUBNET is invalid (must be A.B.C.0)."
ThrowIfFalse (Is-IPv4Mask $Vmnet8Mask)      "VMNET8_MASK is invalid."
ThrowIfFalse (Is-IPv4 $Vmnet8HostIp)        "VMNET8_HOSTIP is invalid."
ThrowIfFalse (Is-IPv4 $Vmnet8Gateway)       "VMNET8_GATEWAY is invalid."
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
  ThrowIfFalse (Is-Network24 $s) "Host-only subnet '$s' is invalid (must be A.B.C.0)."
}
ThrowIfFalse (Is-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK is invalid."

$script:VNetLib = Find-VNetLib

# backup
$backup = Join-Path $logDir "vmnet-backup-$ts.txt"
Export-VMnetProfile $backup

# import commands
$importText = Build-ImportCommands -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gateway $Vmnet8Gateway `
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
$import = Join-Path $env:TEMP "soc9000-vmnet-import.txt"
Set-Content -Path $import -Value $importText -Encoding ASCII

if($WhatIf){
  Write-Host "`n[WhatIf] vnetlib import commands to be applied:" -ForegroundColor Cyan
  Write-Host $importText
  Stop-Transcript | Out-Null
  exit 0
}

# stop → import → start
Invoke-VMnet @("stop","dhcp")
Invoke-VMnet @("stop","nat")
Invoke-VMnet @("import",$import)
Invoke-VMnet @("start","dhcp")
Invoke-VMnet @("start","nat")

# ensure services and prune DHCP for host-only nets
foreach($s in @("VMware NAT Service","VMnetDHCP")){
  $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
  if($svc -and $svc.StartType -eq 'Disabled'){ Set-Service -Name $s -StartupType Automatic }
  try{ Start-Service -Name $s -ErrorAction SilentlyContinue }catch{}
}
Prune-HostOnlyDhcp @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet) $HostOnlyMask
try{ Restart-Service "VMnetDHCP" -ErrorAction SilentlyContinue }catch{}

# verify + summary
$rows = Verify-State -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp `
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
Print-Summary -Rows $rows -BackupFile $backup -ImportFile $import
Stop-Transcript | Out-Null
