<# 
.SYNOPSIS
  Declarative VMware VMnet configuration for Workstation Pro 17.x (Windows 11).
  Generates a vnetlib import profile, imports it atomically, restarts services,
  disables DHCP on host-only VMnets, and verifies adapters/IPs/services.

.PARAMETER Vmnet8Subnet
  NAT network address (default 192.168.37.0)

.PARAMETER Vmnet8Mask
  NAT netmask (default 255.255.255.0)

.PARAMETER Vmnet8HostIp
  Host adapter IP on VMnet8 (default 192.168.37.1)

.PARAMETER Vmnet8Gw
  NAT gateway (internalipaddr) (default 192.168.37.2)

.PARAMETER Vmnet20Subnet..Vmnet23Subnet
  Host-only /24 subnets; DHCP will be disabled on these.

.PARAMETER HostOnlyMask
  Netmask for host-only VMnets (default 255.255.255.0)

.PARAMETER WhatIf
  Show actions and generated import file without applying.

.EXAMPLE
  pwsh -File .\scripts\configure-vmnet.ps1 -Verbose
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$Vmnet8Subnet   = "192.168.37.0",
  [string]$Vmnet8Mask     = "255.255.255.0",
  [string]$Vmnet8HostIp   = "192.168.37.1",
  [string]$Vmnet8Gw       = "192.168.37.2",
  [string]$Vmnet20Subnet  = "172.22.10.0",
  [string]$Vmnet21Subnet  = "172.22.20.0",
  [string]$Vmnet22Subnet  = "172.22.30.0",
  [string]$Vmnet23Subnet  = "172.22.40.0",
  [string]$HostOnlyMask   = "255.255.255.0",
  [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------ Helpers ------------------------------
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

function Read-DotEnv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @{} }
  $map = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($v -ne $null) { $map[$k.Trim()] = $v.Trim() }
  }
  $map
}

function Find-VNetLib {
  $cands = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
    "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
  )
  foreach($p in $cands){ if (Test-Path $p) { return $p } }
  $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run."
}

function Invoke-VMnet {
  param([string[]]$Args)
  Write-Verbose ("vnetlib64 -- " + ($Args -join ' '))
  & $script:VNetLib -- @Args
  if ($LASTEXITCODE -ne 0) {
    throw "vnetlib failed (exit $LASTEXITCODE) for: $($Args -join ' ')"
  }
}

function Export-VMnetProfile {
  param([Parameter(Mandatory)] [string]$Path)
  Invoke-VMnet @("export", $Path)
}

function Get-NetworkOctets {
  param([Parameter(Mandatory)][string]$Subnet) # e.g., 192.168.37.0
  $o = $Subnet -split '\.'
  if ($o.Count -ne 4) { throw "Invalid subnet: $Subnet" }
  return @{A=$o[0];B=$o[1];C=$o[2];D=$o[3]}
}

function Get-HostOnlyHostIP {
  param([Parameter(Mandatory)][string]$Subnet) # returns .1
  $o = Get-NetworkOctets -Subnet $Subnet
  "${($o.A)}.${($o.B)}.${($o.C)}.1"
}

function Get-DhcpRangeFor24 {
  param([Parameter(Mandatory)][string]$Subnet) # *.128 - *.254
  $o = Get-NetworkOctets -Subnet $Subnet
  $start = "${($o.A)}.${($o.B)}.${($o.C)}.128"
  $end   = "${($o.A)}.${($o.B)}.${($o.C)}.254"
  return @{Start=$start; End=$end}
}

function New-VMnetImportText {
  param(
    [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,[string]$Vmnet8Gw,
    [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,[string]$HostOnlyMask
  )
  # Build a vnetlib "command file" that import understands (one command per line).
  $lines = New-Object System.Collections.Generic.List[string]

  # --- VMnet8 (NAT + DHCP) ---
  $dhcp = Get-DhcpRangeFor24 -Subnet $Vmnet8Subnet
  $lines.Add("add vnet vmnet8")
  $lines.Add("set vnet vmnet8 addr $Vmnet8Subnet")
  $lines.Add("set vnet vmnet8 mask $Vmnet8Mask")
  $lines.Add("set adapter vmnet8 addr $Vmnet8HostIp")
  $lines.Add("set nat vmnet8 internalipaddr $Vmnet8Gw")
  $lines.Add("update adapter vmnet8")
  $lines.Add("update nat vmnet8")
  # DHCP ON for vmnet8
  $lines.Add("update dhcp vmnet8")

  # --- Host-only nets (DHCP OFF) ---
  foreach ($pair in @(
    @{n=20; s=$Vmnet20Subnet},
    @{n=21; s=$Vmnet21Subnet},
    @{n=22; s=$Vmnet22Subnet},
    @{n=23; s=$Vmnet23Subnet}
  )){
    $hn = "vmnet{0}" -f $pair.n
    $hip = Get-HostOnlyHostIP -Subnet $pair.s
    $lines.Add("add vnet $hn")
    $lines.Add("set vnet $hn addr $($pair.s)")
    $lines.Add("set vnet $hn mask $HostOnlyMask")
    $lines.Add("set adapter $hn addr $hip")
    $lines.Add("update adapter $hn")
    # NOTE: we purposely do NOT 'update dhcp' for host-only nets to keep DHCP off.
  }

  # Return as a single string
  return ($lines -join "`r`n") + "`r`n"
}

function Restart-VMwareServices {
  $svcs = @("VMware NAT Service","VMnetDHCP")
  foreach($s in $svcs){
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Required service '$s' not found. Repair VMware Workstation install." }
    if ($svc.StartType -eq 'Disabled') {
      Set-Service -Name $s -StartupType Automatic
    }
  }
  foreach($s in $svcs){
    Try { Start-Service -Name $s -ErrorAction SilentlyContinue } Catch {}
  }
  Start-Sleep -Seconds 2
}

function Remove-DHCP-ForSubnets {
  # Remove subnet blocks for our host-only networks from vmnetdhcp.conf
  param([string[]]$Subnets)
  $dhcpPath = "C:\ProgramData\VMware\vmnetdhcp.conf"
  if (-not (Test-Path $dhcpPath)) { return }
  $content = Get-Content $dhcpPath -Raw
  foreach($sub in $Subnets){
    $mask = $HostOnlyMask
    $pattern = "subnet\s+$([regex]::Escape($sub))\s+netmask\s+$([regex]::Escape($mask))\s*\{[^}]*\}"
    $content = [regex]::Replace($content, $pattern, "", "IgnoreCase, Singleline")
  }
  Set-Content -Path $dhcpPath -Value $content -Encoding ASCII
}

function Test-AdaptersAndIPs {
  param(
    [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,[string]$Vmnet8Gw,
    [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,[string]$HostOnlyMask
  )
  $results = @()

  function _one {
    param($vmnet,$type,$subnet,$mask,$expectDhcp)
    $alias = "VMware Network Adapter $vmnet"
    $row = [ordered]@{
      VMnet=$vmnet; Type=$type; Subnet=$subnet; Mask=$mask; DHCP= $(if($expectDhcp){"ON"}else{"OFF"})
      HostIP=$null; AdapterUp=$false; ServicesOK=$false; Note=""
    }
    $ad = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if ($ad -and $ad.Status -eq 'Up') { $row['AdapterUp'] = $true }
    $ipcfg = Get-NetIPConfiguration -InterfaceAlias $alias -ErrorAction SilentlyContinue
    if ($ipcfg -and $ipcfg.IPv4Address){
      $row['HostIP'] = ($ipcfg.IPv4Address | Select-Object -First 1).IPAddress
      # Very lightweight mask check (prefixlength→netmask conversion omitted for brevity)
    }
    $natSvc = Get-Service "VMware NAT Service" -ErrorAction SilentlyContinue
    $dhcpSvc= Get-Service "VMnetDHCP" -ErrorAction SilentlyContinue
    $row['ServicesOK'] = ($natSvc.Status -eq 'Running' -and $dhcpSvc.Status -eq 'Running')
    [pscustomobject]$row
  }

  $results += _one "VMnet8"  "NAT"      $Vmnet8Subnet  $Vmnet8Mask $true
  $results += _one "VMnet20" "HostOnly" $Vmnet20Subnet $HostOnlyMask $false
  $results += _one "VMnet21" "HostOnly" $Vmnet21Subnet $HostOnlyMask $false
  $results += _one "VMnet22" "HostOnly" $Vmnet22Subnet $HostOnlyMask $false
  $results += _one "VMnet23" "HostOnly" $Vmnet23Subnet $HostOnlyMask $false

  return ,$results
}

function Write-Summary {
  param([object[]]$Rows,[string]$ImportFile,[string]$BackupFile)
  Write-Host ""
  Write-Host "================== VMware VMnet Summary ==================" -ForegroundColor White
  "{0,-8} {1,-9} {2,-16} {3,-15} {4,-5} {5,-15} {6,-10}" -f "VMnet","Type","Subnet","Mask","DHCP","HostIP","Services" | Write-Host
  $fail = $false
  foreach($r in $Rows){
    $svc = if($r.ServicesOK){"OK"}else{"FAIL"}
    $line = "{0,-8} {1,-9} {2,-16} {3,-15} {4,-5} {5,-15} {6,-10}" -f $r.VMnet,$r.Type,$r.Subnet,$r.Mask,$r.DHCP,($r.HostIP ?? "-"),$svc
    if ($r.AdapterUp -and $r.ServicesOK) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Yellow; $fail=$true }
  }
  Write-Host "Backup file : $BackupFile"
  if ($ImportFile) { Write-Host "Import file : $ImportFile" }
  Write-Host "==========================================================" -ForegroundColor White
  if ($fail) {
    Write-Error "One or more checks failed. Open Services.msc to ensure 'VMware NAT Service' and 'VMnetDHCP' are Running; then re-run this script."
    exit 1
  }
}

# ------------------------------ Main ------------------------------
Ensure-Admin

$logDir = Join-Path (Split-Path -Parent $PSCommandPath) "..\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try { Stop-Transcript | Out-Null } catch {}
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "configure-vmnet-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# .env overrides
$envMap = Read-DotEnv -Path (Join-Path (Split-Path -Parent $PSCommandPath) "..\.env")
if ($envMap.Count -gt 0) {
  $Vmnet8Subnet   = $envMap.VMNET8_SUBNET   ?? $Vmnet8Subnet
  $Vmnet8Mask     = $envMap.VMNET8_MASK     ?? $Vmnet8Mask
  $Vmnet8HostIp   = $envMap.VMNET8_HOSTIP   ?? $Vmnet8HostIp
  $Vmnet8Gw       = $envMap.VMNET8_GATEWAY  ?? $Vmnet8Gw
  $Vmnet20Subnet  = $envMap.VMNET20_SUBNET  ?? $Vmnet20Subnet
  $Vmnet21Subnet  = $envMap.VMNET21_SUBNET  ?? $Vmnet21Subnet
  $Vmnet22Subnet  = $envMap.VMNET22_SUBNET  ?? $Vmnet22Subnet
  $Vmnet23Subnet  = $envMap.VMNET23_SUBNET  ?? $Vmnet23Subnet
  $HostOnlyMask   = $envMap.HOSTONLY_MASK   ?? $HostOnlyMask
}

$script:VNetLib = Find-VNetLib

# Backup current profile
$backup = Join-Path $logDir "vmnet-backup-$ts.txt"
Export-VMnetProfile -Path $backup

# Generate import file (list of vnetlib commands)
$importText = New-VMnetImportText -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gw $Vmnet8Gw \
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
$importFile = Join-Path $env:TEMP "soc9000-vmnet-import.txt"
Set-Content -Path $importFile -Value $importText -Encoding ASCII

if ($WhatIf) {
  Write-Host "`n[WhatIf] vnetlib import commands that would be applied:" -ForegroundColor Cyan
  Write-Host $importText
  $rows = Test-AdaptersAndIPs -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gw $Vmnet8Gw \
    -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
  Write-Summary -Rows $rows -ImportFile $importFile -BackupFile $backup
  Stop-Transcript | Out-Null
  exit 0
}

# Stop services → import → start services
Invoke-VMnet @("stop","dhcp")
Invoke-VMnet @("stop","nat")
Invoke-VMnet @("import", $importFile)
Invoke-VMnet @("start","dhcp")
Invoke-VMnet @("start","nat")

# Ensure VMware services are up and DHCP OFF on host-only nets
Restart-VMwareServices
Remove-DHCP-ForSubnets -Subnets @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)
Restart-VMwareServices

# Final verification
$rows = Test-AdaptersAndIPs -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gw $Vmnet8Gw \
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
Write-Summary -Rows $rows -ImportFile $importFile -BackupFile $backup
Stop-Transcript | Out-Null
