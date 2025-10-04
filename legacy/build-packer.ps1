<#
.SYNOPSIS
    [DEPRECATED] Legacy Packer build script shim

.DESCRIPTION
    This script is DEPRECATED and maintained only for backwards compatibility.
    It redirects to the new modular builder scripts.

    Please use the new scripts instead:
    - .\ubuntu-build.ps1  (for Ubuntu builds)
    - .\windows-build.ps1 (for Windows builds)
    - .\setup-soc9000.ps1 (for orchestrated builds)

.PARAMETER Only
    [DEPRECATED] Specify 'ubuntu' or 'windows' to build a specific VM.

.PARAMETER UbuntuMaxMinutes
    [DEPRECATED] Timeout for Ubuntu build (default: 45 minutes).

.PARAMETER WindowsMaxMinutes
    [DEPRECATED] Timeout for Windows build (default: 120 minutes).

.PARAMETER Headless
    [DEPRECATED] Run Packer in headless mode.

.EXAMPLE
    .\legacy\build-packer.ps1 -Only ubuntu
    # Redirects to: .\ubuntu-build.ps1

.EXAMPLE
    .\legacy\build-packer.ps1 -Only windows
    # Redirects to: .\windows-build.ps1

.NOTES
    Version: 1.0.0 (Legacy Shim)
    Requires: PowerShell 7.2+

    DEPRECATION NOTICE:
    This script will be removed in a future version.
    Please migrate to the new builder scripts.
#>

#requires -Version 7.2

[CmdletBinding()]
param(
    [ValidateSet('ubuntu', 'windows')]
    [string]$Only,
    [int]$UbuntuMaxMinutes = 45,
    [int]$WindowsMaxMinutes = 120,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================== DEPRECATION WARNING ====================

$DeprecationMessage = @"

===========================================================================
  ⚠️  DEPRECATION WARNING
===========================================================================

This script (legacy/build-packer.ps1) is DEPRECATED.

Please use the new builder scripts instead:

  For Ubuntu:    .\ubuntu-build.ps1 -Verbose
  For Windows:   .\windows-build.ps1 -Verbose
  For All:       .\setup-soc9000.ps1 -All -Verbose

The new scripts provide:
  ✓ Modular architecture with reusable components
  ✓ Better error handling and logging
  ✓ Consistent configuration management
  ✓ Progress tracking and reporting

This shim will be removed in a future release.

===========================================================================

"@

Write-Host $DeprecationMessage -ForegroundColor Yellow

# Wait a few seconds so user sees the warning
Start-Sleep -Seconds 3

# ==================== SHIM LOGIC ====================

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $Only) {
    Write-Host "[REDIRECT] No -Only parameter specified." -ForegroundColor Cyan
    Write-Host "[REDIRECT] Redirecting to: .\setup-soc9000.ps1 -All -Verbose" -ForegroundColor Cyan
    Write-Host ""

    $orchestratorScript = Join-Path $RepoRoot 'setup-soc9000.ps1'
    & $orchestratorScript -All -Verbose
    exit $LASTEXITCODE
}

switch ($Only.ToLower()) {
    'ubuntu' {
        Write-Host "[REDIRECT] Redirecting to: .\ubuntu-build.ps1" -ForegroundColor Cyan
        Write-Host ""

        $ubuntuScript = Join-Path $RepoRoot 'ubuntu-build.ps1'
        & $ubuntuScript -TimeoutMinutes $UbuntuMaxMinutes -Verbose
        exit $LASTEXITCODE
    }

    'windows' {
        Write-Host "[REDIRECT] Redirecting to: .\windows-build.ps1" -ForegroundColor Cyan
        Write-Host ""

        $windowsScript = Join-Path $RepoRoot 'windows-build.ps1'
        & $windowsScript -TimeoutMinutes $WindowsMaxMinutes -Verbose
        exit $LASTEXITCODE
    }

    default {
        Write-Host "[ERROR] Unknown -Only value: $Only" -ForegroundColor Red
        Write-Host "[ERROR] Valid values: ubuntu, windows" -ForegroundColor Red
        exit 1
    }
}
