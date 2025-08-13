<#
    install-prereqs.ps1: Installs Git and PowerShell 7 if they are not already present.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Error "winget is not installed or not in PATH. Cannot install prerequisites."
    exit 1
}

$failed = $false

# PowerShell 7 (pwsh)
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Host "PowerShell 7 not found. Installing via winget..." -ForegroundColor Cyan
    try {
        winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            Write-Warning "winget returned exit code $LASTEXITCODE for PowerShell 7"
            $failed = $true
        }
    } catch {
        Write-Warning "Failed to install PowerShell 7 via winget. You may need to install it manually."
        $failed = $true
    }
} else {
    Write-Host "PowerShell 7 already installed." -ForegroundColor Green
}

# Packer
if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
    Write-Host "Packer not found. Installing via winget..." -ForegroundColor Cyan
    try {
        winget install --id HashiCorp.Packer --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Warning "Failed to install Packer via winget. You may need to install it manually."
    }
} else {
    Write-Host "Packer already installed." -ForegroundColor Green
}

# Git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git not found. Installing via winget..." -ForegroundColor Cyan
    try {
        winget install --id Git.Git --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            Write-Warning "winget returned exit code $LASTEXITCODE for Git"
            $failed = $true
        }
    } catch {
        Write-Warning "Failed to install Git via winget. You may need to install it manually."
        $failed = $true
    }
} else {
    Write-Host "Git already installed." -ForegroundColor Green
}

if ($failed) {
    Write-Warning "One or more prerequisites failed to install."
    exit 1
}

Write-Host "Prerequisite installation complete." -ForegroundColor Green
exit 0

