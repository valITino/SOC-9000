<# 
.SYNOPSIS
  Declarative VMware VMnet configuration for Workstation Pro 17.x on Windows 11.
.DESCRIPTION
  Backs up the existing Virtual Network configuration, generates a vnetlib
  import command file from desired parameters (or .env overrides), imports it
  atomically via vnetlib64.exe, restarts NAT/DHCP, disables DHCP on host-only
  VMnets (20–23), and verifies adapters/services.
#>
# CmdletBinding without SupportsShouldProcess to avoid duplicate WhatIf
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
  [string]$HostOnlyMask   = "255.255.255.0",
  [switch]$WhatIf
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

function Read-DotEnv([string]$Path) {
  if (-not (Test-Path $Path)) { return @{} }
  $m=@{}; Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($v -ne $null){ $m[$k.Trim()]=$v.Trim() }
  }; $m
}

function Find-VNetLib {
  foreach($p in @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
    "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
  )){ if(Test-Path $p){ return $p } }
  $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run."
}

function Invoke-VMnet([string[]]$Args) {
  Write-Verbose ("vnetlib64 -- " + ($Args -join ' '))
  & $script:VNetLib -- @Args
  if ($LASTEXITCODE -ne 0) { throw "vnetlib failed ($LASTEXITCODE): $($Args -join ' ')" }
}

function HostOnlyIP([string]$Subnet) { $o = $Subnet -split '\.'; "$($o[0]).$($o[1]).$($o[2]).1" }

function Build-ImportCommands {
  param(
    [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,[string]$Vmnet8Gateway,
    [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,[string]$HostOnlyMask
  )
  $L = New-Object System.Collections.Generic.List[string]

  # VMnet8 NAT
  $L.Add("add vnet vmnet8")
  $L.Add("set vnet vmnet8 addr $Vmnet8Subnet")
  $L.Add("set vnet vmnet8 mask $Vmnet8Mask")
  $L.Add("set adapter vmnet8 addr $Vmnet8HostIp")
  $L.Add("set nat vmnet8 internalipaddr $Vmnet8Gateway")
  $L.Add("update adapter vmnet8")
  $L.Add("update nat vmnet8")
  $L.Add("update dhcp vmnet8")   # enable DHCP for NAT network

  foreach($def in @(
    @{n=20;s=$Vmnet20Subnet},
    @{n=21;s=$Vmnet21Subnet},
    @{n=22;s=$Vmnet22Subnet},
    @{n=23;s=$Vmnet23Subnet}
  )){
    $hn = "vmnet$($def.n)"
    $hip = HostOnlyIP $def.s
    $L.Add("add vnet $hn")
    $L.Add("set vnet $hn addr $($def.s)")
    $L.Add("set vnet $hn mask $HostOnlyMask")
    $L.Add("set adapter $hn addr $hip")
    $L.Add("update adapter $hn")
    # do NOT 'update dhcp' to keep DHCP OFF on host-only nets
  }
  ($L -join "`r`n") + "`r`n"
}

function Prune-HostOnlyDhcp([string[]]$Subnets,[string]$Mask){
  $dhcp = "C:\ProgramData\VMware\vmnetdhcp.conf"
  if (-not (Test-Path $dhcp)) { return }
  $raw = Get-Content $dhcp -Raw
  foreach($s in $Subnets){
    $pat = "subnet\s+$([regex]::Escape($s))\s+netmask\s+$([regex]::Escape($Mask))\s*\{[^}]*\}"
    $raw = [regex]::Replace($raw,$pat,"","Singleline,IgnoreCase")
  }
  Set-Content -Path $dhcp -Value $raw -Encoding ASCII
}

function Test-SvcsOk { 
  $n = Get-Service "VMware NAT Service" -ErrorAction SilentlyContinue
  $d = Get-Service "VMnetDHCP" -ErrorAction SilentlyContinue
  if (-not $n -or -not $d){ return $false }
  return ($n.Status -eq 'Running' -and $d.Status -eq 'Running')
}

function Verify-State {
  param(
    [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,[string]$Vmnet8Gateway,
    [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,[string]$HostOnlyMask
  )
  $rows=@()
  foreach($row in @(
    @{V="VMnet8";  T="NAT";      S=$Vmnet8Subnet;  M=$Vmnet8Mask},
    @{V="VMnet20"; T="HostOnly"; S=$Vmnet20Subnet; M=$HostOnlyMask},
    @{V="VMnet21"; T="HostOnly"; S=$Vmnet21Subnet; M=$HostOnlyMask},
    @{V="VMnet22"; T="HostOnly"; S=$Vmnet22Subnet; M=$HostOnlyMask},
    @{V="VMnet23"; T="HostOnly"; S=$Vmnet23Subnet; M=$HostOnlyMask}
  )){
    $alias = "VMware Network Adapter $($row.V)"
    $ad = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    $ip = (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $rows += [pscustomobject]@{
      VMnet=$row.V; Type=$row.T; Subnet=$row.S; Mask=$row.M;
      AdapterUp = ($ad -and $ad.Status -eq 'Up');
      HostIP = $ip;
      ServicesOK = (Test-SvcsOk)
    }
  }
  $rows
}

function Print-Summary([object[]]$Rows,[string]$BackupFile,[string]$ImportFile){
  Write-Host "`n================== VMware VMnet Summary ==================" -ForegroundColor White
  "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-8}" -f "VMnet","Type","Subnet","Mask","HostIP","Services" | Write-Host
  $bad=$false
  foreach($r in $Rows){
    $svc = if($r.ServicesOK){"OK"}else{"FAIL"}
    $line = "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-8}" -f $r.VMnet,$r.Type,$r.Subnet,$r.Mask,($r.HostIP ?? "-"),$svc
    if($r.AdapterUp -and $r.ServicesOK){ Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Yellow; $bad=$true }
  }
  Write-Host "Backup file : $BackupFile"
  Write-Host "Import file : $ImportFile"
  Write-Host "==========================================================" -ForegroundColor White
  if ($bad){ throw "One or more checks failed. Ensure 'VMware NAT Service' and 'VMnetDHCP' are Running and adapters are Up, then re-run." }
}

# ------------------------ Main ------------------------
Ensure-Admin

$root = Split-Path -Parent $PSCommandPath
$logDir = Join-Path $root "..\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try{ Stop-Transcript | Out-Null }catch{}
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "configure-vmnet-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# .env overrides
$envMap = Read-DotEnv (Join-Path $root "..\.env")
$Vmnet8Subnet  = $envMap.VMNET8_SUBNET  ?? $Vmnet8Subnet
$Vmnet8Mask    = $envMap.VMNET8_MASK    ?? $Vmnet8Mask
$Vmnet8HostIp  = $envMap.VMNET8_HOSTIP  ?? $Vmnet8HostIp
$Vmnet8Gateway = $envMap.VMNET8_GATEWAY ?? $Vmnet8Gateway
$Vmnet20Subnet = $envMap.VMNET20_SUBNET ?? $Vmnet20Subnet
$Vmnet21Subnet = $envMap.VMNET21_SUBNET ?? $Vmnet21Subnet
$Vmnet22Subnet = $envMap.VMNET22_SUBNET ?? $Vmnet22Subnet
$Vmnet23Subnet = $envMap.VMNET23_SUBNET ?? $Vmnet23Subnet
$HostOnlyMask  = $envMap.HOSTONLY_MASK  ?? $HostOnlyMask

$script:VNetLib = Find-VNetLib

# Backup
$backup = Join-Path $logDir "vmnet-backup-$ts.txt"
Invoke-VMnet @("export",$backup)

# Build import command file
$importText = Build-ImportCommands -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gateway $Vmnet8Gateway \
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
$import = Join-Path $env:TEMP "soc9000-vmnet-import.txt"
Set-Content -Path $import -Value $importText -Encoding ASCII

if ($WhatIf) {
  Write-Host "`n[WhatIf] vnetlib import commands:" -ForegroundColor Cyan
  Write-Host $importText
  Stop-Transcript | Out-Null
  exit 0
}

# Stop → import → start
Invoke-VMnet @("stop","dhcp")
Invoke-VMnet @("stop","nat")
Invoke-VMnet @("import",$import)
Invoke-VMnet @("start","dhcp")
Invoke-VMnet @("start","nat")

# Ensure services started and DHCP pruned for host-only nets
foreach($s in @("VMware NAT Service","VMnetDHCP")){
  $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
  if ($svc -and $svc.StartType -eq 'Disabled'){ Set-Service -Name $s -StartupType Automatic }
  Try{ Start-Service -Name $s -ErrorAction SilentlyContinue }Catch{}
}
Prune-HostOnlyDhcp @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet) $HostOnlyMask
Try{ Restart-Service "VMnetDHCP" -ErrorAction SilentlyContinue }Catch{}

# Verify
$rows = Verify-State -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gateway $Vmnet8Gateway \
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
Print-Summary -Rows $rows -BackupFile $backup -ImportFile $import
Stop-Transcript | Out-Null
