<#
.SYNOPSIS
  Declarative VMware VMnet setup for Workstation Pro 17.x (Windows 11).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
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

# --- helpers (approved verbs) ---

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
    $m = @{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k, $v = $_ -split '=', 2
        if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
    }
    return $m
}

function Set-ValueFromEnv([hashtable]$EnvMap, [string]$Key, [ref]$Target) {
    if ($EnvMap.ContainsKey($Key) -and $EnvMap[$Key]) { $Target.Value = $EnvMap[$Key] }
}

function Test-ConditionOrThrow($Cond, [string]$Message) { if (-not $Cond) { throw $Message } }

function Test-IPv4Address([string]$Ip) {
    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($oct in $Ip -split '\.') { if ([int]$oct -gt 255) { return $false } }
    return $true
}

function Test-IPv4Mask([string]$Mask) {
    if (-not (Test-IPv4Address $Mask)) { return $false }
    $bytes = [Net.IPAddress]::Parse($Mask).GetAddressBytes()
    $bits  = ($bytes | ForEach-Object { [Convert]::ToString($_,2).PadLeft(8,'0') }) -join ''
    return ($bits -notmatch '01')
}

function Test-Network24([string]$Subnet) {
    if (-not (Test-IPv4Address $Subnet)) { return $false }
    $oct = $Subnet -split '\.'
    return ($oct[3] -eq '0')
}

function Get-HostOnlyGatewayIp([string]$Subnet) {
    $oct = $Subnet -split '\.'; "$($oct[0]).$($oct[1]).$($oct[2]).1"
}

function Get-VNetLibPath {
    foreach ($p in @(
        "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
        "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
    )) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run."
}

function Invoke-VMnet([string[]]$CliArgs) {
    Write-Verbose ("vnetlib64 -- " + ($CliArgs -join ' '))
    $p = Start-Process -FilePath $script:VNetLib -ArgumentList @('--') + $CliArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "vnetlib failed ($($p.ExitCode)): $($CliArgs -join ' ')" }
}

function Export-VMnetProfile([string]$Path) { Invoke-VMnet @('export', $Path) }

function New-ImportCommands {
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
    foreach ($def in @(
        @{ n = 20; s = $Vmnet20Subnet },
        @{ n = 21; s = $Vmnet21Subnet },
        @{ n = 22; s = $Vmnet22Subnet },
        @{ n = 23; s = $Vmnet23Subnet }
    )) {
        $hn  = "vmnet$($def.n)"; $hip = Get-HostOnlyGatewayIp $def.s
        $L.Add("add vnet $hn")
        $L.Add("set vnet $hn addr $($def.s)")
        $L.Add("set vnet $hn mask $HostOnlyMask")
        $L.Add("set adapter $hn addr $hip")
        $L.Add("update adapter $hn")
    }
    ($L -join "`r`n") + "`r`n"
}

function Remove-HostOnlyDhcpScopes([string[]]$Subnets, [string]$Mask) {
    $dhcp = "C:\ProgramData\VMware\vmnetdhcp.conf"
    if (-not (Test-Path $dhcp)) { return }
    $raw = Get-Content $dhcp -Raw
    foreach ($s in $Subnets) {
        $pat = "subnet\s+$([regex]::Escape($s))\s+netmask\s+$([regex]::Escape($Mask))\s*\{[^}]*\}"
        $raw = [regex]::Replace($raw, $pat, "", "Singleline,IgnoreCase")
    }
    Set-Content -Path $dhcp -Value $raw -Encoding ASCII
}

function Test-ServiceStateOk {
    $n = Get-Service "VMware NAT Service" -ErrorAction SilentlyContinue
    $d = Get-Service "VMnetDHCP" -ErrorAction SilentlyContinue
    return ($n -and $d -and $n.Status -eq 'Running' -and $d.Status -eq 'Running')
}

function Test-VmnetState {
    param(
        [string]$Vmnet8Subnet, [string]$Vmnet8Mask, [string]$Vmnet8HostIp,
        [string]$Vmnet20Subnet, [string]$Vmnet21Subnet, [string]$Vmnet22Subnet, [string]$Vmnet23Subnet,
        [string]$HostOnlyMask
    )
    $rows = @()

    $targets = @(
        @{ V='VMnet8';  T='NAT';      S=$Vmnet8Subnet;  M=$Vmnet8Mask;   IP=$Vmnet8HostIp }
        @{ V='VMnet20'; T='HostOnly'; S=$Vmnet20Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet20Subnet) }
        @{ V='VMnet21'; T='HostOnly'; S=$Vmnet21Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet21Subnet) }
        @{ V='VMnet22'; T='HostOnly'; S=$Vmnet22Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet22Subnet) }
        @{ V='VMnet23'; T='HostOnly'; S=$Vmnet23Subnet; M=$HostOnlyMask; IP=(Get-HostOnlyGatewayIp $Vmnet23Subnet) }
    )

    foreach ($row in $targets) {
        $alias   = "VMware Network Adapter $($row.V)"
        $ad      = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        $ipObj   = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $actual  = if ($ipObj) { $ipObj.IPAddress } else { '' }

        $rows += [pscustomobject]@{
            VMnet      = $row.V
            Type       = $row.T
            Subnet     = $row.S
            Mask       = $row.M
            ExpectedIP = $row.IP
            ActualIP   = $actual
            AdapterUp  = ($ad -and $ad.Status -eq 'Up')
            ServicesOK = (Test-ServiceStateOk)
        }
    }

    return $rows
}

function Write-VmnetSummary([object[]]$Rows, [string]$BackupFile, [string]$ImportFile) {
    Write-Host "`n================== VMware VMnet Summary ==================" -ForegroundColor White
    "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-15} {6,-8}" -f "VMnet","Type","Subnet","Mask","ExpectedIP","ActualIP","Services" | Write-Host
    $bad = $false
    foreach ($r in $Rows) {
        $svc    = if ($r.ServicesOK) { "OK" } else { "FAIL" }
        $okLine = ($r.AdapterUp -and $r.ServicesOK -and ($r.ExpectedIP -eq $r.ActualIP))
        $actual = if ($r.ActualIP) { $r.ActualIP } else { '-' }
        $line   = "{0,-8} {1,-9} {2,-16} {3,-15} {4,-15} {5,-15} {6,-8}" -f $r.VMnet,$r.Type,$r.Subnet,$r.Mask,$r.ExpectedIP,$actual,$svc
        if ($okLine) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Yellow; $bad = $true }
    }
    Write-Host "Backup file : $BackupFile"
    Write-Host "Import file : $ImportFile"
    Write-Host "==========================================================" -ForegroundColor White
    if ($bad) { throw "One or more checks failed. Validate .env IPs/masks, ensure 'VMware NAT Service' and 'VMnetDHCP' are Running, then re-run." }
}

# --- main ---

Start-AdminElevation

$root     = Split-Path -Parent $PSCommandPath
$RepoRoot = (Resolve-Path (Join-Path $root '..')).Path

# InstallRoot & log dir under SOC-9000-Install
$EExists  = Test-Path 'E:\'
$DefaultInstallRoot = $(if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path $env:SystemDrive 'SOC-9000-Install' })
$envMap = Get-DotEnvMap (Join-Path $RepoRoot '.env')

$InstallRoot = $DefaultInstallRoot
if ($envMap.ContainsKey('INSTALL_ROOT') -and $envMap['INSTALL_ROOT']) { $InstallRoot = $envMap['INSTALL_ROOT'] }

$logDir = Join-Path $InstallRoot 'logs\installation'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

try { Stop-Transcript | Out-Null } catch {}
$ts  = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "configure-vmnet-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# .env overrides for addressing
Set-ValueFromEnv $envMap 'VMNET8_SUBNET'   ([ref]$Vmnet8Subnet)
Set-ValueFromEnv $envMap 'VMNET8_MASK'     ([ref]$Vmnet8Mask)
Set-ValueFromEnv $envMap 'VMNET8_HOSTIP'   ([ref]$Vmnet8HostIp)
Set-ValueFromEnv $envMap 'VMNET8_GATEWAY'  ([ref]$Vmnet8Gateway)
Set-ValueFromEnv $envMap 'VMNET20_SUBNET'  ([ref]$Vmnet20Subnet)
Set-ValueFromEnv $envMap 'VMNET21_SUBNET'  ([ref]$Vmnet21Subnet)
Set-ValueFromEnv $envMap 'VMNET22_SUBNET'  ([ref]$Vmnet22Subnet)
Set-ValueFromEnv $envMap 'VMNET23_SUBNET'  ([ref]$Vmnet23Subnet)
Set-ValueFromEnv $envMap 'HOSTONLY_MASK'   ([ref]$HostOnlyMask)

# validate inputs
Test-ConditionOrThrow (Test-Network24 $Vmnet8Subnet)     "VMNET8_SUBNET is invalid (must be A.B.C.0)."
Test-ConditionOrThrow (Test-IPv4Mask  $Vmnet8Mask)       "VMNET8_MASK is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8HostIp)   "VMNET8_HOSTIP is invalid."
Test-ConditionOrThrow (Test-IPv4Address $Vmnet8Gateway)  "VMNET8_GATEWAY is invalid."
foreach ($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)) {
    Test-ConditionOrThrow (Test-Network24 $s) "Host-only subnet '$s' is invalid (must be A.B.C.0)."
}
Test-ConditionOrThrow (Test-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK is invalid."

$script:VNetLib = Get-VNetLibPath

# backup to install logs
$backup = Join-Path $logDir "vmnet-backup-$ts.txt"
Export-VMnetProfile $backup

# import commands
$importText = New-ImportCommands -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp -Vmnet8Gateway $Vmnet8Gateway `
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
$import = Join-Path $env:TEMP "soc9000-vmnet-import.txt"
Set-Content -Path $import -Value $importText -Encoding ASCII

if (-not $PSCmdlet.ShouldProcess("VMware VMnet configuration","Apply import commands")) {
    Write-Host "`n[Preview] vnetlib import commands to be applied:" -ForegroundColor Cyan
    Write-Host $importText
    Stop-Transcript | Out-Null
    exit 0
}

# stop → import → start via ExitCode
$p = Start-Process -FilePath $script:VNetLib -ArgumentList '--','stop','dhcp' -Wait -PassThru; if ($p.ExitCode -ne 0) { throw "stop dhcp failed: $($p.ExitCode)" }
$p = Start-Process -FilePath $script:VNetLib -ArgumentList '--','stop','nat'  -Wait -PassThru; if ($p.ExitCode -ne 0) { throw "stop nat failed: $($p.ExitCode)" }
$p = Start-Process -FilePath $script:VNetLib -ArgumentList '--','import',"$import" -Wait -PassThru; if ($p.ExitCode -ne 0) { throw "import failed: $($p.ExitCode)" }
[void](Start-Process -FilePath $script:VNetLib -ArgumentList '--','start','dhcp' -Wait -PassThru)
[void](Start-Process -FilePath $script:VNetLib -ArgumentList '--','start','nat'  -Wait -PassThru)

# prune DHCP for host-only nets
Remove-HostOnlyDhcpScopes @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet) $HostOnlyMask
try { Restart-Service "VMnetDHCP" -ErrorAction SilentlyContinue } catch {}

# verify + summary
$rows = Test-VmnetState -Vmnet8Subnet $Vmnet8Subnet -Vmnet8Mask $Vmnet8Mask -Vmnet8HostIp $Vmnet8HostIp `
  -Vmnet20Subnet $Vmnet20Subnet -Vmnet21Subnet $Vmnet21Subnet -Vmnet22Subnet $Vmnet22Subnet -Vmnet23Subnet $Vmnet23Subnet -HostOnlyMask $HostOnlyMask
Write-VmnetSummary -Rows $rows -BackupFile $backup -ImportFile $import

Stop-Transcript | Out-Null