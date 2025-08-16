<#
.SYNOPSIS
  Declarative VMware VMnet setup for Workstation Pro 17+ on Windows.

.DESCRIPTION
  Builds a vnetlib64 import profile that CREATES adapters, stops services,
  imports the profile, restarts services, prunes host-only DHCP scopes,
  forces adapter IPv4 addresses, verifies adapters/IPs/services, and prints a summary.
  ASCII-only; PS 5.1 and 7+ compatible.
#>

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

    [switch]$Preview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- helpers ----------

function Start-AdminElevation {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal $id
    $isAdmin = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
        $pwshArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
        Start-Process pwsh -Verb RunAs -ArgumentList $pwshArgs | Out-Null
        exit 0
    }
}

function Get-DotEnvMap([string]$Path) {
    if (-not (Test-Path $Path)) { return @{} }
    $m = @{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k,$v = $_ -split '=',2
        if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
    }
    return $m
}
function Set-ValueFromEnv([hashtable]$Map,[string]$Key,[ref]$Target) {
    if ($Map.ContainsKey($Key) -and $Map[$Key]) { $Target.Value = $Map[$Key] }
}
function Test-ConditionOrThrow($Cond,[string]$Message){ if (-not $Cond) { throw $Message } }

function Test-IPv4Address([string]$Ip){
    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach($oct in $Ip -split '\.'){ if([int]$oct -gt 255){ return $false } }
    return $true
}
function Test-IPv4Mask([string]$Mask){
    if (-not (Test-IPv4Address $Mask)) { return $false }
    $bytes=[Net.IPAddress]::Parse($Mask).GetAddressBytes()
    $bits = ($bytes | ForEach-Object { [Convert]::ToString($_,2).PadLeft(8,'0') }) -join ''
    return ($bits -notmatch '01')
}
function Test-Network24([string]$Subnet){
    if (-not (Test-IPv4Address $Subnet)) { return $false }
    $oct = $Subnet -split '\.'
    return ($oct[3] -eq '0')
}
function Get-HostOnlyGatewayIp([string]$Subnet){
    $o = $Subnet -split '\.'; "$($o[0]).$($o[1]).$($o[2]).1"
}

function Get-VNetLibPath {
    foreach ($p in @(
        "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe",
        "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe"
    )) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "vnetlib64.exe not found. Install VMware Workstation Pro (with Virtual Network Editor)."
}
function Invoke-VMnet {
    [CmdletBinding()]
    param(
        [string[]]$CliArgs,
        [int[]]$AllowedExitCodes = @(0)
    )
    $exe = Get-VNetLibPath
    $p = Start-Process -FilePath $exe -ArgumentList (@('--') + $CliArgs) -Wait -PassThru
    if ($AllowedExitCodes -notcontains $p.ExitCode) {
        throw "vnetlib64 exited $($p.ExitCode): $($CliArgs -join ' ')"
    }
}

function New-ImportText {
    param(
        [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,[string]$Vmnet8Gateway,
        [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,[string]$HostOnlyMask
    )
    $lines = @()

    # vmnet8: NAT + DHCP (create then update)
    $lines += "add adapter vmnet8"
    $lines += "add vnet vmnet8"
    $lines += "set vnet vmnet8 addr $Vmnet8Subnet"
    $lines += "set vnet vmnet8 mask $Vmnet8Mask"
    $lines += "set adapter vmnet8 addr $Vmnet8HostIp"
    $lines += "add nat vmnet8"
    $lines += "set nat vmnet8 internalipaddr $Vmnet8Gateway"
    $lines += "add dhcp vmnet8"
    $lines += "update adapter vmnet8"
    $lines += "update nat vmnet8"
    $lines += "update dhcp vmnet8"
    $lines += ""

    # host-only: adapters created explicitly; no DHCP
    foreach($def in @(
        @{n=20;s=$Vmnet20Subnet},
        @{n=21;s=$Vmnet21Subnet},
        @{n=22;s=$Vmnet22Subnet},
        @{n=23;s=$Vmnet23Subnet}
    )) {
        $hn  = "vmnet$($def.n)"
        $hip = Get-HostOnlyGatewayIp $def.s
        $lines += "add adapter $hn"
        $lines += "add vnet $hn"
        $lines += "set vnet $hn addr $($def.s)"
        $lines += "set vnet $hn mask $HostOnlyMask"
        $lines += "set adapter $hn addr $hip"
        $lines += "update adapter $hn"
        $lines += ""
    }

    return ($lines -join "`r`n")
}

function Remove-HostOnlyDhcpScopes([string[]]$Subnets,[string]$Mask){
    $dhcp="C:\ProgramData\VMware\vmnetdhcp.conf"
    if (-not (Test-Path $dhcp)) { return }
    $raw = Get-Content $dhcp -Raw
    foreach($s in $Subnets){
        $pat = "subnet\s+$([regex]::Escape($s))\s+netmask\s+$([regex]::Escape($Mask))\s*\{[^}]*\}"
        $raw = [regex]::Replace($raw,$pat,"","Singleline,IgnoreCase")
    }
    Set-Content -Path $dhcp -Value $raw -Encoding ASCII
}

function Test-ServiceStateOk {
    $n = Get-Service "VMware NAT Service" -ErrorAction SilentlyContinue
    $d = Get-Service "VMnetDHCP" -ErrorAction SilentlyContinue
    return ($n -and $d -and $n.Status -eq 'Running' -and $d.Status -eq 'Running')
}
function Start-VMwareNetworkServices {
    $pairs = @(
        @('VMnetNatSvc','VMware NAT Service'),
        @('VMnetDHCP',  'VMware DHCP Service')
    )
    foreach ($pair in $pairs) {
        $svc = Get-Service -Name $pair[0] -ErrorAction SilentlyContinue
        if (-not $svc) { $svc = Get-Service -DisplayName $pair[1] -ErrorAction SilentlyContinue }
        if ($svc -and $svc.Status -ne 'Running') {
            try { Start-Service $svc -ErrorAction Stop } catch { Write-Warning "Failed to start '$($svc.Name)': $($_.Exception.Message)" }
        }
    }
}

function Convert-MaskToPrefixLength([string]$Mask){
    $bytes=[Net.IPAddress]::Parse($Mask).GetAddressBytes()
    $bits = ($bytes | ForEach-Object { [Convert]::ToString($_,2).PadLeft(8,'0') }) -join ''
    ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}
function Set-AdapterIPv4 {
    [CmdletBinding()]
    param([string]$Alias,[string]$IpAddress,[string]$Mask)

    $ad = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
    if (-not $ad) { return }

    $prefix = Convert-MaskToPrefixLength $Mask

    $has = Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $IpAddress }
    if ($has) { return }

    # remove existing v4s (including APIPA) and apply static
    Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { try { Remove-NetIPAddress -InterfaceAlias $Alias -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue } catch {} }

    if ($ad.Status -ne 'Up') {
        try { Enable-NetAdapter -Name $Alias -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    }

    try {
        New-NetIPAddress -InterfaceAlias $Alias -IPAddress $IpAddress -PrefixLength $prefix -ErrorAction Stop | Out-Null
    } catch {
        # fallback to netsh if needed
        & netsh interface ip set address name="$Alias" static $IpAddress $Mask
    }
}
function Wait-AdapterUp([string]$Alias,[int]$Seconds = 10){
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $ad = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
        if ($ad -and $ad.Status -eq 'Up') { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Test-VmnetState {
    param(
        [string]$Vmnet8Subnet, [string]$Vmnet8Mask, [string]$Vmnet8HostIp,
        [string]$Vmnet20Subnet, [string]$Vmnet21Subnet, [string]$Vmnet22Subnet, [string]$Vmnet23Subnet, [string]$HostOnlyMask
    )
    $rows = @()

    $targets = @(
        @{ V='VMnet8';  T='NAT';      S=$Vmnet8Subnet;  M=$Vmnet8Mask;   IP=$Vmnet8HostIp },
        @{ V='VMnet20'; T='HostOnly'; S=$Vmnet20Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet20Subnet) },
        @{ V='VMnet21'; T='HostOnly'; S=$Vmnet21Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet21Subnet) },
        @{ V='VMnet22'; T='HostOnly'; S=$Vmnet22Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet22Subnet) },
        @{ V='VMnet23'; T='HostOnly'; S=$Vmnet23Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet23Subnet) }
    )

    foreach ($row in $targets) {
        $alias  = "VMware Network Adapter $($row.V)"
        $ad     = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        $ipObj  = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1

        $rows += [pscustomobject]@{
        VMnet      = $row.V
        Type       = $row.T
        Subnet     = $row.S
        Mask       = $row.M
        ExpectedIP = $row.IP
        ActualIP   = (if ($ipObj) { $ipObj.IPAddress } else { '' })
        AdapterUp  = ($ad -and $ad.Status -eq 'Up')
        ServicesOK = (Test-ServiceStateOk)
    }
}

return $rows
}

function Write-VmnetSummary {
param([object[]]$Rows,[string]$BackupFile,[string]$ImportFile)
Write-Host ""
Write-Host "================== VMware VMnet Summary ==================" -ForegroundColor White
$headerFmt = "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-15} {6,-8}"
$lineFmt   = "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-15} {6,-8}"
Write-Host ($headerFmt -f "VMnet","Type","Subnet","Mask","ExpectedIP","ActualIP","Services")
$bad = $false
foreach($r in $Rows){
$svc    = if ($r.ServicesOK) { "OK" } else { "FAIL" }
$okLine = ($r.AdapterUp -and $r.ServicesOK -and ($r.ExpectedIP -eq $r.ActualIP))
$actual = if ($r.ActualIP) { $r.ActualIP } else { "-" }
$line   = $lineFmt -f $r.VMnet,$r.Type,$r.Subnet,$r.Mask,$r.ExpectedIP,$actual,$svc
if ($okLine) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Yellow; $bad = $true }
}
Write-Host "Backup file : $BackupFile"
Write-Host "Import file : $ImportFile"
Write-Host "==========================================================" -ForegroundColor White
if ($bad) { throw "One or more checks failed. Validate .env IPs/masks; ensure 'VMware NAT Service' and 'VMnetDHCP' are Running; then re-run." }
}

# ---------- main ----------

Start-AdminElevation

$ScriptRoot = Split-Path -Parent $PSCommandPath
$RepoRoot   = (Resolve-Path (Join-Path $ScriptRoot '..')).Path

$EExists  = Test-Path 'E:\'
$DefaultInstallRoot = if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path $env:SystemDrive 'SOC-9000-Install' }

$EnvMap = Get-DotEnvMap (Join-Path $RepoRoot '.env')
$InstallRoot = if ($EnvMap['INSTALL_ROOT']) { $EnvMap['INSTALL_ROOT'] } else { $DefaultInstallRoot }

$LogDir = Join-Path $InstallRoot 'logs\installation'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

try { Stop-Transcript | Out-Null } catch {}
$ts  = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $LogDir "configure-vmnet-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# .env overrides
Set-ValueFromEnv $EnvMap 'VMNET8_SUBNET'   ([ref]$Vmnet8Subnet)
Set-ValueFromEnv $EnvMap 'VMNET8_MASK'     ([ref]$Vmnet8Mask)
Set-ValueFromEnv $EnvMap 'VMNET8_HOSTIP'   ([ref]$Vmnet8HostIp)
Set-ValueFromEnv $EnvMap 'VMNET8_GATEWAY'  ([ref]$Vmnet8Gateway)
Set-ValueFromEnv $EnvMap 'VMNET20_SUBNET'  ([ref]$Vmnet20Subnet)
Set-ValueFromEnv $EnvMap 'VMNET21_SUBNET'  ([ref]$Vmnet21Subnet)
Set-ValueFromEnv $EnvMap 'VMNET22_SUBNET'  ([ref]$Vmnet22Subnet)
Set-ValueFromEnv $EnvMap 'VMNET23_SUBNET'  ([ref]$Vmnet23Subnet)
Set-ValueFromEnv $EnvMap 'HOSTONLY_MASK'   ([ref]$HostOnlyMask)

# Validate
Test-ConditionOrThrow (Test-Network24 $Vmnet8Subnet)    "VMNET8_SUBNET is invalid (must be A.B.C.0)."
Test-ConditionOrThrow (Test-IPv4Mask  $Vmnet8Mask)      "VMNET8_MASK is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8HostIp)  "VMNET8_HOSTIP is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8Gateway) "VMNET8_GATEWAY is invalid."
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
Test-ConditionOrThrow (Test-Network24 $s) "Host-only subnet '$s' is invalid (must be A.B.C.0)."
}
Test-ConditionOrThrow (Test-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK is invalid."

# Build/preview import
$importText = New-ImportText -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gateway $Vmnet8Gateway -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
if ($Preview) {
Write-Host ""
Write-Host "[Preview only] vnetlib import commands that would be applied:" -ForegroundColor Cyan
Write-Host $importText
Stop-Transcript | Out-Null
exit 0
}

$importFile = Join-Path $env:TEMP "soc9000-vmnet-import.txt"
Set-Content -Path $importFile -Value $importText -Encoding ASCII

# Backup profile (warn only)
$backup = Join-Path $LogDir "vmnet-backup-$ts.txt"
try { Invoke-VMnet -CliArgs @('export',$backup) -AllowedExitCodes @(0,1) } catch { Write-Warning "Backup export failed: $($_.Exception.Message)" }

# Stop -> Import -> Start (tolerate exit code 1 on stop/import)
Invoke-VMnet -CliArgs @('stop','dhcp')          -AllowedExitCodes @(0,1)
Invoke-VMnet -CliArgs @('stop','nat')           -AllowedExitCodes @(0,1)
Invoke-VMnet -CliArgs @('import',"$importFile") -AllowedExitCodes @(0,1)
Invoke-VMnet -CliArgs @('start','dhcp')         -AllowedExitCodes @(0,1)
Invoke-VMnet -CliArgs @('start','nat')          -AllowedExitCodes @(0,1)

# Start services
Start-VMwareNetworkServices

# Force adapter IPs (handles APIPA cases after import)
Set-AdapterIPv4 -Alias "VMware Network Adapter VMnet8" -IpAddress $Vmnet8HostIp -Mask $Vmnet8Mask
foreach ($item in @(
@{Alias="VMware Network Adapter VMnet20"; Subnet=$Vmnet20Subnet},
@{Alias="VMware Network Adapter VMnet21"; Subnet=$Vmnet21Subnet},
@{Alias="VMware Network Adapter VMnet22"; Subnet=$Vmnet22Subnet},
@{Alias="VMware Network Adapter VMnet23"; Subnet=$Vmnet23Subnet}
)) {
$hip = Get-HostOnlyGatewayIp $item.Subnet
Set-AdapterIPv4 -Alias $item.Alias -IpAddress $hip -Mask $HostOnlyMask
}

# Give Windows a moment to settle links
Wait-AdapterUp "VMware Network Adapter VMnet8" 10 | Out-Null

# Prune DHCP scopes for host-only nets then bounce DHCP service
Remove-HostOnlyDhcpScopes @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet) $HostOnlyMask
try { Restart-Service "VMnetDHCP" -ErrorAction SilentlyContinue } catch {}

# Verify + summarize
$rows = Test-VmnetState -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
Write-VmnetSummary -Rows $rows -BackupFile $backup -ImportFile $importFile
Stop-Transcript | Out-Null