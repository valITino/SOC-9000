[CmdletBinding()]
param(
    [string]$EnvPath,
    [string]$OutFile,
    [switch]$PassThru,
    [switch]$CopyToLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-DotEnv {
    param([string]$Path)
    
    if (-not $Path -or -not (Test-Path $Path)) { return @{} }
    $map = @{}
    
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k, $v = $_ -split '=', 2
        if ($null -ne $v) { $map[$k.Trim()] = $v.Trim() }
    }
    return $map
}

function Test-IPv4Address {
    param([string]$Ip)
    
    if ($Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach($oct in ($Ip -split '\.')) { 
        if([int]$oct -gt 255) { return $false } 
    }
    return $true
}

function Test-IPv4Mask {
    param([string]$Mask)
    
    if (-not (Test-IPv4Address $Mask)) { return $false }
    $bytes = [Net.IPAddress]::Parse($Mask).GetAddressBytes()
    $bits = ($bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    return ($bits -notmatch '01')
}

function Test-Network24 {
    param([string]$Subnet)
    
    if (-not (Test-IPv4Address $Subnet)) { return $false }
    ($Subnet -split '\.')[3] -eq '0'
}

function Get-HostOnlyGatewayIp {
    param([string]$Subnet)
    
    $octets = $Subnet -split '\.'
    "$($octets[0]).$($octets[1]).$($octets[2]).1"
}

function Test-SubnetConflict {
    param([string[]]$Subnets)
    
    $ipRanges = @()
    foreach ($subnet in $Subnets) {
        $ip = [Net.IPAddress]::Parse($subnet)
        $ipRanges += @{
            IP = $ip
            Network = $subnet
        }
    }
    
    for ($i = 0; $i -lt $ipRanges.Count; $i++) {
        for ($j = $i + 1; $j -lt $ipRanges.Count; $j++) {
            $ip1 = $ipRanges[$i].IP
            $ip2 = $ipRanges[$j].IP
            
            # Check if subnets are the same or overlapping
            if ($ip1.Equals($ip2)) {
                Write-Warning "Duplicate subnet found: $($ipRanges[$i].Network)"
                return $true
            }
        }
    }
    return $false
}

# Main execution
try {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $envFile = if ($EnvPath) { $EnvPath } elseif (Test-Path (Join-Path $RepoRoot '.env')) { Join-Path $RepoRoot '.env' } else { $null }
    $envMap = if ($envFile) { Read-DotEnv $envFile } else { @{} }

    # Determine install root
    $EExists = Test-Path 'E:\'
    $sysDrive = $env:SystemDrive
    if (-not $sysDrive) { $sysDrive = 'C:' }
    
    $InstallRoot = if ($envMap['INSTALL_ROOT']) { 
        $envMap['INSTALL_ROOT'] 
    } else { 
        if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path $sysDrive 'SOC-9000-Install' } 
    }
    
    $ProfileDir = Join-Path $InstallRoot 'config\network'
    $LogDir = Join-Path $InstallRoot 'logs\installation'
    New-Item -ItemType Directory -Force -Path $ProfileDir, $LogDir | Out-Null

    $HostOnlyMask = if ($envMap['HOSTONLY_MASK']) { $envMap['HOSTONLY_MASK'] } else { '255.255.255.0' }
    
    # Host-only subnets with flexible configuration
    $HostOnlySubnets = @()
    if ($envMap['HOSTONLY_SUBNETS']) {
        $HostOnlySubnets = $envMap['HOSTONLY_SUBNETS'] -split ',' | ForEach-Object { $_.Trim() }
    } else {
        # Fallback to individual VMNET environment variables
        $Vmnet20Subnet = if ($envMap['VMNET20_SUBNET']) { $envMap['VMNET20_SUBNET'] } else { '172.22.10.0' }
        $Vmnet21Subnet = if ($envMap['VMNET21_SUBNET']) { $envMap['VMNET21_SUBNET'] } else { '172.22.20.0' }
        $Vmnet22Subnet = if ($envMap['VMNET22_SUBNET']) { $envMap['VMNET22_SUBNET'] } else { '172.22.30.0' }
        $Vmnet23Subnet = if ($envMap['VMNET23_SUBNET']) { $envMap['VMNET23_SUBNET'] } else { '172.22.40.0' }
        $HostOnlySubnets = @($Vmnet20Subnet, $Vmnet21Subnet, $Vmnet22Subnet, $Vmnet23Subnet)
    }

    # Host-only VMnet IDs
    [int[]]$Ids = @()
    if ($envMap['HOSTONLY_VMNET_IDS']) {
        $Ids = $envMap['HOSTONLY_VMNET_IDS'] -split ',' | ForEach-Object { [int]($_.Trim()) }
    } else {
        $Ids = 9, 10, 11, 12
    }

    # Validation
    foreach ($s in $HostOnlySubnets) {
        if (-not (Test-Network24 $s)) { throw "Host-only subnet '$s' is invalid. Must be a /24 network ending with .0" }
    }
    
    if (-not (Test-IPv4Mask $HostOnlyMask)) { throw "HOSTONLY_MASK '$HostOnlyMask' is invalid" }
    if ($Ids.Count -ne $HostOnlySubnets.Count) { throw "Number of host-only VMnet IDs ($($Ids.Count)) must match number of host-only subnets ($($HostOnlySubnets.Count))" }
    
    # Check for subnet conflicts
    if (Test-SubnetConflict $HostOnlySubnets) {
        throw "Subnet conflict detected. Please ensure all subnets are unique."
    }

    # Generate command lines for host-only networks only
    $lines = @()

    for ($i = 0; $i -lt $HostOnlySubnets.Count; $i++) {
        $id = $Ids[$i]
        $subnet = $HostOnlySubnets[$i]
        $hostIp = Get-HostOnlyGatewayIp $subnet
        
        $lines += @(
            "add adapter vmnet$id",
            "add vnet vmnet$id",
            "set vnet vmnet$id addr $subnet",
            "set vnet vmnet$id mask $HostOnlyMask",
            "set adapter vmnet$id addr $hostIp",
            "update adapter vmnet$id",
            ""
        )
    }

    $text = $lines -join "`r`n"

    # Output file handling
    if (-not $OutFile) { 
        $OutFile = Join-Path $ProfileDir 'vmnet-profile.txt' 
    } else { 
        $parentDir = Split-Path $OutFile -Parent
        if (-not [string]::IsNullOrEmpty($parentDir)) {
            New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
        }
    }
    
    Set-Content -Path $OutFile -Value $text -Encoding ASCII
    Write-Host "VMnet profile written to: $OutFile" -ForegroundColor Green

    if ($CopyToLogs) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $logCopy = Join-Path $LogDir "vmnet-profile-$timestamp.txt"
        Set-Content -Path $logCopy -Value $text -Encoding ASCII
        Write-Host "VMnet profile snapshot copied to: $logCopy" -ForegroundColor Green
    }

    if ($PassThru) { return $text }
}
catch {
    Write-Error "Failed to generate VMnet profile: $($_.Exception.Message)"
    exit 1
}