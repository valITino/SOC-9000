# SOC-9000 - build-standalone-exe.ps1
<#
    Compiles scripts/standalone-installer.ps1 into SOC-9000-installer.exe using PS2EXE.
    Works on PowerShell 5.1 and PowerShell 7. Run from repo root or pass -Source/-Output.
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
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
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
$scriptDir     = Split-Path -Parent $resolvedSource
$prereqScript  = Join-Path $scriptDir 'install-prereqs.ps1'
if (-not (Test-Path $prereqScript)) {
    Write-Error "Prerequisite script not found at '$prereqScript'."
    exit 1
}

Ensure-PS2EXE

Write-Host "Compiling `"$resolvedSource`" to `"$resolvedOutput`" and bundling prerequisites..." -ForegroundColor Cyan
try {
    Invoke-PS2EXE -InputFile $resolvedSource -OutputFile $resolvedOutput -NoConsole -SupportingFile $prereqScript
    Write-Host "Executable created: $resolvedOutput" -ForegroundColor Green
} catch {
    Write-Error "Compilation failed: $_"
    exit 1
}
