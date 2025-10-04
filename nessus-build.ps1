<#
.SYNOPSIS
    SOC-9000 Nessus VM Builder

.DESCRIPTION
    Builds a Nessus vulnerability scanner VM image using Packer and VMware.
    Supports standalone execution or integration with the main orchestrator.

.PARAMETER Verbose
    Show detailed output during the build process.

.EXAMPLE
    .\nessus-build.ps1 -Verbose

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7.2+, Packer, VMware Workstation
    Status: Stub implementation - TODO: Add Packer template for Nessus
#>

#requires -Version 7.2

[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 30
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
$NessusOut = Join-Path $VmRoot $Config.Build.VMNames.Nessus

# Log directory
$LogDir = Join-Path $InstallRoot $Config.Paths.LogDirectory 'packer'
Confirm-Directory -Path $LogDir

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogDir "nessus-$timestamp.log"

# ==================== BANNER ====================

Write-Banner -Title "SOC-9000 Nessus VM Builder" -Subtitle "Vulnerability Scanner" -Color Cyan

# ==================== AUTOMATED NESSUS BUILD ====================
# ==================== PREREQUISITES ====================

Write-InfoLog "Checking prerequisites..."

# Find Packer
$PackerExe = Find-PackerExecutable
if (-not $PackerExe) {
    Write-ErrorLog "Packer executable not found. Install with: winget install HashiCorp.Packer"
    exit 1
}

# ==================== ISO DISCOVERY ====================

Write-InfoLog "Looking for Nessus ISO..."

$IsoNessus = $null
$IsoNessusName = if ($env:ISO_NESSUS) { $env:ISO_NESSUS } else { $EnvMap['ISO_NESSUS'] }

if ($IsoNessusName) {
    $IsoNessus = Join-Path $IsoRoot $IsoNessusName
}

if (-not $IsoNessus -or -not (Test-Path -LiteralPath $IsoNessus)) {
    $found = Find-IsoFile -Directory $IsoRoot -Patterns $Config.ISOs.Patterns.Nessus
    if ($found) {
        $IsoNessus = $found.FullName
        $IsoNessusName = $found.Name
    }
}

if (-not $IsoNessus -or -not (Test-Path -LiteralPath $IsoNessus)) {
    Write-ErrorLog "Nessus ISO not found in $IsoRoot"
    Write-InfoLog "Download Nessus and place it in the ISO directory"
    exit 1
}

Write-SuccessLog "Found Nessus ISO: $IsoNessusName"

# ==================== TEMPLATE CONFIGURATION ====================

$NtplPath = Join-Path $RepoRoot 'packer' 'nessus' 'nessus.pkr.hcl'
Assert-FileExists -Path $NtplPath -Label "Nessus Packer template"

# ==================== OUTPUT DIRECTORY ====================

Confirm-Directory -Path $NessusOut
Write-InfoLog "Output directory: $NessusOut"

# ==================== PACKER BUILD ====================

$PackerVars = @{
    iso_path   = $IsoNessus
    output_dir = $NessusOut
}

Write-InfoLog "Starting Packer build (timeout: $TimeoutMinutes minutes)..."
Write-InfoLog "Log file: $LogFile"

try {
    Invoke-PackerInit -TemplatePath $NtplPath -PackerExe $PackerExe -LogPath $LogFile
    Invoke-PackerValidate -TemplatePath $NtplPath -PackerExe $PackerExe -LogPath $LogFile -Variables $PackerVars
    Invoke-PackerBuild -TemplatePath $NtplPath -PackerExe $PackerExe -LogPath $LogFile -Variables $PackerVars -TimeoutMinutes $TimeoutMinutes

    # ==================== ARTIFACT VERIFICATION ====================

    Write-InfoLog "Verifying VM artifacts..."

    $Targets = @(
        @{ Name = 'Nessus'; Directory = $NessusOut; Pattern = '*.vmx' }
    )

    $Artifacts = Wait-ForVMxArtifacts -Targets $Targets -MaxWaitSeconds 120

    # ==================== SAVE ARTIFACT STATE ====================

    $StateDir = Join-Path $InstallRoot $Config.Paths.StateDirectory
    Confirm-Directory -Path $StateDir

    $ArtifactInfo = @{
        name      = 'Nessus'
        vmx       = $Artifacts['Nessus']
        timestamp = (Get-Date -Format 'o')
    }

    $ArtifactFile = Join-Path $StateDir 'nessus-artifact.json'
    $ArtifactInfo | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ArtifactFile -Encoding UTF8

    # ==================== SUCCESS ====================

    Write-Banner -Title "Nessus VM Build Complete" -Color Green
    Write-SuccessLog "VMX: $($Artifacts['Nessus'])"
    Write-SuccessLog "Log: $LogFile"
    Write-SuccessLog "Artifact state: $ArtifactFile"

    exit 0
}
catch {
    Write-ErrorLog "Nessus build failed: $($_.Exception.Message)"
    Write-ErrorLog "Log file: $LogFile"
    exit 1
}
