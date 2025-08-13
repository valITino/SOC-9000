# SOC-9000 - standalone-installer.ps1
<#
    One-click installation for SOC-9000. Clones the repository, downloads ISOs,
    and launches lab bring-up. Run **as Administrator**.
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
    [switch]$SkipBringUp,
    [switch]$SkipHashCheck
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

# Embedded prerequisite installer populated during build
$EmbeddedPrereqs = @'
__INSTALL_PREREQS_EMBEDDED__
'@

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

function Test-Packer {
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
    $exit = 0
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
        $exit = $LASTEXITCODE
    } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
        $exit = $LASTEXITCODE
    } else {
        Write-Error "Neither pwsh nor powershell is available to run $ScriptPath. Please install PowerShell."
        exit 1
    }
    if ($exit -ne 0 -and $exit -ne 3010) {
        throw "Script $ScriptPath exited with code $exit"
    }
}

Write-Host "== SOC-9000 Standalone Installer ==" -ForegroundColor Cyan
Test-Administrator

# Prerequisites
if (-not $SkipPrereqs) {
    if ($PSCmdlet.ShouldProcess("Install prerequisites")) {
        if ($IsWindowsOS) {
            Write-Host "Checking prerequisites..." -ForegroundColor Cyan
            $prereqPath = Join-Path $ScriptsDir 'install-prereqs.ps1'
            if (Test-Path $prereqPath) {
                try {
                    Run-PowerShellScript -ScriptPath $prereqPath
                } catch {
                    Write-Error "Prerequisite installation script failed. Aborting."
                    exit 1
                }
            } elseif ($EmbeddedPrereqs.Trim()) {
                $tempPrereq = Join-Path ([System.IO.Path]::GetTempPath()) 'install-prereqs.ps1'
                Set-Content -Path $tempPrereq -Value $EmbeddedPrereqs -Encoding UTF8
                try {
                    Run-PowerShellScript -ScriptPath $tempPrereq
                } catch {
                    Write-Error "Prerequisite installation script failed. Aborting."
                    exit 1
                }
            } else {
                Write-Warning "Prerequisite script not found at $prereqPath. Skipping prerequisite installation."
            }
        } else {
            Write-Warning "Non-Windows host detected; skipping prerequisite installation."
        }
    }
}

Test-Git

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
            git pull --ff-only --quiet 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warning "git pull returned exit code $LASTEXITCODE. Proceeding with existing repository." }
            Pop-Location
        } else {
            if ((Get-ChildItem -Path $RepoDir -Force | Measure-Object).Count -gt 0) {
                Write-Error "Repository directory $RepoDir exists and is not a Git repository."
                exit 1
            }
            Write-Host "Cloning SOC-9000 repository..." -ForegroundColor Green
            git clone --quiet "https://github.com/valITino/SOC-9000.git" $RepoDir 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Error "git clone failed with exit code $LASTEXITCODE."
                exit 1
            }
        }
    }
}

# Operate from repo root
Set-Location $RepoDir
$ProjectRoot = $RepoDir
$ScriptsDir  = Join-Path $ProjectRoot 'scripts'

# Initialize .env if missing
if (-not (Test-Path ".env")) {
    if (Test-Path ".env.example") {
        Copy-Item ".env.example" ".env" -Force
        Write-Host "Created .env from template. Review and update before proceeding." -ForegroundColor Green
    } else {
        Write-Warning ".env.example not found; create .env manually."
    }
}

# Download ISOs
$isoDir = Join-Path $InstallDir 'isos'
if (-not (Test-Path $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }
if (-not $SkipIsoDownload) {
    if ($PSCmdlet.ShouldProcess("Download ISOs to $isoDir")) {
        $downloadIsos = Join-Path $ScriptsDir 'download-isos.ps1'
        Run-PowerShellScript -ScriptPath $downloadIsos -Arguments @('-IsoDir', $isoDir)
        Write-Host "Note: If pfSense/Win11/Nessus did not download automatically, their official pages were opened. Save the files into: $isoDir and re-run." -ForegroundColor Yellow
    }
}

# --- Download Summary ---
$requiredFiles = @(
    @{ Name = 'ubuntu-22.04.iso';          Path = Join-Path $isoDir 'ubuntu-22.04.iso' },
    @{ Name = 'pfsense.iso';               Path = Join-Path $isoDir 'pfsense.iso' },
    @{ Name = 'win11-eval.iso';            Path = Join-Path $isoDir 'win11-eval.iso' },
    @{ Name = 'nessus_latest_amd64.deb';   Path = Join-Path $isoDir 'nessus_latest_amd64.deb' }
)

Write-Host "`n== Download Summary ==" -ForegroundColor Cyan
$missingCount = 0
foreach ($file in $requiredFiles) {
    if (Test-Path $file.Path) {
        $sizeMB = [math]::Round((Get-Item $file.Path).Length / 1MB, 1)
        Write-Host ("[OK] {0} - {1} MB" -f $file.Name, $sizeMB) -ForegroundColor Green
    } else {
        Write-Host ("[MISSING] {0}" -f $file.Name) -ForegroundColor Red
        $missingCount++
    }
}

if ($missingCount -gt 0) {
    Write-Host "`nSome files are missing. Please download or copy them into: $isoDir" -ForegroundColor Yellow
    Write-Host "Then re-run the installer. Skipping checksum validation because not all files are present." -ForegroundColor Yellow
    $skipValidationDueToMissing = $true
} else {
    $skipValidationDueToMissing = $false
}

# Optional reminder after gated downloads
Write-Host "Note: If a file was opened in the browser (gated/expiring), save it to: $isoDir and re-run if needed." -ForegroundColor Yellow

# --- Checksum validation (auto, only if everything exists) ---
if (-not $SkipHashCheck -and -not $skipValidationDueToMissing) {
    $verifyScript   = Join-Path $ScriptsDir 'verify-hashes.ps1'
    $checksumsIso   = Join-Path $isoDir 'checksums.txt'
    $checksumsRoot  = Join-Path $ProjectRoot 'checksums.txt'
    $checksumsPath  = $null

    if (Test-Path $checksumsIso)      { $checksumsPath = $checksumsIso }
    elseif (Test-Path $checksumsRoot) { $checksumsPath = $checksumsRoot }

    if (Test-Path $verifyScript) {
        if ($checksumsPath) {
            Write-Host "Validating downloads against checksums: $checksumsPath" -ForegroundColor Cyan
            Run-PowerShellScript -ScriptPath $verifyScript -Arguments @('-IsoDir', $isoDir, '-ChecksumsPath', $checksumsPath, '-Strict')
            $code = $LASTEXITCODE
            if ($code -ne 0) {
                Write-Error "Checksum validation failed (exit code $code). Fix mismatches or run with -SkipHashCheck."
                exit 1
            } else {
                Write-Host "Checksum validation passed." -ForegroundColor Green
            }
        } else {
            Write-Warning "No checksums.txt found. Creating a template in: $checksumsIso"
            Run-PowerShellScript -ScriptPath $verifyScript -Arguments @('-IsoDir', $isoDir, '-OutPath', $checksumsIso)
            Write-Host "Tip: Fill $checksumsIso with vendor SHA256 values, then re-run the installer for strict validation." -ForegroundColor Yellow
        }
    } else {
        Write-Warning "verify-hashes.ps1 not found in scripts/. Skipping checksum validation."
    }
} elseif ($SkipHashCheck) {
    Write-Host "Skipping checksum validation (-SkipHashCheck)." -ForegroundColor Yellow
} else {
    Write-Host "Checksum validation skipped because some files are missing." -ForegroundColor Yellow
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
        if ($PSCmdlet.ShouldProcess("Bring up lab")) {
            Run-PowerShellScript -ScriptPath (Join-Path $ScriptsDir 'lab-up.ps1')
        }
    } else {
        Write-Warning "Skipping lab bring-up because Packer is missing."
    }
}

Write-Host "SOC-9000 installation complete." -ForegroundColor Green
