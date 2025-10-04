<#
.SYNOPSIS
    SOC-9000 Ubuntu VM Builder

.DESCRIPTION
    Builds an Ubuntu Container Host VM image using Packer and VMware.
    Supports standalone execution or integration with the main orchestrator.

.PARAMETER Verbose
    Show detailed output during the build process.

.EXAMPLE
    .\ubuntu-build.ps1 -Verbose

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7.2+, Packer, VMware Workstation
#>

#requires -Version 7.2

[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 45
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
$UbuntuOut = Join-Path $VmRoot $Config.Build.VMNames.Ubuntu

# Log directory
$LogDir = Join-Path $InstallRoot $Config.Paths.LogDirectory 'packer'
Confirm-Directory -Path $LogDir

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogDir "ubuntu-$timestamp.log"

# Keys directory
$KeyDir = Join-Path $InstallRoot $Config.Paths.KeysDirectory
Confirm-Directory -Path $KeyDir
$KeyPath = Join-Path $KeyDir 'id_ed25519'
$PubPath = "$KeyPath.pub"

# Packer cache
$CacheDir = Join-Path $InstallRoot $Config.Paths.CacheDirectory 'packer' 'ubuntu'
Confirm-Directory -Path $CacheDir
$env:PACKER_CACHE_DIR = $CacheDir

# Packer temp
$TmpDir = Join-Path $InstallRoot 'tmp' 'packer' 'ubuntu'
if (Test-Path $TmpDir) {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
Confirm-Directory -Path $TmpDir
$env:PACKER_TMP_DIR = $TmpDir

# Disable colored output globally
$env:PACKER_NO_COLOR = '1'

# ==================== BANNER ====================

Write-Banner -Title "SOC-9000 Ubuntu VM Builder" -Subtitle "Container Host Image" -Color Cyan

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

# SSH keygen
Assert-CommandExists -CommandName 'ssh-keygen' -InstallHint 'Install Windows OpenSSH Client (optional feature)'

# Generate SSH keypair if needed
if (-not (Test-Path -LiteralPath $KeyPath)) {
    Write-InfoLog "Generating SSH keypair..."
    & ssh-keygen -t $Config.Build.SSH.KeyType -N '""' -f $KeyPath | Out-Null
    Write-SuccessLog "Generated SSH key: $KeyPath"
}

# ==================== ISO DISCOVERY ====================

Write-InfoLog "Looking for Ubuntu ISO..."

$IsoUbuntu = $null
$IsoUbuntuName = if ($env:ISO_UBUNTU) { $env:ISO_UBUNTU } else { $EnvMap['ISO_UBUNTU'] }

if ($IsoUbuntuName) {
    $IsoUbuntu = Join-Path $IsoRoot $IsoUbuntuName
}

if (-not $IsoUbuntu -or -not (Test-Path -LiteralPath $IsoUbuntu)) {
    $found = Find-IsoFile -Directory $IsoRoot -Patterns $Config.ISOs.Patterns.Ubuntu
    if ($found) {
        $IsoUbuntu = $found.FullName
        $IsoUbuntuName = $found.Name
    }
}

if (-not $IsoUbuntu -or -not (Test-Path -LiteralPath $IsoUbuntu)) {
    Write-ErrorLog "Ubuntu ISO not found in $IsoRoot"
    Write-InfoLog "Download Ubuntu Server 22.04 LTS and place it in the ISO directory"
    exit 1
}

Write-SuccessLog "Found Ubuntu ISO: $IsoUbuntuName"

# ==================== NETWORK CONFIGURATION ====================

# Resolve VMnet8 host IP (ENV > .env > auto-detect)
$Vmnet8Host = if ($env:VMNET8_HOSTIP) { $env:VMNET8_HOSTIP }
    elseif ($EnvMap['VMNET8_HOSTIP']) { $EnvMap['VMNET8_HOSTIP'] }
    else { $null }

if (-not $Vmnet8Host) {
    try {
        $ipObj = Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet8" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($ipObj) { $Vmnet8Host = $ipObj.IPAddress }
    }
    catch { }
}

if (-not $Vmnet8Host) {
    Write-ErrorLog "Cannot resolve VMnet8 host IP. Set VMNET8_HOSTIP in .env or check VMware vmnet8."
    exit 1
}

Write-SuccessLog "VMnet8 Host IP: $Vmnet8Host"

# Configure firewall rule for Packer HTTP server
try {
    New-NetFirewallRule -DisplayName "Packer HTTP Any (8800)" -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Config.Build.Packer.HttpPort -Profile Private -ErrorAction Stop | Out-Null
}
catch {
    # Ignore if rule exists or not admin
}

# ==================== TEMPLATE CONFIGURATION ====================

$UtplPath = Join-Path $RepoRoot 'packer' 'ubuntu-container' 'ubuntu-container.pkr.hcl'
Assert-FileExists -Path $UtplPath -Label "Ubuntu Packer template"

# HTTP seed directory
$SeedDir = Join-Path $RepoRoot 'packer' 'ubuntu-container' 'http'
Confirm-Directory -Path $SeedDir

$UserDataPath = Join-Path $SeedDir 'user-data'
$MetaDataPath = Join-Path $SeedDir 'meta-data'

Assert-FileExists -Path $UserDataPath -Label "user-data file"

# ==================== SSH KEY INJECTION ====================

Write-InfoLog "Preparing cloud-init seed files..."

$OriginalUserData = Get-Content -LiteralPath $UserDataPath -Raw
$PubKey = (Get-Content -LiteralPath $PubPath -Raw).Trim()
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    # Inject public key into user-data
    $PatchedUserData = $OriginalUserData.Replace('__PUBKEY__', $PubKey) -replace "`r", ""
    [System.IO.File]::WriteAllText($UserDataPath, $PatchedUserData, $Utf8NoBom)

    # Generate meta-data with fresh instance-id
    $InstanceId = 'iid-containerhost-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $MetaData = "instance-id: $InstanceId`nlocal-hostname: containerhost`n"
    [System.IO.File]::WriteAllText($MetaDataPath, $MetaData, $Utf8NoBom)

    Write-SuccessLog "Cloud-init seed files prepared"

    # ==================== OUTPUT DIRECTORY ====================

    Confirm-Directory -Path $UbuntuOut
    Write-InfoLog "Output directory: $UbuntuOut"

    # ==================== PACKER BUILD ====================

    $SshUsername = if ($env:UBUNTU_USERNAME) { $env:UBUNTU_USERNAME }
        elseif ($EnvMap['UBUNTU_USERNAME']) { $EnvMap['UBUNTU_USERNAME'] }
        else { $Config.Build.SSH.DefaultUbuntuUser }

    $PackerVars = @{
        iso_path             = $IsoUbuntu
        ssh_private_key_file = $KeyPath
        output_dir           = $UbuntuOut
        vmnet8_host_ip       = $Vmnet8Host
        ssh_username         = $SshUsername
    }

    Write-InfoLog "Starting Packer build (timeout: $TimeoutMinutes minutes)..."
    Write-InfoLog "Log file: $LogFile"

    Invoke-PackerInit -TemplatePath $UtplPath -PackerExe $PackerExe -LogPath $LogFile
    Invoke-PackerValidate -TemplatePath $UtplPath -PackerExe $PackerExe -LogPath $LogFile -Variables $PackerVars
    Invoke-PackerBuild -TemplatePath $UtplPath -PackerExe $PackerExe -LogPath $LogFile -Variables $PackerVars -TimeoutMinutes $TimeoutMinutes

    # ==================== ARTIFACT VERIFICATION ====================

    Write-InfoLog "Verifying VM artifacts..."

    $Targets = @(
        @{ Name = 'Ubuntu'; Directory = $UbuntuOut; Pattern = '*.vmx' }
    )

    $Artifacts = Wait-ForVMxArtifacts -Targets $Targets -MaxWaitSeconds 120

    # ==================== SAVE ARTIFACT STATE ====================

    $StateDir = Join-Path $InstallRoot $Config.Paths.StateDirectory
    Confirm-Directory -Path $StateDir

    $ArtifactInfo = @{
        name      = 'Ubuntu'
        vmx       = $Artifacts['Ubuntu']
        timestamp = (Get-Date -Format 'o')
    }

    $ArtifactFile = Join-Path $StateDir 'ubuntu-artifact.json'
    $ArtifactInfo | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ArtifactFile -Encoding UTF8

    # ==================== SUCCESS ====================

    Write-Banner -Title "Ubuntu VM Build Complete" -Color Green
    Write-SuccessLog "VMX: $($Artifacts['Ubuntu'])"
    Write-SuccessLog "Log: $LogFile"
    Write-SuccessLog "Artifact state: $ArtifactFile"

    exit 0
}
catch {
    Write-ErrorLog "Ubuntu build failed: $($_.Exception.Message)"
    Write-ErrorLog "Log file: $LogFile"
    exit 1
}
finally {
    # Restore the original user-data file (remove injected key)
    [System.IO.File]::WriteAllText($UserDataPath, $OriginalUserData, $Utf8NoBom)
    Write-InfoLog "Restored template user-data (placeholder version)"
}
