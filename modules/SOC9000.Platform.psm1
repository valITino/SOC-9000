<#
.SYNOPSIS
    SOC9000 Platform Module - OS checks, prerequisites, and tool installers.

.DESCRIPTION
    Provides platform-specific functionality:
    - OS and PowerShell version checks
    - Prerequisites validation
    - Tool installers (winget wrappers)
    - VMware detection and validation

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7.2+
#>

#requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import utilities
Import-Module (Join-Path $PSScriptRoot 'SOC9000.Utils.psm1') -Force

# ==================== OS & POWERSHELL CHECKS ====================

<#
.SYNOPSIS
    Gets the preferred PowerShell executable (pwsh or powershell).
#>
function Get-PreferredShell {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return 'pwsh' }
    return 'powershell'
}

<#
.SYNOPSIS
    Tests if PowerShell 7+ is available.
#>
function Test-PowerShell7Available {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

# ==================== PENDING REBOOT DETECTION ====================

<#
.SYNOPSIS
    Tests if a system reboot is pending.
#>
function Test-PendingReboot {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        )

        foreach ($k in $keys) {
            if (Test-Path $k) {
                if ($k -like '*Session Manager') {
                    $val = (Get-ItemProperty -Path $k -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
                    if ($val) { return $true }
                }
                else {
                    return $true
                }
            }
        }
    }
    catch {
        Write-WarnLog "Error checking for pending reboot: $($_.Exception.Message)"
    }
    return $false
}

# ==================== VMWARE DETECTION ====================

<#
.SYNOPSIS
    Detects VMware Workstation installation and version.
#>
function Get-VMwareWorkstationVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $ver = $null
    try {
        $paths = @(
            'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation',
            'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation'
        )
        foreach ($rk in $paths) {
            if (Test-Path $rk) {
                $p = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
                if ($p -and $p.ProductVersion) { return $p.ProductVersion }
                if ($p -and $p.Version) { return $p.Version }
            }
        }
    }
    catch { }

    return $ver
}

<#
.SYNOPSIS
    Validates VMware Workstation version meets minimum requirements.
#>
function Test-VMwareWorkstationVersion {
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$MinimumVersion = 17)

    $ver = Get-VMwareWorkstationVersion
    if (-not $ver) {
        Write-WarnLog "VMware Workstation not detected"
        return $false
    }

    try {
        $major = [int]($ver -split '\.' | Select-Object -First 1)
        if ($major -ge $MinimumVersion) {
            Write-SuccessLog "VMware Workstation $ver detected (>= $MinimumVersion required)"
            return $true
        }
        else {
            Write-WarnLog "VMware Workstation $ver detected (< $MinimumVersion required)"
            return $false
        }
    }
    catch {
        Write-WarnLog "Could not parse VMware version: $ver"
        return $false
    }
}

# ==================== TOOL INSTALLATION (WINGET) ====================

<#
.SYNOPSIS
    Ensures WinGet is available.
#>
function Test-WinGetAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
}

<#
.SYNOPSIS
    Installs a package using WinGet.
#>
function Install-PackageViaWinGet {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [string]$DisplayName = $PackageId
    )

    if (-not (Test-WinGetAvailable)) {
        Write-ErrorLog "WinGet is not available. Cannot install $DisplayName"
        return $false
    }

    try {
        Write-InfoLog "Installing $DisplayName via winget..."
        $args = @(
            "install", "-e", "--id", $PackageId,
            "--accept-source-agreements", "--accept-package-agreements", "--silent"
        )

        $process = Start-Process -FilePath "winget" -ArgumentList $args -PassThru -Wait -NoNewWindow
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq -1978335189) {
            Write-SuccessLog "$DisplayName installed successfully"
            Update-SessionPath
            return $true
        }
        else {
            Write-WarnLog "winget returned exit code $($process.ExitCode) for $DisplayName"
            return $false
        }
    }
    catch {
        Write-ErrorLog "Error installing $DisplayName`: $($_.Exception.Message)"
        return $false
    }
}

# ==================== WSL MANAGEMENT ====================

<#
.SYNOPSIS
    Checks if WSL is enabled.
#>
function Test-WSLEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
        return ($wsl -and $wsl.State -eq 'Enabled')
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Enables WSL and VirtualMachinePlatform features.
#>
function Enable-WSLFeatures {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $changed = $false

    try {
        $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
        if (-not $wsl -or $wsl.State -ne 'Enabled') {
            Write-InfoLog "Enabling Microsoft-Windows-Subsystem-Linux..."
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction Stop | Out-Null
            $changed = $true
        }
    }
    catch {
        Write-WarnLog "Could not enable WSL: $($_.Exception.Message)"
    }

    try {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
        if (-not $vmp -or $vmp.State -ne 'Enabled') {
            Write-InfoLog "Enabling VirtualMachinePlatform..."
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction Stop | Out-Null
            $changed = $true
        }
    }
    catch {
        Write-WarnLog "Could not enable VirtualMachinePlatform: $($_.Exception.Message)"
    }

    return $changed
}

# ==================== EXPORTS ====================

Export-ModuleMember -Function @(
    'Get-PreferredShell',
    'Test-PowerShell7Available',
    'Test-PendingReboot',
    'Get-VMwareWorkstationVersion',
    'Test-VMwareWorkstationVersion',
    'Test-WinGetAvailable',
    'Install-PackageViaWinGet',
    'Test-WSLEnabled',
    'Enable-WSLFeatures'
)
