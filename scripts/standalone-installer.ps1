# SOC-9000 - standalone-installer.ps1

<#
    This script provides a one‑click installation experience for SOC‑9000.  It clones the
    repository into a configurable install directory, downloads required ISOs, and then
    launches the full lab bring‑up (`make up-all`).  Run this script from a PowerShell
    window **as Administrator**.

    Examples:
        # install to the default path (E:\SOC-9000-Pre-Install)
        pwsh -File .\scripts\standalone-installer.ps1

        # install to a custom path
        pwsh -File .\scripts\standalone-installer.ps1 -InstallDir "D:\Labs\SOC-9000"

    If you have the PS2EXE module installed, you can compile this script into an .exe
    using `scripts/build-standalone-exe.ps1`.
#>
[CmdletBinding()] param(
    # Where prerequisite files (ISOs, artifacts, temp) will live.  This folder is
    # separate from the repository itself to avoid confusion.  Defaults to
    # E:\SOC-9000-Pre-Install.  It will be created if it does not exist.
    [string]$InstallDir = "E:\\SOC-9000-Pre-Install",
    
    # Where to clone the SOC‑9000 repository.  Many users prefer the repo to
    # reside directly under a volume root (e.g. E:\SOC-9000) while keeping
    # downloads elsewhere.  Defaults to E:\SOC-9000.  The repository will be
    # cloned or pulled into this directory.  It will be created if it does
    # not exist.
    [string]$RepoDir = "E:\\SOC-9000"
)

$ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest

function Require-Administrator {
    if ($IsWindows) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
            Write-Warning "This installer must be run as Administrator.  Right-click PowerShell and choose 'Run as administrator'."
            exit 1
        }
    } else {
        Write-Warning "Non-Windows platform detected; skipping Administrator check."
    }
}

function Ensure-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git is not installed or not in PATH.  Please install Git and retry."
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
    # Try to execute the given script using pwsh if available; otherwise fallback to Windows PowerShell
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    } else {
        Write-Error "Neither pwsh nor powershell is available to run $ScriptPath.  Please install PowerShell."
        exit 1
    }
}

# Entry point
Write-Host "== SOC-9000 Standalone Installer ==" -ForegroundColor Cyan
Require-Administrator
Ensure-Git

# Install prerequisites (GNU Make and PowerShell 7) using the helper script.  This
# ensures that the remainder of this installer can rely on make and pwsh.
if ($IsWindows) {
    Try {
        Write-Host "Checking prerequisites..." -ForegroundColor Cyan
        Run-PowerShellScript -ScriptPath "scripts/install-prereqs.ps1"
    } Catch {
        Write-Warning "Prerequisite installation script failed.  Continuing may result in errors."
    }
} else {
    Write-Warning "Non-Windows host detected; skipping prerequisite installation."
}
Ensure-Make

# Ensure the install directory exists and expand both paths to absolute paths
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$RepoDir    = [System.IO.Path]::GetFullPath($RepoDir)

Write-Host "Pre‑install directory: $InstallDir" -ForegroundColor Cyan
Write-Host "Repository directory: $RepoDir"    -ForegroundColor Cyan

# Clone or update the repository in RepoDir.  We always clone into RepoDir
# directly (not into a subfolder) so that the repo root is exactly the
# specified path.  If the directory already contains the repository, pull
# updates instead of recloning.
$gitDir = Join-Path $RepoDir '.git'
if (Test-Path $gitDir) {
    Write-Host "SOC-9000 repository already exists.  Pulling latest changes..." -ForegroundColor Green
    Push-Location $RepoDir
    git pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to pull latest changes. Proceeding with existing repository."
    }
    Pop-Location
} else {
    if (Test-Path $RepoDir) {
        if ((Get-ChildItem -Path $RepoDir -Force | Measure-Object).Count -gt 0) {
            Write-Error "Repository directory $RepoDir exists and is not a Git repository."; exit 1
        }
    }
    Write-Host "Cloning SOC-9000 repository..." -ForegroundColor Green
    try {
        git clone "https://github.com/valITino/SOC-9000.git" $RepoDir
    } catch {
        Write-Error "Failed to clone repository: $_"; exit 1
    }
}

# Change to repo directory for subsequent operations
Set-Location $RepoDir

# Initialize environment (.env) using make init if not present.  Because
# Makefile and scripts live in the repository directory (RepoDir), we
# invoke make from here.  If make is unavailable, warn but continue.
if (-not (Test-Path ".env")) {
    Write-Host "Initializing .env..." -ForegroundColor Green
    try {
        make init
    } catch {
        Write-Warning "Could not run 'make init'.  Ensure GNU Make is installed or create .env manually."
    }
}

# Download ISOs to the pre-install folder.  This uses the helper script
Write-Host "Downloading required ISOs..." -ForegroundColor Cyan
$isoDir = Join-Path $InstallDir 'isos'
if (-not (Test-Path $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }
Run-PowerShellScript -ScriptPath (Join-Path $RepoDir 'scripts/download-isos.ps1') -Arguments @('-IsoDir', $isoDir)

# Update .env with custom paths.  We set LAB_ROOT/REPO_ROOT to RepoDir and
# ISO_DIR/ARTIFACTS_DIR/TEMP_DIR to InstallDir subfolders.  We also update
# ISO-specific variables to point into the iso folder.  Preserve existing
# variables that are not path-related.
$envPath = Join-Path $RepoDir '.env'
if (Test-Path $envPath) {
    Write-Host "Updating .env with RepoDir and InstallDir paths..." -ForegroundColor Cyan
    $lines = Get-Content $envPath
    $updated = @()
    foreach ($line in $lines) {
        if ($line -match '^(LAB_ROOT)=') {
            $updated += "LAB_ROOT=$RepoDir"
        } elseif ($line -match '^(REPO_ROOT)=') {
            $updated += "REPO_ROOT=$RepoDir"
        } elseif ($line -match '^(ISO_DIR)=') {
            $updated += "ISO_DIR=$isoDir"
        } elseif ($line -match '^(ARTIFACTS_DIR)=') {
            $updated += "ARTIFACTS_DIR=" + (Join-Path $InstallDir 'artifacts')
        } elseif ($line -match '^(TEMP_DIR)=') {
            $updated += "TEMP_DIR=" + (Join-Path $InstallDir 'temp')
        } else {
            $updated += $line
        }
    }
    # Write updated lines back to file
    $updated | Set-Content $envPath -Encoding ASCII
}

# Bring up the lab
if (Ensure-Packer) {
    Write-Host "Launching lab bring-up (this may take a while)..."
    try {
        make up-all
    } catch {
        Write-Warning "'make' command failed.  Attempting to run the lab-up script directly..."
        # Fall back to running the PowerShell orchestration script directly
        Run-PowerShellScript -ScriptPath "scripts/lab-up.ps1"
    }
} else {
    Write-Warning "Skipping lab bring-up because Packer is missing."
}

Write-Host "SOC-9000 installation complete." -ForegroundColor Green

