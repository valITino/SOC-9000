<#
    install-prereqs.ps1: Installs GNU Make and PowerShell 7 if they are not already present.
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
    Write-Output "GNU Make not found. Installing via winget..."
    try { winget install --id GnuWin32.Make --exact --accept-package-agreements --accept-source-agreements }
    catch { Write-Warning "Failed to install GNU Make via winget. You may need to install it manually." }
} else { Write-Output "GNU Make already installed." }

# PowerShell 7
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Output "PowerShell 7 not found. Installing via winget..."
    try { winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements }
    catch { Write-Warning "Failed to install PowerShell 7 via winget. You may need to install it manually." }
} else { Write-Output "PowerShell 7 already installed." }

Write-Output "Prerequisite installation complete."
