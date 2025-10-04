<#
.SYNOPSIS
    SOC-9000 Windows VM Builder

.DESCRIPTION
    Builds a Windows 11 VM image using Packer and VMware.
    Supports standalone execution or integration with the main orchestrator.

.PARAMETER Verbose
    Show detailed output during the build process.

.EXAMPLE
    .\windows-build.ps1 -Verbose

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7.2+, Packer, VMware Workstation
#>

#requires -Version 7.2

[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================== MODULE IMPORTS ====================

$ModulesDir = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $ModulesDir 'SOC9000.Utils.psm1') -Force
Import-Module (Join-Path $ModulesDir 'SOC9000.Build.psm1') -Force
Import-Module (Join-Path $ModulesDir 'SOC9000.Platform.psm1') -Force

# ==================== CONFIGURATION ====================

$ConfigPath = Join-Path $PSScriptRoot 'config' 'soc9000.config.psd1'
$Config = Import-PowerShellDataFile -LiteralPath $ConfigPath

$RepoRoot = Get-RepositoryRoot
Set-Location $RepoRoot

$EnvFile = Join-Path $RepoRoot '.env'
$EnvMap = Get-DotEnvConfig -Path $EnvFile

# ==================== PATHS ====================

# Install root (ENV > .env > config default > fallback)
$InstallRoot = if ($env:INSTALL_ROOT) { $env:INSTALL_ROOT }
    elseif ($EnvMap['INSTALL_ROOT']) { $EnvMap['INSTALL_ROOT'] }
    elseif (Test-Path $Config.Paths.InstallRoot -PathType Container) { $Config.Paths.InstallRoot }
    elseif (Test-Path 'E:\') { 'E:\SOC-9000-Install' }
    else { 'C:\SOC-9000-Install' }

# ISO directory
$IsoRoot = if ($env:ISO_DIR) { $env:ISO_DIR }
    elseif ($EnvMap['ISO_DIR']) { $EnvMap['ISO_DIR'] }
    else { Join-Path $InstallRoot $Config.Paths.IsoDirectory }

# VM output directory
$VmRoot = Join-Path $InstallRoot $Config.Paths.VMDirectory
$WindowsOut = Join-Path $VmRoot $Config.Build.VMNames.Windows

# Log directory
$LogDir = Join-Path $InstallRoot $Config.Paths.LogDirectory 'packer'
Confirm-Directory -Path $LogDir

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogDir "windows-$timestamp.log"

# Packer cache
$CacheDir = Join-Path $InstallRoot $Config.Paths.CacheDirectory 'packer' 'windows'
Confirm-Directory -Path $CacheDir
$env:PACKER_CACHE_DIR = $CacheDir

# Packer temp
$TmpDir = Join-Path $InstallRoot 'tmp' 'packer' 'windows'
if (Test-Path $TmpDir) {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
Confirm-Directory -Path $TmpDir
$env:PACKER_TMP_DIR = $TmpDir

# Disable colored output globally
$env:PACKER_NO_COLOR = '1'

# ==================== BANNER ====================

Write-Banner -Title "SOC-9000 Windows VM Builder" -Subtitle "Windows 11 Victim Image" -Color Cyan

# ==================== PREREQUISITES ====================

Write-InfoLog "Checking prerequisites..."

# Find Packer
$PackerExe = Find-PackerExecutable
if (-not $PackerExe) {
    Write-ErrorLog "Packer executable not found. Install with: winget install HashiCorp.Packer"
    exit 1
}

try {
    $vOut = & $PackerExe -v 2>&1
    Write-SuccessLog "Packer: $($vOut -join ' ')"
}
catch {
    Write-WarnLog "Could not query Packer version."
}

# ==================== ISO DISCOVERY ====================

Write-InfoLog "Looking for Windows ISO..."

$IsoWindows = $null
$IsoWindowsName = if ($env:ISO_WINDOWS) { $env:ISO_WINDOWS } else { $EnvMap['ISO_WINDOWS'] }

if ($IsoWindowsName) {
    $IsoWindows = Join-Path $IsoRoot $IsoWindowsName
}

if (-not $IsoWindows -or -not (Test-Path -LiteralPath $IsoWindows)) {
    $found = Find-IsoFile -Directory $IsoRoot -Patterns $Config.ISOs.Patterns.Windows
    if ($found) {
        $IsoWindows = $found.FullName
        $IsoWindowsName = $found.Name
    }
}

if (-not $IsoWindows -or -not (Test-Path -LiteralPath $IsoWindows)) {
    Write-ErrorLog "Windows 11 ISO not found in $IsoRoot"
    Write-InfoLog "Download Windows 11 ISO and place it in the ISO directory"
    exit 1
}

Write-SuccessLog "Found Windows ISO: $IsoWindowsName"

# ==================== TEMPLATE CONFIGURATION ====================

$WtplPath = Join-Path $RepoRoot 'packer' 'windows-victim' 'windows.pkr.hcl'
Assert-FileExists -Path $WtplPath -Label "Windows Packer template"

# ==================== OUTPUT DIRECTORY ====================

Confirm-Directory -Path $WindowsOut
Write-InfoLog "Output directory: $WindowsOut"

# ==================== PACKER BUILD ====================

$PackerVars = @{
    iso_path   = $IsoWindows
    output_dir = $WindowsOut
}

Write-InfoLog "Starting Packer build (timeout: $TimeoutMinutes minutes)..."
Write-InfoLog "Log file: $LogFile"

try {
    Invoke-PackerInit -TemplatePath $WtplPath -PackerExe $PackerExe -LogPath $LogFile
    Invoke-PackerValidate -TemplatePath $WtplPath -PackerExe $PackerExe -LogPath $LogFile -Variables $PackerVars
    Invoke-PackerBuild -TemplatePath $WtplPath -PackerExe $PackerExe -LogPath $LogFile -Variables $PackerVars -TimeoutMinutes $TimeoutMinutes

    # ==================== ARTIFACT VERIFICATION ====================

    Write-InfoLog "Verifying VM artifacts..."

    $Targets = @(
        @{ Name = 'Windows'; Directory = $WindowsOut; Pattern = '*.vmx' }
    )

    $Artifacts = Wait-ForVMxArtifacts -Targets $Targets -MaxWaitSeconds 120

    # ==================== SAVE ARTIFACT STATE ====================

    $StateDir = Join-Path $InstallRoot $Config.Paths.StateDirectory
    Confirm-Directory -Path $StateDir

    $ArtifactInfo = @{
        name      = 'Windows'
        vmx       = $Artifacts['Windows']
        timestamp = (Get-Date -Format 'o')
    }

    $ArtifactFile = Join-Path $StateDir 'windows-artifact.json'
    $ArtifactInfo | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ArtifactFile -Encoding UTF8

    # ==================== SUCCESS ====================

    Write-Banner -Title "Windows VM Build Complete" -Color Green
    Write-SuccessLog "VMX: $($Artifacts['Windows'])"
    Write-SuccessLog "Log: $LogFile"
    Write-SuccessLog "Artifact state: $ArtifactFile"

    exit 0
}
catch {
    Write-ErrorLog "Windows build failed: $($_.Exception.Message)"
    Write-ErrorLog "Log file: $LogFile"
    exit 1
}
