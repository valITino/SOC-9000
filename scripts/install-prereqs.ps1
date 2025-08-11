<# 
    install-prereqs.ps1: Installs GNU Make and PowerShell 7 if they are not already present.

    This script uses winget to install the required tools and should be run with Administrator
    privileges.  If the tool is already installed, it will be skipped.

    Usage:
        pwsh -File .\scripts\install-prereqs.ps1

    You can also call this script via the Makefile target:
        make prereqs
#>
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning "winget is not installed or not in PATH. Installation attempts may fail."
    }
}

Ensure-Winget

# Check for GNU Make
$makeCmd = Get-Command make -ErrorAction SilentlyContinue
if (-not $makeCmd) {
    Write-Host "GNU Make not found. Installing via winget..." -ForegroundColor Cyan
    try {
        winget install --id GnuWin32.Make --exact --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Warning "Failed to install GNU Make via winget. You may need to install it manually."
    }
} else {
    Write-Host "GNU Make already installed." -ForegroundColor Green
}

# Check for PowerShell 7 (`pwsh`)
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd) {
    Write-Host "PowerShell 7 not found. Installing via winget..." -ForegroundColor Cyan
    try {
        winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Warning "Failed to install PowerShell 7 via winget. You may need to install it manually."
    }
} else {
    Write-Host "PowerShell 7 already installed." -ForegroundColor Green
}

Write-Host "Prerequisite installation complete." -ForegroundColor Green
