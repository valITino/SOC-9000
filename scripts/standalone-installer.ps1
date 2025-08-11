# SOC-9000 - standalone-installer.ps1
<#
    One‑click installation for SOC‑9000. Clones the repository into a chosen directory,
    downloads required ISOs, and launches lab bring‑up (`make up-all`).

    Run from a PowerShell window **as Administrator**.

    Examples:
        # install to the default path (E:\SOC-9000-Pre-Install)
        pwsh -File .\scripts\standalone-installer.ps1

        # install to a custom path
        pwsh -File .\scripts\standalone-installer.ps1 -InstallDir "D:\Labs\SOC-9000"
#>

[CmdletBinding()]
param(
    # Where prerequisite files (ISOs, artifacts, temp) will live. Defaults to E:\SOC-9000-Pre-Install.
    [string]$InstallDir = "E:\\SOC-9000-Pre-Install",

    # Where to clone the SOC‑9000 repository. Defaults to E:\SOC-9000.
    [string]$RepoDir    = "E:\\SOC-9000"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script root for locating sibling helper scripts regardless of CWD
$ScriptRoot = Split-Path -Parent $PSCommandPath

function Require-Administrator {
    if ($IsWindows) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
            Write-Warning "This installer must be run as Administrator. Right-click PowerShell and choose 'Run as administrator'."
            exit 1
        }
    } else {
        Write-Warning "Non-Windows platform detected; skipping Administrator check."
    }
}

function Ensure-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git is not installed or not in PATH. Please install Git and retry."
        exit 1
    }
}

function Ensure-Make {
    if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
        Write-Warning "GNU Make was not found after prerequisite installation."
    }
}

function Ensure-Packer {
    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning "HashiCorp Packer was not found. Lab bring-up cannot proceed."
        return $false
    }
    return $true
}

function Run-PowerShellScript {
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [string[]]$Arguments = @()
    )
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    } else {
        Write-Error "Neither pwsh nor powershell is available to run $ScriptPath. Please install PowerShell."
        exit 1
    }
}

# Entry point
Write-Host "== SOC-9000 Standalone Installer ==" -ForegroundColor Cyan
Require-Administrator
Ensure-Git

# Install prerequisites (GNU Make and PowerShell 7)
if ($IsWindows) {
    try {
        Write-Host "Checking prerequisites..." -ForegroundColor Cyan
        $prereqPath = Join-Path $ScriptRoot 'install-prereqs.ps1'
        Run-PowerShellScript -ScriptPath $prereqPath
    } catch {
        Write-Warning "Prerequisite installation script failed. Continuing may result in errors."
    }
} else {
    Write-Warning "Non-Windows host detected; skipping prerequisite installation."
}
Ensure-Make

# Ensure directories exist and normalize to absolute paths
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
if (-not (Test-Path $RepoDir))    { New-Item -ItemType Directory -Path $RepoDir    -Force | Out-Null }

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$RepoDir    = [System.IO.Path]::GetFullPath($RepoDir)

Write-Host "Pre‑install directory: $InstallDir" -ForegroundColor Cyan
Write-Host "Repository directory: $RepoDir"    -ForegroundColor Cyan

# Clone or update repository
$gitDir = Join-Path $RepoDir '.git'
if (Test-Path $gitDir) {
    Write-Host "SOC-9000 repository already exists. Pulling latest changes..." -ForegroundColor Green
    Push-Location $RepoDir
    try {
        git pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "git pull returned exit code $LASTEXITCODE. Proceeding with existing repository."
        }
    } catch {
        Write-Warning "Failed to pull latest changes. Proceeding with existing repository."
    } finally {
        Pop-Location
    }
} else {
    # If directory exists but is not a git repo, ensure it's empty
    if ((Get-ChildItem -Path $RepoDir -Force | Measure-Object).Count -gt 0) {
        Write-Error "Repository directory $RepoDir exists and is not a Git repository."
        exit 1
    }
    Write-Host "Cloning SOC-9000 repository..." -ForegroundColor Green
    try {
        git clone "https://github.com/valITino/SOC-9000.git" $RepoDir
        if ($LASTEXITCODE -ne 0) {
            Write-Error "git clone returned exit code $LASTEXITCODE."
            exit 1
        }
    } catch {
        Write-Error "Failed to clone repository: $_"
        exit 1
    }
}

# Work from the repo root for subsequent operations
Set-Location $RepoDir

# Initialize .env if missing
if (-not (Test-Path ".env")) {
    Write-Host "Initializing .env..." -ForegroundColor Green
    try {
        make init
    } catch {
        Write-Warning "Could not run 'make init'. Ensure GNU Make is installed or create .env manually."
    }
}

# Download ISOs to the pre-install folder
Write-Host "Downloading required ISOs..." -ForegroundColor Cyan
$isoDir = Join-Path $InstallDir 'isos'
if (-not (Test-Path $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }

$downloadIsos = Join-Path $ScriptRoot 'download-isos.ps1'
Run-PowerShellScript -ScriptPath $downloadIsos -Arguments @('-IsoDir', $isoDir)

# Update .env with paths
$envPath = Join-Path $RepoDir '.env'
if (Test-Path $envPath) {
    Write-Host "Updating .env with RepoDir and InstallDir paths..." -ForegroundColor Cyan
    $lines   = Get-Content $envPath
    $updated = @()
    foreach ($line in $lines) {
        if     ($line -match '^(LAB_ROOT)=')       { $updated += "LAB_ROOT=$RepoDir" }
        elseif ($line -match '^(REPO_ROOT)=')      { $updated += "REPO_ROOT=$RepoDir" }
        elseif ($line -match '^(ISO_DIR)=')        { $updated += "ISO_DIR=$isoDir" }
        elseif ($line -match '^(ARTIFACTS_DIR)=')  { $updated += "ARTIFACTS_DIR=" + (Join-Path $InstallDir 'artifacts') }
        elseif ($line -match '^(TEMP_DIR)=')       { $updated += "TEMP_DIR="      + (Join-Path $InstallDir 'temp') }
        else                                       { $updated += $line }
    }
    $updated | Set-Content $envPath -Encoding ASCII
}

# Bring up the lab
if (Ensure-Packer) {
    Write-Host "Launching lab bring-up (this may take a while)..." -ForegroundColor Cyan
    try {
        make up-all
    } catch {
        Write-Warning "'make up-all' failed. Attempting to run the orchestration script directly..."
        Run-PowerShellScript -ScriptPath (Join-Path $ScriptRoot 'lab-up.ps1')
    }
} else {
    Write-Warning "Skipping lab bring-up because Packer is missing."
}

Write-Host "SOC-9000 installation complete." -ForegroundColor Green
