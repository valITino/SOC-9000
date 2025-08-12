<#
    install-prereqs.ps1: Installs PowerShell 7 if it is not already present.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Warning "winget is not installed or not in PATH. Skipping prerequisite installation."
    return
}

# PowerShell 7 (pwsh)
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Host "PowerShell 7 not found. Installing via winget..." -ForegroundColor Cyan
    try {
        winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Warning "Failed to install PowerShell 7 via winget. You may need to install it manually."
    }
} else {
    Write-Host "PowerShell 7 already installed." -ForegroundColor Green
}

Write-Host "Prerequisite installation complete." -ForegroundColor Green

