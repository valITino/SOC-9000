# SOC-9000 - build-standalone-exe.ps1

<#
    Uses the PS2EXE module to compile the standalone installer script into a single
    Windows executable.  You must run this script from the repository root with
    PowerShell.  The resulting `SOC-9000-installer.exe` will be placed in the
    current directory.

    Example:
        pwsh -File .\scripts\build-standalone-exe.ps1

    You can specify custom paths via -Source and -Output parameters.
#>
[CmdletBinding()] param(
    [string]$Source = "scripts/standalone-installer.ps1",
    [string]$Output = "SOC-9000-installer.exe"
)
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

Ensure-PS2EXE

Write-Host "Compiling $Source to $Output..."
try {
    Invoke-PS2EXE -InputFile $Source -OutputFile $Output -NoConsole
    Write-Host "Executable created: $Output" -ForegroundColor Green
} catch {
    Write-Error "Compilation failed: $_"
    exit 1
}

