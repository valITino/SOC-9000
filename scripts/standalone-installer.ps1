# SOC-9000 - standalone-installer.ps1
<#
    One-click installation for SOC-9000. Clones the repository, downloads ISOs,
    and launches lab bring-up (`make up-all`). Run **as Administrator**.
    Compatible with Windows PowerShell 5.1 and PowerShell 7.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "", Justification="User-facing colored output")]
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

# Determine if running on Windows
if (Test-Path variable:IsWindows) {
    $IsWindowsOS = $IsWindows
} else {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $IsWindowsOS = $true
    } elseif ($PSVersionTable.Platform) {
        $IsWindowsOS = $PSVersionTable.Platform -eq 'Win32NT'
    } else {
        $IsWindowsOS = $true
    }
}

function Get-ProjectRoot {
    try {
        if ($script:PSScriptRoot) {
            $leaf = Split-Path -Leaf $script:PSScriptRoot
            if ($leaf -ieq 'scripts') {
                return (Split-Path -Parent $script:PSScriptRoot)
            } else {
                return $script:PSScriptRoot
            }
        }
    } catch {
        Write-Verbose $_
    }

    $def = $MyInvocation.MyCommand.Definition
    if ($def -and (Test-Path $def)) {
        $dir  = Split-Path -Parent $def
        $leaf = Split-Path -Leaf $dir
        if ($leaf -ieq 'scripts') {
            return (Split-Path -Parent $dir)
        } else {
            return $dir
        }
    }

    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $exeDir  = [System.IO.Path]::GetDirectoryName($exePath)
    return $exeDir
}

$ProjectRoot = Get-ProjectRoot
$ScriptsDir  = Join-Path $ProjectRoot 'scripts'

function Test-Administrator {
    if ($IsWindowsOS) {
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

function Test-Git {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git is not installed or not in PATH. Please install Git and retry."
        exit 1
    }
}

function Test-Make {
    if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
        Write-Warning "GNU Make was not found after prerequisite installation."
    }
}

function Test-Packer {
    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
        Write-Warning "HashiCorp Packer was not found. Lab bring-up cannot proceed."
        return $false
    }
    return $true
}

function Invoke-PowerShellScript {
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

Write-Host "== SOC-9000 Standalone Installer ==" -ForegroundColor Cyan
Test-Administrator
    Test-Git

# Prerequisites
if (-not $SkipPrereqs) {
    if ($PSCmdlet.ShouldProcess("Install prerequisites")) {
        if ($IsWindowsOS) {
            try {
                Write-Host "Checking prerequisites..." -ForegroundColor Cyan
                $prereqPath = Join-Path $ScriptsDir 'install-prereqs.ps1'
                Invoke-PowerShellScript -ScriptPath $prereqPath
            } catch {
                Write-Warning "Prerequisite installation script failed. Continuing may result in errors."
            }
        } else {
            Write-Warning "Non-Windows host detected; skipping prerequisite installation."
        }
    }
}
    Test-Make

# Directories
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
if (-not (Test-Path $RepoDir))    { New-Item -ItemType Directory -Path $RepoDir    -Force | Out-Null }

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$RepoDir    = [System.IO.Path]::GetFullPath($RepoDir)

Write-Host "Pre-install directory: $InstallDir" -ForegroundColor Cyan
Write-Host "Repository directory: $RepoDir"    -ForegroundColor Cyan

# Clone or update repo
if (-not $SkipClone) {
    if ($PSCmdlet.ShouldProcess("Clone or update SOC-9000 repository")) {
        $gitDir = Join-Path $RepoDir '.git'
        if (Test-Path $gitDir) {
            Write-Host "SOC-9000 repository already exists. Pulling latest changes..." -ForegroundColor Green
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
            Write-Host "Cloning SOC-9000 repository..." -ForegroundColor Green
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

# Operate from repo root
Set-Location $RepoDir

# Initialize .env if missing
if (-not (Test-Path ".env")) {
    Write-Host "Initializing .env..." -ForegroundColor Green
    try { make init } catch { Write-Warning "Could not run 'make init'. Ensure GNU Make is installed or create .env manually." }
}

# Download ISOs
if (-not $SkipIsoDownload) {
    $isoDir = Join-Path $InstallDir 'isos'
    if (-not (Test-Path $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }
    if ($PSCmdlet.ShouldProcess("Download ISOs to $isoDir")) {
        $downloadIsos = Join-Path $ScriptsDir 'download-isos.ps1'
                Invoke-PowerShellScript -ScriptPath $downloadIsos -Arguments @('-IsoDir', $isoDir)
    }
}

# Update .env paths
$envPath = Join-Path $RepoDir '.env'
if (Test-Path $envPath) {
    Write-Host "Updating .env with RepoDir and InstallDir paths..." -ForegroundColor Cyan
    $lines   = Get-Content $envPath
    $updated = @()
    foreach ($line in $lines) {
        if     ($line -match '^(LAB_ROOT)=')      { $updated += "LAB_ROOT=$RepoDir" }
        elseif ($line -match '^(REPO_ROOT)=')     { $updated += "REPO_ROOT=$RepoDir" }
        elseif ($line -match '^(ISO_DIR)=')       { $updated += "ISO_DIR=" + (Join-Path $InstallDir 'isos') }
        elseif ($line -match '^(ARTIFACTS_DIR)=') { $updated += "ARTIFACTS_DIR=" + (Join-Path $InstallDir 'artifacts') }
        elseif ($line -match '^(TEMP_DIR)=')      { $updated += "TEMP_DIR="      + (Join-Path $InstallDir 'temp') }
        else                                      { $updated += $line }
    }
    $updated | Set-Content $envPath -Encoding ASCII
}

# Bring up lab
if (-not $SkipBringUp) {
    if (Test-Packer) {
        if ($PSCmdlet.ShouldProcess("Run 'make up-all'")) {
            try { make up-all }
            catch {
                Write-Warning "'make up-all' failed. Attempting to run orchestration script directly..."
                Invoke-PowerShellScript -ScriptPath (Join-Path $ScriptsDir 'lab-up.ps1')
            }
        }
    } else {
        Write-Warning "Skipping lab bring-up because Packer is missing."
    }
}

Write-Host "SOC-9000 installation complete." -ForegroundColor Green