<#
.SYNOPSIS
  Declarative VMware VMnet setup for Workstation Pro 17+ on Windows.

.DESCRIPTION
  Creates/updates VMnet8 (NAT + DHCP) and four Host-only VMnets (IDs configurable),
  imports via vnetlib64, starts services, force-sets adapter IPv4s, verifies state,
  and prints a summary.
  - Default host-only VMnet IDs: 9,10,11,12
  - Override with .env: HOSTONLY_VMNET_IDS=9,10,11,12
  - Logs to INSTALL_ROOT\logs\installation unless -NoTranscript is used.
#>

[CmdletBinding()]
param(
# Addressing (overridable by .env)
    [string]$Vmnet8Subnet   = "192.168.37.0",
    [string]$Vmnet8Mask     = "255.255.255.0",
    [string]$Vmnet8HostIp   = "192.168.37.1",
    [string]$Vmnet8Gateway  = "192.168.37.2",

    [string]$Vmnet20Subnet  = "172.22.10.0",
    [string]$Vmnet21Subnet  = "172.22.20.0",
    [string]$Vmnet22Subnet  = "172.22.30.0",
    [string]$Vmnet23Subnet  = "172.22.40.0",
    [string]$HostOnlyMask   = "255.255.255.0",

# Behavior
    [switch]$Preview,
    [switch]$NoTranscript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- helpers ----------
function Start-AdminElevation {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal $id
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
        $pwshArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
        Start-Process pwsh -Verb RunAs -ArgumentList $pwshArgs | Out-Null
        exit 0
    }
}

function Get-DotEnvMap([string]$Path) {
    if (-not (Test-Path $Path)) { return @{} }
    $m=@{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k,$v = $_ -split '=',2
        if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
    }
    $m
}
function Set-ValueFromEnv([hashtable]$Map,[string]$Key,[ref]$Target) {
    if ($Map.ContainsKey($Key) -and $Map[$Key]) { $Target.Value = $Map[$Key] }
}
function Test-ConditionOrThrow($Cond,[string]$Msg){ if (-not $Cond) { throw $Msg } }

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
    throw "vnetlib64.exe not found. Install VMware Workstation Pro."
}
function Invoke-VMnet {
    [CmdletBinding()]
    param([string[]]$CliArgs,[int[]]$AllowedExitCodes = @(0))
    $exe = Get-VNetLibPath
    $p = Start-Process -FilePath $exe -ArgumentList (@('--') + $CliArgs) -Wait -PassThru
    if ($AllowedExitCodes -notcontains $p.ExitCode) {
        throw "vnetlib64 exited $($p.ExitCode): $($CliArgs -join ' ')"
    }
}

function New-ImportText {
    param(
        [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,[string]$Vmnet8Gateway,
        [string[]]$HostOnlySubnets,[string]$HostOnlyMask,[int[]]$HostOnlyVmnetIds
    )
    $L = @()
    # vmnet8 (NAT + DHCP)
    $L += "add adapter vmnet8"
    $L += "add vnet vmnet8"
    $L += "set vnet vmnet8 addr $Vmnet8Subnet"
    $L += "set vnet vmnet8 mask $Vmnet8Mask"
    $L += "set adapter vmnet8 addr $Vmnet8HostIp"
    $L += "add nat vmnet8"
    $L += "set nat vmnet8 internalipaddr $Vmnet8Gateway"
    $L += "add dhcp vmnet8"
    $L += "update adapter vmnet8"
    $L += "update nat vmnet8"
    $L += "update dhcp vmnet8"
    $L += ""
    # host-only vmnets
    for ($i=0; $i -lt $HostOnlySubnets.Count; $i++) {
        $id  = $HostOnlyVmnetIds[$i]
        $s   = $HostOnlySubnets[$i]
        $hip = Get-HostOnlyGatewayIp $s
        $L += "add adapter vmnet$id"
        $L += "add vnet vmnet$id"
        $L += "set vnet vmnet$id addr $s"
        $L += "set vnet vmnet$id mask $HostOnlyMask"
        $L += "set adapter vmnet$id addr $hip"
        $L += "update adapter vmnet$id"
        $L += ""
    }
    ($L -join "`r`n")
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
    param([string]$Alias,[string]$Ip,[string]$Mask)
    $ad = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
    if (-not $ad) { return }
    $pref = Convert-MaskToPrefixLength $Mask
    # remove any existing IPv4s (including APIPA)
    Get-NetIPAddress -InterfaceAlias $Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { try { Remove-NetIPAddress -InterfaceAlias $Alias -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue } catch {} }
    if ($ad.Status -ne 'Up') { try { Enable-NetAdapter -Name $Alias -Confirm:$false -ErrorAction SilentlyContinue } catch {} }
    try {
        New-NetIPAddress -InterfaceAlias $Alias -IPAddress $Ip -PrefixLength $pref -ErrorAction Stop | Out-Null
    } catch {
        & netsh interface ip set address name="$Alias" static $Ip $Mask
    }
}
function Wait-AdapterUp([string]$Alias,[int]$Seconds=10){
    $deadline=(Get-Date).AddSeconds($Seconds)
    do{
        $ad=Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
        if($ad -and $ad.Status -eq 'Up'){ return $true }
        Start-Sleep -Milliseconds 500
    }while((Get-Date) -lt $deadline)
    $false
}

function Test-VmnetState {
    param(
        [string]$Vmnet8Subnet,[string]$Vmnet8Mask,[string]$Vmnet8HostIp,
        [string]$Vmnet20Subnet,[string]$Vmnet21Subnet,[string]$Vmnet22Subnet,[string]$Vmnet23Subnet,
        [string]$HostOnlyMask,[int[]]$HostOnlyVmnetIds
    )
    $rows = @()

    # NAT row
    $rows += [pscustomobject]@{
        VMnet='VMnet8'; Type='NAT'; Subnet=$Vmnet8Subnet; Mask=$Vmnet8Mask;
        ExpectedIP=$Vmnet8HostIp; ActualIP=''; AdapterUp=$false; ServicesOK=(Test-ServiceStateOk)
    }

    # host-only rows
    $hostOnlySubnets = @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)
    for ($i=0; $i -lt $hostOnlySubnets.Count; $i++) {
        $id = $HostOnlyVmnetIds[$i]
        $rows += [pscustomobject]@{
            VMnet="VMnet$id"; Type='HostOnly'; Subnet=$hostOnlySubnets[$i]; Mask=$HostOnlyMask;
            ExpectedIP=(Get-HostOnlyGatewayIp $hostOnlySubnets[$i]); ActualIP=''; AdapterUp=$false; ServicesOK=(Test-ServiceStateOk)
        }
    }

    # fill dynamic fields
    for ($i=0; $i -lt $rows.Count; $i++) {
        $alias = "VMware Network Adapter $($rows[$i].VMnet)"
        $ad    = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        $ip    = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $rows[$i].ActualIP  = if ($ip) { $ip.IPAddress } else { '' }
        $rows[$i].AdapterUp = ($ad -and $ad.Status -eq 'Up')
    }

    return $rows
}

function Write-VmnetSummary {
    param([object[]]$Rows,[string]$BackupFile,[string]$ImportFile)
    Write-Host ""
    Write-Host "================== VMware VMnet Summary ==================" -ForegroundColor White
    $fmt="{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-15} {6,-8}"
    Write-Host ($fmt -f "VMnet","Type","Subnet","Mask","ExpectedIP","ActualIP","Services")
    $bad=$false
    foreach($r in $Rows){
        $svc=if($r.ServicesOK){"OK"}else{"FAIL"}
        $ok=($r.AdapterUp -and $r.ServicesOK -and ($r.ExpectedIP -eq $r.ActualIP))
        $actual=if($r.ActualIP){$r.ActualIP}else{"-"}
        $line=$fmt -f $r.VMnet,$r.Type,$r.Subnet,$r.Mask,$r.ExpectedIP,$actual,$svc
        if($ok){Write-Host $line -ForegroundColor Green}else{Write-Host $line -ForegroundColor Yellow; $bad=$true}
    }
    if ($BackupFile) { Write-Host "Backup file : $BackupFile" }
    if ($ImportFile) { Write-Host "Import file : $ImportFile" }
    Write-Host "==========================================================" -ForegroundColor White
    if($bad){ throw "One or more checks failed. Validate IPs/masks; ensure 'VMware NAT Service' and 'VMnetDHCP' are Running; then re-run." }
}

# ---------- main ----------
function Invoke-Main {
    Start-AdminElevation

    $ScriptRoot = Split-Path -Parent $PSCommandPath
    $RepoRoot   = (Resolve-Path (Join-Path $ScriptRoot '..')).Path

    $EExists  = Test-Path 'E:\'
    $DefaultInstallRoot = if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path $env:SystemDrive 'SOC-9000-Install' }

    $EnvMap = Get-DotEnvMap (Join-Path $RepoRoot '.env')
    $InstallRoot = if ($EnvMap['INSTALL_ROOT']) { $EnvMap['INSTALL_ROOT'] } else { $DefaultInstallRoot }

    $LogDir = Join-Path $InstallRoot 'logs\installation'
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    # transcript (optional)
    if (-not $NoTranscript) {
        try { Stop-Transcript | Out-Null } catch {}
        $ts  = Get-Date -Format "yyyyMMdd-HHmmss"
        $log = Join-Path $LogDir "configure-vmnet-$ts.log"
        Start-Transcript -Path $log -Force | Out-Null
    } else {
        $ts  = Get-Date -Format "yyyyMMdd-HHmmss"
        $log = $null
    }

    # env overrides
    Set-ValueFromEnv $EnvMap 'VMNET8_SUBNET'   ([ref]$Vmnet8Subnet)
    Set-ValueFromEnv $EnvMap 'VMNET8_MASK'     ([ref]$Vmnet8Mask)
    Set-ValueFromEnv $EnvMap 'VMNET8_HOSTIP'   ([ref]$Vmnet8HostIp)
    Set-ValueFromEnv $EnvMap 'VMNET8_GATEWAY'  ([ref]$Vmnet8Gateway)
    Set-ValueFromEnv $EnvMap 'VMNET20_SUBNET'  ([ref]$Vmnet20Subnet)
    Set-ValueFromEnv $EnvMap 'VMNET21_SUBNET'  ([ref]$Vmnet21Subnet)
    Set-ValueFromEnv $EnvMap 'VMNET22_SUBNET'  ([ref]$Vmnet22Subnet)
    Set-ValueFromEnv $EnvMap 'VMNET23_SUBNET'  ([ref]$Vmnet23Subnet)
    Set-ValueFromEnv $EnvMap 'HOSTONLY_MASK'   ([ref]$HostOnlyMask)

    # host-only VMnet IDs from .env or default 9-12
    [int[]]$HostOnlyVmnetIds = @()
    if ($EnvMap.ContainsKey('HOSTONLY_VMNET_IDS') -and $EnvMap['HOSTONLY_VMNET_IDS']) {
        $HostOnlyVmnetIds = $EnvMap['HOSTONLY_VMNET_IDS'] -split ',' | ForEach-Object { [int]($_.Trim()) }
    } else {
        $HostOnlyVmnetIds = 9,10,11,12
    }

    # validate
    Test-ConditionOrThrow (Test-Network24 $Vmnet8Subnet)    "VMNET8_SUBNET invalid (A.B.C.0)."
    Test-ConditionOrThrow (Test-IPv4Mask  $Vmnet8Mask)      "VMNET8_MASK invalid."
    Test-ConditionOrThrow (Test-IPv4Address $Vmnet8HostIp)  "VMNET8_HOSTIP invalid."
    Test-ConditionOrThrow (Test-IPv4Address $Vmnet8Gateway) "VMNET8_GATEWAY invalid."
    foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
        Test-ConditionOrThrow (Test-Network24 $s) "Host-only subnet '$s' invalid (A.B.C.0)."
    }
    Test-ConditionOrThrow (Test-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK invalid."

    # build import text
    $hostOnlySubnets = @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)
    $importText = New-ImportText -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gateway $Vmnet8Gateway `
                               -HostOnlySubnets $hostOnlySubnets -HostOnlyMask $HostOnlyMask -HostOnlyVmnetIds $HostOnlyVmnetIds

    if ($Preview) {
        Write-Host "`n[Preview] vnetlib import commands to be applied:" -ForegroundColor Cyan
        Write-Host $importText
        if (-not $NoTranscript) { Stop-Transcript | Out-Null }
        return
    }

    $importFile = Join-Path $env:TEMP "soc9000-vmnet-import.txt"
    Set-Content -Path $importFile -Value $importText -Encoding ASCII

    # backup current
    $backup = if ($log) { Join-Path $LogDir "vmnet-backup-$ts.txt" } else { $null }
    try { if ($backup) { Invoke-VMnet -CliArgs @('export',$backup) -AllowedExitCodes @(0,1) } } catch { Write-Warning "Backup export failed: $($_.Exception.Message)" }

    # stop -> import -> start (tolerate 0/1 on stop/import in case nothing running yet)
    Invoke-VMnet -CliArgs @('stop','dhcp')          -AllowedExitCodes @(0,1)
    Invoke-VMnet -CliArgs @('stop','nat')           -AllowedExitCodes @(0,1)
    Invoke-VMnet -CliArgs @('import',"$importFile") -AllowedExitCodes @(0,1)
    Invoke-VMnet -CliArgs @('start','dhcp')         -AllowedExitCodes @(0,1)
    Invoke-VMnet -CliArgs @('start','nat')          -AllowedExitCodes @(0,1)

    # services up
    Start-VMwareNetworkServices

    # force adapter IPs (handles APIPA)
    Set-AdapterIPv4 -Alias "VMware Network Adapter VMnet8" -Ip $Vmnet8HostIp -Mask $Vmnet8Mask
    for ($i=0; $i -lt $hostOnlySubnets.Count; $i++) {
        $id = $HostOnlyVmnetIds[$i]
        $ip = Get-HostOnlyGatewayIp $hostOnlySubnets[$i]
        Set-AdapterIPv4 -Alias "VMware Network Adapter VMnet$id" -Ip $ip -Mask $HostOnlyMask
    }
    Wait-AdapterUp "VMware Network Adapter VMnet8" 10 | Out-Null

    # prune DHCP scopes created by host-only adapters, then bounce DHCP
    Remove-HostOnlyDhcpScopes $hostOnlySubnets $HostOnlyMask
    try { Restart-Service "VMnetDHCP" -ErrorAction SilentlyContinue } catch {}

    # verify + summary
    $rows = Test-VmnetState -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp `
                          -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet `
                          -HostOnlyMask $HostOnlyMask -HostOnlyVmnetIds $HostOnlyVmnetIds
    Write-VmnetSummary -Rows $rows -BackupFile $backup -ImportFile $importFile

    if (-not $NoTranscript) { Stop-Transcript | Out-Null }
}

Invoke-Main