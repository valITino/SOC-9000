# Configure VMware VMnet adapters for SOC-9000 (declarative)
<#!
.SYNOPSIS
    Declaratively configure VMware VMnet networks for SOC-9000.
.DESCRIPTION
    Generates a VMnet profile, backs up the current state, imports the
    new profile via vnetlib64.exe, restarts services, and verifies
    adapters and services. Defaults can be overridden via parameters or
    a .env file in the project root.
.PARAMETER VMNET8_SUBNET
    Subnet of VMnet8 NAT network.
.PARAMETER VMNET8_MASK
    Netmask for VMnet8.
.PARAMETER VMNET8_HOSTIP
    Host adapter IP for VMnet8.
.PARAMETER VMNET8_GATEWAY
    NAT gateway for VMnet8.
.PARAMETER VMNET20_SUBNET
    Subnet of host-only VMnet20.
.PARAMETER VMNET21_SUBNET
    Subnet of host-only VMnet21.
.PARAMETER VMNET22_SUBNET
    Subnet of host-only VMnet22.
.PARAMETER VMNET23_SUBNET
    Subnet of host-only VMnet23.
.PARAMETER HOSTONLY_MASK
    Netmask used for host-only networks.
.EXAMPLE
    ./configure-vmnet.ps1
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$VMNET8_SUBNET = '192.168.37.0',
    [string]$VMNET8_MASK = '255.255.255.0',
    [string]$VMNET8_HOSTIP = '192.168.37.1',
    [string]$VMNET8_GATEWAY = '192.168.37.2',
    [string]$VMNET20_SUBNET = '172.22.10.0',
    [string]$VMNET21_SUBNET = '172.22.20.0',
    [string]$VMNET22_SUBNET = '172.22.30.0',
    [string]$VMNET23_SUBNET = '172.22.40.0',
    [string]$HOSTONLY_MASK = '255.255.255.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'configure-vmnet.ps1 can only run on Windows.'
}

# Allow overrides from .env in project root
$projectRoot = Split-Path -Parent $PSCommandPath
$envPath = Join-Path $projectRoot '.env'
if (Test-Path $envPath) {
    Get-Content $envPath | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } |
        ForEach-Object {
            $parts = $_ -split '=',2
            $key = $parts[0].Trim()
            $val = $parts[1].Trim()
            switch ($key) {
                'VMNET8_SUBNET' { $VMNET8_SUBNET = $val }
                'VMNET8_MASK' { $VMNET8_MASK = $val }
                'VMNET8_HOSTIP' { $VMNET8_HOSTIP = $val }
                'VMNET8_GATEWAY' { $VMNET8_GATEWAY = $val }
                'VMNET20_SUBNET' { $VMNET20_SUBNET = $val }
                'VMNET21_SUBNET' { $VMNET21_SUBNET = $val }
                'VMNET22_SUBNET' { $VMNET22_SUBNET = $val }
                'VMNET23_SUBNET' { $VMNET23_SUBNET = $val }
                'HOSTONLY_MASK' { $HOSTONLY_MASK = $val }
            }
        }
}

# Require Administrator
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Administrator privileges are required.'
    $relaunchArgs = $MyInvocation.UnboundArguments -join ' '
    Write-Output "Start-Process pwsh -Verb RunAs -File `"$PSCommandPath`" $relaunchArgs"
    exit 1
}

# Locate vnetlib64.exe
$candidates = @(
    'C:\\Program Files (x86)\\VMware\\VMware Workstation\\vnetlib64.exe',
    'C:\\Program Files\\VMware\\VMware Workstation\\vnetlib64.exe'
)
$vnetlib = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vnetlib) {
    $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
    if ($cmd) { $vnetlib = $cmd.Source }
}
if (-not $vnetlib) {
    Write-Error 'Install VMware Workstation Pro 17+ (Virtual Network Editor). vnetlib64.exe missing.'
    exit 1
}

# Ensure required services exist and startup not Disabled
$services = @(
    @{Name='VMware NAT Service'; Startup='Automatic'},
    @{Name='VMnetDHCP'; Startup='Automatic'}
)
$bridge = Get-Service -Name 'VMnetBridge' -ErrorAction SilentlyContinue
if ($bridge) { $services += @{Name='VMnetBridge'; Startup=$bridge.StartType} }
foreach ($svc in $services) {
    $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
    if (-not $s) { Write-Error "Service $($svc.Name) not found"; exit 1 }
    if ($s.StartType -eq 'Disabled') { Set-Service -Name $s.Name -StartupType $svc.Startup }
}

function Get-DhcpRange([string]$subnet) {
    $parts = $subnet.Split('.')
    $prefix = "$($parts[0]).$($parts[1]).$($parts[2])"
    return "$prefix.128 $prefix.254"
}
function Get-HostIP([string]$subnet) {
    $parts = $subnet.Split('.')
    return "$($parts[0]).$($parts[1]).$($parts[2]).1"
}
function MaskToPrefix([string]$mask) {
    $bytes = [System.Net.IPAddress]::Parse($mask).GetAddressBytes()
    $bits  = ($bytes | ForEach-Object { [Convert]::ToString($_,2).PadLeft(8,'0') }) -join ''
    return ($bits -split '0')[0].Length
}

$dhcpRange    = Get-DhcpRange $VMNET8_SUBNET
$vmnet20_host = Get-HostIP $VMNET20_SUBNET
$vmnet21_host = Get-HostIP $VMNET21_SUBNET
$vmnet22_host = Get-HostIP $VMNET22_SUBNET
$vmnet23_host = Get-HostIP $VMNET23_SUBNET

# Generate VMnet profile
$vmnetProfile = @"
version 1
# VMnet8 NAT
add VMnet8 nat
set VMnet8 mask $VMNET8_MASK
set VMnet8 subnet $VMNET8_SUBNET
set VMnet8 hostip $VMNET8_HOSTIP
set VMnet8 gateway $VMNET8_GATEWAY
set VMnet8 dhcp yes $dhcpRange
# VMnet20 host-only
add VMnet20 hostonly
set VMnet20 mask $HOSTONLY_MASK
set VMnet20 subnet $VMNET20_SUBNET
set VMnet20 hostip $vmnet20_host
set VMnet20 dhcp no
# VMnet21 host-only
add VMnet21 hostonly
set VMnet21 mask $HOSTONLY_MASK
set VMnet21 subnet $VMNET21_SUBNET
set VMnet21 hostip $vmnet21_host
set VMnet21 dhcp no
# VMnet22 host-only
add VMnet22 hostonly
set VMnet22 mask $HOSTONLY_MASK
set VMnet22 subnet $VMNET22_SUBNET
set VMnet22 hostip $vmnet22_host
set VMnet22 dhcp no
# VMnet23 host-only
add VMnet23 hostonly
set VMnet23 mask $HOSTONLY_MASK
set VMnet23 subnet $VMNET23_SUBNET
set VMnet23 hostip $vmnet23_host
set VMnet23 dhcp no
"@
$tempProfile = Join-Path $env:TEMP 'soc-9000-vmnet.vnet'
$vmnetProfile | Set-Content -Path $tempProfile -Encoding ASCII

# Backup existing config
$backupDir = Join-Path $env:TEMP 'vmnet-backup'
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
$backupFile = Join-Path $backupDir ("vmnet-" + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.vnet')
& $vnetlib -- export $backupFile

# Import new profile
& $vnetlib -- import $tempProfile
if ($LASTEXITCODE -ne 0) { Write-Error 'vnetlib import failed'; exit 1 }

# Ensure config files exist
$natConf  = 'C:\\ProgramData\\VMware\\vmnetnat.conf'
$dhcpConf = 'C:\\ProgramData\\VMware\\vmnetdhcp.conf'
if (-not (Test-Path $natConf) -or -not (Test-Path $dhcpConf)) {
    & $vnetlib -- update vmnet8
}

# Restart services
foreach ($svc in $services) {
    Restart-Service -Name $svc.Name -ErrorAction SilentlyContinue
    Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
}

# Verify adapters
function Assert-Adapter {
    param([string]$Name,[string]$Ip,[string]$Mask)
    $ad = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
    if (-not $ad) { Write-Error "Adapter $Name missing"; exit 1 }
    if ($ad.Status -ne 'Up') { Write-Error "Adapter $Name not Up"; exit 1 }
    $cfg = Get-NetIPAddress -InterfaceAlias $Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cfg) { Write-Error "No IPv4 address on $Name"; exit 1 }
    if ($cfg.IPAddress -ne $Ip) { Write-Error "$Name IP $($cfg.IPAddress) expected $Ip"; exit 1 }
    if ($cfg.PrefixLength -ne (MaskToPrefix $Mask)) { Write-Error "$Name mask mismatch"; exit 1 }
}

Assert-Adapter 'VMware Network Adapter VMnet8' $VMNET8_HOSTIP $VMNET8_MASK
Assert-Adapter 'VMware Network Adapter VMnet20' $vmnet20_host $HOSTONLY_MASK
Assert-Adapter 'VMware Network Adapter VMnet21' $vmnet21_host $HOSTONLY_MASK
Assert-Adapter 'VMware Network Adapter VMnet22' $vmnet22_host $HOSTONLY_MASK
Assert-Adapter 'VMware Network Adapter VMnet23' $vmnet23_host $HOSTONLY_MASK

# NAT gateway connectivity check
$natSvc = Get-Service 'VMware NAT Service' -ErrorAction SilentlyContinue
if ($natSvc -and $natSvc.Status -eq 'Running') {
    $ping = Test-Connection -TargetName $VMNET8_GATEWAY -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $ping) {
        Write-Warning 'Detected NAT routing failure. Repair/reinstall VMware Workstation 17.x; some builds shipped a faulty vmnat.exe.'
    }
}

# Hyper-V advisory
$hyperv = $false
try {
    $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
    $hyperv = $hv.State -eq 'Enabled'
} catch {
    try {
        $bcd = bcdedit /enum '{current}' | Select-String 'hypervisorlaunchtype'
        if ($bcd -and $bcd.ToString() -match 'Auto') { $hyperv = $true }
    } catch { Write-Verbose $_ }
}
if ($hyperv) {
    Write-Warning 'Hyper-V is enabled; bridged networking may behave unpredictably.'
}

# vmrest optional check
if (Get-Process -Name vmrest -ErrorAction SilentlyContinue) {
    $rest = Test-NetConnection 127.0.0.1 -Port 8697 -InformationLevel Quiet
    if (-not $rest) { Write-Warning 'vmrest is running but 127.0.0.1:8697 is unreachable' }
}

Write-Output 'VMware networks configured.'
exit 0
