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
    [string]$InstallDir = "E:\\SOC-9000-Pre-Install"
)

$ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest

function Require-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Warning "This installer must be run as Administrator.  Right-click PowerShell and choose 'Run as administrator'."
        exit 1
    }
}

function Ensure-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git is not installed or not in PATH.  Please install Git and retry."
        exit 1
    }
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
Try {
    Write-Host "Checking prerequisites..." -ForegroundColor Cyan
    Run-PowerShellScript -ScriptPath "scripts/install-prereqs.ps1"
} Catch {
    Write-Warning "Prerequisite installation script failed.  Continuing may result in errors."
}

# Normalize path
$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path
Write-Host "Install directory: $InstallDir"

# Create install directory
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Clone or update repository
$repoDir = Join-Path $InstallDir 'SOC-9000'
if (-not (Test-Path $repoDir)) {
    Write-Host "Cloning SOC-9000 repository..."
    git clone "https://github.com/valITino/SOC-9000.git" $repoDir
} else {
    Write-Host "SOC-9000 repository already exists.  Pulling latest changes..."
    Push-Location $repoDir
    git pull --ff-only
    Pop-Location
}

# Change to repo directory
Set-Location $repoDir

# Initialize environment
if (-not (Test-Path ".env")) {
    Write-Host "Initializing .env..."
    make init
}

# Download ISOs to local iso folder
$isoDir = Join-Path $InstallDir 'isos'
Write-Host "Ensuring ISO directory exists: $isoDir"
if (-not (Test-Path $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }
Write-Host "Downloading required ISOs..."
Run-PowerShellScript -ScriptPath "scripts/download-isos.ps1" -Arguments @("-IsoDir", $isoDir)

# Update .env with custom paths (basic replacement of ISO_DIR and LAB_ROOT)
$envPath = Join-Path $repoDir '.env'
if (Test-Path $envPath) {
    Write-Host "Updating .env with InstallDir and IsoDir..."
    $content = Get-Content $envPath
    $newContent = $content | ForEach-Object {
        $_.Replace('E:\\SOC-9000', $InstallDir) -replace 'isos\\', "${isoDir.Replace($InstallDir, '').TrimStart('\\')}\\"
    }
    $newContent | Set-Content $envPath
}

# Bring up the lab
Write-Host "Launching lab bring-up (this may take a while)..."
try {
    make up-all
} catch {
    Write-Warning "'make' command failed.  Attempting to run the lab-up script directly..."
    # Fall back to running the PowerShell orchestration script directly
    Run-PowerShellScript -ScriptPath "scripts/lab-up.ps1"
}

Write-Host "SOC-9000 installation complete." -ForegroundColor Green