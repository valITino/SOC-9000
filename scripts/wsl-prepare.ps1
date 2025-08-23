[CmdletBinding()]
param(
    [string]$DistroName = "Ubuntu"   # Change if you prefer a different image
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WSLFeatureEnabled {
    param([string]$FeatureName)
    
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return $feature.State -eq 'Enabled'
    }
    catch {
        Write-Warning "Could not check status of feature '$FeatureName': $($_.Exception.Message)"
        return $false
    }
}

function Enable-WSLFeature {
    param([string]$FeatureName)
    
    try {
        Write-Host "Enabling $FeatureName..." -ForegroundColor Yellow
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop
        return $true
    }
    catch {
        Write-Error "Failed to enable feature '$FeatureName': $($_.Exception.Message)"
        return $false
    }
}

function Test-WSLInstalled {
    try {
        $null = wsl --version 2>$null
        return $true
    }
    catch {
        return $false
    }
}

function Install-WSLPlatform {
    try {
        Write-Host "Installing WSL platform..." -ForegroundColor Yellow
        wsl --install --no-distribution --web-download
        return $true
    }
    catch {
        Write-Error "Failed to install WSL platform: $($_.Exception.Message)"
        return $false
    }
}

function Test-WSLDistroInstalled {
    param([string]$Distro)
    
    try {
        $distros = (wsl -l -q) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        return $distros -contains $Distro
    }
    catch {
        Write-Warning "Could not retrieve WSL distributions: $($_.Exception.Message)"
        return $false
    }
}

function Install-WSLDistro {
    param([string]$Distro)
    
    try {
        Write-Host "Installing $Distro..." -ForegroundColor Yellow
        wsl --install -d $Distro --no-launch --web-download
        return $true
    }
    catch {
        Write-Error "Failed to install WSL distro '$Distro': $($_.Exception.Message)"
        return $false
    }
}

# Main execution
try {
    Write-Host "=== WSL Preflight Check ===" -ForegroundColor Cyan
    Write-Host "Target distro: $DistroName" -ForegroundColor Cyan
    Write-Host ""

    # Check admin privileges
    if (-not (Test-Admin)) {
        throw "This script must be run elevated (as Administrator)."
    }

    # Check and enable required Windows features
    $needReboot = $false
    $features = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
    
    foreach ($feature in $features) {
        if (-not (Test-WSLFeatureEnabled -FeatureName $feature)) {
            if (Enable-WSLFeature -FeatureName $feature) {
                $needReboot = $true
            }
        }
    }

    # Check if WSL is installed
    if (-not (Test-WSLInstalled)) {
        if (Install-WSLPlatform) {
            $needReboot = $true
        }
    }

    # If reboot is needed, exit with code 2
    if ($needReboot) {
        Write-Host "`n=== Reboot Required ===" -ForegroundColor Yellow
        Write-Warning "Windows features enabled. Please reboot your system, then rerun this script."
        exit 2
    }

    # Ensure the target distro is installed
    if (-not (Test-WSLDistroInstalled -Distro $DistroName)) {
        if (-not (Install-WSLDistro -Distro $DistroName)) {
            throw "Failed to install WSL distro '$DistroName'."
        }
        
        # Verify the distro was installed successfully
        Start-Sleep -Seconds 5  # Give it a moment to complete installation
        if (-not (Test-WSLDistroInstalled -Distro $DistroName)) {
            throw "WSL distro '$DistroName' not present after install attempt."
        }
    }

    Write-Host "`n=== Preflight Complete ===" -ForegroundColor Green
    Write-Host "WSL is ready with distro: $DistroName" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "WSL preflight failed: $($_.Exception.Message)"
    exit 1
}