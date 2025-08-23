[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:hadFail = $false

function Get-DotEnvMap {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) { return @{} }
    $map = @{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k, $v = $_ -split '=', 2
        if ($null -ne $v) { $map[$k.Trim()] = $v.Trim() }
    }
    return $map
}

function Write-Fail {
    param([string]$Message)
    Write-Host "FAIL: $Message" -ForegroundColor Red
    $script:hadFail = $true
}

function Write-Success {
    param([string]$Message)
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "INFO: $Message" -ForegroundColor Cyan
}

function Test-ServiceStatus {
    param([string]$ServiceName)
    
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Fail "Service not found: $ServiceName"
        return $false
    }

    if ($service.StartType -ne 'Automatic') {
        try {
            Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop
            Write-Info "Set $ServiceName startup type to Automatic"
        } catch {
            Write-Fail "Could not set $ServiceName StartupType=Automatic: $($_.Exception.Message)"
            return $false
        }
    }

    if ($service.Status -ne 'Running') {
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-Info "Started service: $ServiceName"
        } catch {
            Write-Fail "Service not running: $ServiceName (state=$($service.Status)); start failed: $($_.Exception.Message)"
            return $false
        }
    }
    
    return $true
}

function Test-VMnetAdapter {
    param(
        [int]$Id,
        [string]$ExpectedSubnet,
        [string]$AdapterType = "Host-only"
    )
    
    $alias = "VMware Network Adapter VMnet$Id"
    Write-Info "Checking $AdapterType adapter: $alias"

    $adapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Fail "Adapter '$alias' missing."
        return $false
    }

    if ($adapter.Status -ne 'Up') {
        Write-Fail "Adapter '$alias' is not Up (state=$($adapter.Status))."
        return $false
    }

    $ipConfig = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixLength -eq 24 } | Select-Object -First 1
                
    if (-not $ipConfig) {
        Write-Fail "No IPv4 /24 configured on '$alias'."
        return $false
    }

    if ($AdapterType -eq "NAT") {
        Write-Success "VMnet${Id}: $($ipConfig.IPAddress)/$($ipConfig.PrefixLength)"
        return $true
    }

    # For host-only adapters, verify the expected IP
    $expectedIp = ($ExpectedSubnet -replace '\.0$','.1')
    if ($ipConfig.IPAddress -ne $expectedIp) {
        Write-Fail "Expected $expectedIp on '$alias', got $($ipConfig.IPAddress)."
        return $false
    }
    
    Write-Success "$alias configured correctly with IP $($ipConfig.IPAddress)/$($ipConfig.PrefixLength)"
    return $true
}

# Main execution
try {
    # Resolve repo + .env
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $EnvFile = Join-Path $RepoRoot '.env'
    $envMap = Get-DotEnvMap $EnvFile

    # Targets (with sane defaults)
    $natId = [int]($envMap['NAT_VMNET_ID'] ?? 8)
    $natSubnet = $envMap['NAT_SUBNET'] ?? '192.168.186.0'
    
    # Host-only VMnet IDs
    [int[]]$ids = @()
    if ($envMap['HOSTONLY_VMNET_IDS']) { 
        $ids = $envMap['HOSTONLY_VMNET_IDS'] -split ',' | ForEach-Object { [int]($_.Trim()) } 
    } else { 
        $ids = 9, 10, 11, 12 
    }

    # Host-only subnets
    $subnets = @()
    if ($envMap['HOSTONLY_SUBNETS']) { 
        $subnets = $envMap['HOSTONLY_SUBNETS'] -split ',' | ForEach-Object { $_.Trim() } 
    } else { 
        $subnets = @('172.22.10.0', '172.22.20.0', '172.22.30.0', '172.22.40.0')[0..($ids.Count-1)] 
    }

    # Validation
    if ($ids.Count -ne $subnets.Count) {
        Write-Fail "HOSTONLY_VMNET_IDS count ($($ids.Count)) != HOSTONLY_SUBNETS count ($($subnets.Count))."
        exit 1
    }

    Write-Host "`n=== VMware Networking Verification ===" -ForegroundColor Cyan
    Write-Host "NAT (vmnet$natId): $natSubnet/24"
    for ($i = 0; $i -lt $ids.Count; $i++) {
        Write-Host "Host-only (vmnet$($ids[$i])): $($subnets[$i])/24"
    }
    Write-Host ""

    # --- NAT checks ---
    Write-Host "## Checking NAT Configuration ##" -ForegroundColor Yellow
    
    # Check if NAT adapter exists and is up, but don't verify IP configuration
    $natAlias = "VMware Network Adapter VMnet$natId"
    $natAdapter = Get-NetAdapter -Name $natAlias -ErrorAction SilentlyContinue
    if (-not $natAdapter) {
        Write-Fail "NAT adapter '$natAlias' missing."
    } elseif ($natAdapter.Status -ne 'Up') {
        Write-Fail "NAT adapter '$natAlias' is not Up (state=$($natAdapter.Status))."
    } else {
        $natIpConfig = Get-NetIPAddress -InterfaceAlias $natAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.PrefixLength -eq 24 } | Select-Object -First 1
        if ($natIpConfig) {
            Write-Success "NAT adapter configured with IP $($natIpConfig.IPAddress)/$($natIpConfig.PrefixLength)"
        } else {
            Write-Fail "No IPv4 /24 configured on NAT adapter '$natAlias'."
        }
    }
    
    # Check NAT/DHCP services
    foreach ($svcName in 'VMware NAT Service', 'VMnetDHCP') {
        Write-Info "Checking service: $svcName"
        Test-ServiceStatus -ServiceName $svcName | Out-Null
    }

    # --- Host-only checks ---
    Write-Host "`n## Checking Host-only Adapters ##" -ForegroundColor Yellow
    for ($i = 0; $i -lt $ids.Count; $i++) {
        Test-VMnetAdapter -Id $ids[$i] -ExpectedSubnet $subnets[$i]
    }

    # Final result
    if ($script:hadFail) {
        Write-Host "`n=== Verification Result: FAILED ===" -ForegroundColor Red
        Write-Error "Networking verification failed. Please check the configuration."
        exit 1
    } else {
        Write-Host "`n=== Verification Result: PASSED ===" -ForegroundColor Green
        Write-Success "All networking components are properly configured"
        exit 0
    }
}
catch {
    Write-Fail "Script execution failed: $($_.Exception.Message)"
    exit 1
}