# SOC-9000 - build-standalone-exe.ps1
<#
    Uses the PS2EXE module to compile the standalone installer script into a single
    Windows executable. Run this script from the repository root (recommended),
    or pass a custom -Source and/or -Output.

    Example:
        pwsh -File .\scripts\build-standalone-exe.ps1
#>

[CmdletBinding()]
param(
    [string]$Source = "scripts/standalone-installer.ps1",
    [string]$Output = "SOC-9000-installer.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-PS2EXE {
    if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
        Write-Host "PS2EXE module not found. Installing..." -ForegroundColor Yellow
        try {
            Install-Module -Name PS2EXE -Scope CurrentUser -Force
        } catch {
            Write-Error "Failed to install PS2EXE module: $_"
            exit 1
        }
    }
}

# Resolve paths (allow relative input)
try {
    $resolvedSource = (Resolve-Path -Path $Source).Path
} catch {
    Write-Error "Source script not found at '$Source'."
    exit 1
}
$resolvedOutput = [System.IO.Path]::GetFullPath($Output)

Ensure-PS2EXE

Write-Host "Compiling `"$resolvedSource`" to `"$resolvedOutput`"..." -ForegroundColor Cyan
try {
    Invoke-PS2EXE -InputFile $resolvedSource -OutputFile $resolvedOutput -NoConsole
    Write-Host "Executable created: $resolvedOutput" -ForegroundColor Green
} catch {
    Write-Error "Compilation failed: $_"
    exit 1
}
