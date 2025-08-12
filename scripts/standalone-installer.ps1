# SOC-9000 - standalone-installer.ps1
<#
    One‑click installation for SOC‑9000. Clones the repository, downloads ISOs,
    and launches lab bring‑up (`make up-all`). Run **as Administrator**.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDir = "E:\\SOC-9000-Pre-Install",
    [string]$RepoDir    = "E:\\SOC-9000",
    [switch]$SkipPrereqs,
    [switch]$SkipClone,
    [switch]$SkipIsoDownload,
    [switch]$SkipBringUp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Robust project root detection (works for PS1 and PS2EXE .exe) ---
function Get-ProjectRoot {
    # 1) Prefer $PSScriptRoot when present (PS1)
    if ($script:PSScriptRoot) {
        $leaf = Split-Path -Leaf $script:PSScriptRoot
        if ($leaf -ieq 'scripts') {
            return (Split-Path -Parent $script:PSScriptRoot)   # repo root
        } else {
            return $script:PSScriptRoot
        }
    }
    # 2) $MyInvocation fallback
    $def = $MyInvocation.MyCommand.Definition
    if ($def -and (Test-Path $def)) {
        $dir = Split-Path -Parent $def
        $leaf = Split-Path -Leaf $dir
        return ($leaf -ieq 'scripts') ? (Split-Path -Parent $dir) : $dir
    }
    # 3) EXE location
    $exeDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    return $exeDir
}

$ProjectRoot = Get-ProjectRoot
$ScriptsDir  = Join-Path $ProjectRoot 'scripts'

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

Write-Output "== SOC-9000 Standalone Installer =="
Require-Administrator
Ensure-Git

# Prereqs (use absolute path under repo root, works for EXE or PS1)
if (-not $SkipPrereqs) {
    if ($PSCmdlet.ShouldProcess("Install prerequisites")) {
        if ($IsWindows) {
            try {
                Write-Output "Checking prerequisites..."
                $prereqPath = Join-Path $ScriptsDir 'install-prereqs.ps1'
                Run-PowerShellScript -ScriptPath $prereqPath
            } catch {
                Write-Warning "Prerequisite installation script failed. Continuing may result in errors."
            }
        } else {
            Write-Warning "Non-Windows host detected; skipping prerequisite installation."
        }
    }
}
Ensure-Make

# Ensure directories exist and normalize to absolute paths
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
if (-not (Test-Path $RepoDir))    { New-Item -ItemType Directory -Path $RepoDir    -Force | Out-Null }

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$RepoDir    = [System.IO.Path]::GetFullPath($RepoDir)

Write-Output "Pre‑install directory: $InstallDir"
Write-Output "Repository directory: $RepoDir"

# Clone or update repository
if (-not $SkipClone) {
    if ($PSCmdlet.ShouldProcess("Clone or update repo")) {
        $gitDir = Join-Path $RepoDir '.git'
        if (Test-Path $gitDir) {
            Write-Output "SOC-9000 repository already exists. Pulling latest changes..."
            Push-Location $RepoDir
            try {
                git pull --ff-only
                if ($LASTEXITCODE -ne 0) { Write-Warning "git pull returned exit code $LASTEXITCODE. Proceeding with existing repository." }
            } catch {
                Write-Warning "Failed to pull latest changes. Proceeding with existing repository."
            } finally {
                Pop-Location
            }
        } else {
            if ((Get-ChildItem -Path $RepoDir -Force | Measure-Object).Count -gt 0) {
                Write-Error "Repository directory $RepoDir exists and is not a Git repository."
                exit 1
            }
            Write-Output "Cloning SOC-9000 repository..."
            try {
                git clone "https://github.com/valITino/SOC-9000.git" $RepoDir
                if ($LASTEXITCODE -ne 0) { Write-Error "git clone returned exit code $LASTEXITCODE."; exit 1 }
            } catch {
                Write-Error "Failed to clone repository: $_"
                exit 1
            }
        }
    }
}

# Operate from the repo root
Set-Location $RepoDir

# Initialize .env if missing and Makefile exists
$makefile = Join-Path $RepoDir 'Makefile'
if ((Test-Path $makefile) -and -not (Test-Path ".env")) {
    Write-Output "Initializing .env..."
    try {
        make init
        if ($LASTEXITCODE -ne 0) { Write-Warning "'make init' exited with code $LASTEXITCODE. Ensure GNU Make is installed or create .env manually." }
    } catch {
        Write-Warning "Could not run 'make init'. Ensure GNU Make is installed or create .env manually."
    }
}

# Download ISOs to the pre-install folder (use absolute helper path)
$isoDir = Join-Path $InstallDir 'isos'
if (-not $SkipIsoDownload) {
    if ($PSCmdlet.ShouldProcess("Download ISOs to $isoDir")) {
        Write-Output "Downloading required ISOs..."
        if (-not (Test-Path $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }
        $downloadIsos = Join-Path $ScriptsDir 'download-isos.ps1'
        Run-PowerShellScript -ScriptPath $downloadIsos -Arguments @('-IsoDir', $isoDir)
    }
}

# Update .env with paths
$envPath = Join-Path $RepoDir '.env'
if (Test-Path $envPath) {
    Write-Output "Updating .env with RepoDir and InstallDir paths..."
    $lines   = Get-Content $envPath
    $updated = @()
    foreach ($line in $lines) {
        if     ($line -match '^(LAB_ROOT)=')      { $updated += "LAB_ROOT=$RepoDir" }
        elseif ($line -match '^(REPO_ROOT)=')     { $updated += "REPO_ROOT=$RepoDir" }
        elseif ($line -match '^(ISO_DIR)=')       { $updated += "ISO_DIR=$isoDir" }
        elseif ($line -match '^(ARTIFACTS_DIR)=') { $updated += "ARTIFACTS_DIR=" + (Join-Path $InstallDir 'artifacts') }
        elseif ($line -match '^(TEMP_DIR)=')      { $updated += "TEMP_DIR="      + (Join-Path $InstallDir 'temp') }
        else                                      { $updated += $line }
    }
    $updated | Set-Content $envPath -Encoding ASCII
}

# Bring up the lab
if (-not $SkipBringUp) {
    if ($PSCmdlet.ShouldProcess("Run make up-all")) {
        if (Ensure-Packer) {
            Write-Output "Launching lab bring-up (this may take a while)..."
            try { make up-all }
            catch {
                Write-Warning "'make up-all' failed. Attempting to run the orchestration script directly..."
                Run-PowerShellScript -ScriptPath (Join-Path $ScriptsDir 'lab-up.ps1')
            }
        } else {
            Write-Warning "Skipping lab bring-up because Packer is missing."
        }
    }
}

Write-Output "SOC-9000 installation complete."
