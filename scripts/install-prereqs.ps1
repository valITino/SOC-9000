<#
    install-prereqs.ps1: Installs PowerShell 7 and GNU Make if they are not already present.
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

# GNU Make
if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
    Write-Host "GNU Make not found. Installing via winget..." -ForegroundColor Cyan
    try {
        winget install --id GnuWin32.Make --exact --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Warning "Failed to install GNU Make via winget. You may need to install it manually."
    }
    # Try to add common GnuWin32 path to PATH for current session and persist if possible
    $makeDir = Join-Path ${env:ProgramFiles(x86)} 'GnuWin32\bin'
    if (-not (Test-Path $makeDir)) {
        $makeDir = Join-Path ${env:ProgramFiles} 'GnuWin32\bin'
    }
    if (Test-Path $makeDir) {
        if (-not ($Env:Path.Split(';') -contains $makeDir)) {
            $Env:Path = "$Env:Path;$makeDir"
            try {
                [Environment]::SetEnvironmentVariable('Path', $Env:Path, 'Machine')
            } catch {
                Write-Warning "Failed to persist PATH update. GNU Make may not be available in new shells."
            }
        }
    }
    if (Get-Command make -ErrorAction SilentlyContinue) {
        Write-Host "GNU Make installed." -ForegroundColor Green
    } else {
        Write-Warning "GNU Make is still not available. You may need to restart PowerShell or install it manually."
    }
} else {
    Write-Host "GNU Make already installed." -ForegroundColor Green
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