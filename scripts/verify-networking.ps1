# Verify VMware networking and hosts configuration for SOC-9000
<#!
.SYNOPSIS
    Validate VMware VMnet adapters, services and configuration.
.DESCRIPTION
    Ensures required adapters exist and are up, services are running,
    and configuration files reflect the expected topology. Values may
    be overridden by parameters or .env entries.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignment", "", Justification="Parameters consumed during configuration comparisons")]
[CmdletBinding()]
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

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw 'verify-networking.ps1 can only run on Windows.' }

# Allow overrides from .env
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

try {
    # Locate vnetlib64
    $candidates = @(
        'C:\\Program Files (x86)\\VMware\\VMware Workstation\\vnetlib64.exe',
        'C:\\Program Files\\VMware\\VMware Workstation\\vnetlib64.exe'
    )
    $vnetlib = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $vnetlib) {
        $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
        if ($cmd) { $vnetlib = $cmd.Source }
    }
    if (-not $vnetlib) { throw 'vnetlib64.exe not found' }

    # Services
    $services = 'VMware NAT Service','VMnetDHCP'
    foreach ($s in $services) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $svc) { throw "Service $s not found" }
        if ($svc.StartType -eq 'Disabled') { throw "$s startup disabled" }
        if ($svc.Status -ne 'Running') { throw "$s not running" }
    }
    $bridgeSvc = Get-Service -Name 'VMnetBridge' -ErrorAction SilentlyContinue
    if ($bridgeSvc -and $bridgeSvc.StartType -eq 'Disabled') { throw 'VMnetBridge startup disabled' }

    # Config files
    $natConf  = 'C:\\ProgramData\\VMware\\vmnetnat.conf'
    $dhcpConf = 'C:\\ProgramData\\VMware\\vmnetdhcp.conf'
    if (-not (Test-Path $natConf))  { throw "Missing $natConf" }
    if (-not (Test-Path $dhcpConf)) { throw "Missing $dhcpConf" }

    # Validate NAT gateway
    $natText = Get-Content $natConf -ErrorAction Stop
    if ($natText -notmatch [regex]::Escape($VMNET8_GATEWAY)) {
        throw 'NAT gateway mismatch in vmnetnat.conf'
    }

    # Validate DHCP range
    $range = Get-DhcpRange $VMNET8_SUBNET
    $dhcpText = Get-Content $dhcpConf -ErrorAction Stop
    if ($dhcpText -notmatch [regex]::Escape($range.Split()[0])) { throw 'DHCP start mismatch' }
    if ($dhcpText -notmatch [regex]::Escape($range.Split()[1])) { throw 'DHCP end mismatch' }

    # Adapters
    $adapters = @(
        @{Name='VMware Network Adapter VMnet8';  IP=$VMNET8_HOSTIP; Mask=$VMNET8_MASK},
        @{Name='VMware Network Adapter VMnet20'; IP=(Get-HostIP $VMNET20_SUBNET); Mask=$HOSTONLY_MASK},
        @{Name='VMware Network Adapter VMnet21'; IP=(Get-HostIP $VMNET21_SUBNET); Mask=$HOSTONLY_MASK},
        @{Name='VMware Network Adapter VMnet22'; IP=(Get-HostIP $VMNET22_SUBNET); Mask=$HOSTONLY_MASK},
        @{Name='VMware Network Adapter VMnet23'; IP=(Get-HostIP $VMNET23_SUBNET); Mask=$HOSTONLY_MASK}
    )
    foreach ($a in $adapters) {
        $ad = Get-NetAdapter -Name $a.Name -ErrorAction SilentlyContinue
        if (-not $ad) { throw "Adapter $($a.Name) missing" }
        if ($ad.Status -ne 'Up') { throw "Adapter $($a.Name) not Up" }
        $cfg = Get-NetIPAddress -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cfg) { throw "No IPv4 on $($a.Name)" }
        if ($cfg.IPAddress -ne $a.IP) { throw "$($a.Name) IP $($cfg.IPAddress) expected $($a.IP)" }
        if ($cfg.PrefixLength -ne (MaskToPrefix $a.Mask)) { throw "$($a.Name) mask mismatch" }
    }

    Write-Output 'Networking verification passed'
    exit 0
} catch {
    Write-Error $_
    exit 1
}
