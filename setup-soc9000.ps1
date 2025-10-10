<#
.SYNOPSIS
    SOC-9000 Lab Setup Orchestrator

.DESCRIPTION
    Main orchestrator script for building SOC-9000 Lab VMs.
    Supports interactive menu or CLI parameter-driven execution.

    This script starts in PowerShell 5.1, installs PowerShell 7 as a prerequisite,
    then re-executes itself in PowerShell 7 to continue with the setup.

.PARAMETER All
    Build all VM images (Ubuntu, Windows, Nessus, pfSense).

.PARAMETER Ubuntu
    Build Ubuntu container host VM only.

.PARAMETER Windows
    Build Windows 11 victim VM only.

.PARAMETER Nessus
    Build Nessus vulnerability scanner VM only (stub).

.PARAMETER PfSense
    Build pfSense firewall VM only (stub).

.PARAMETER PrereqsOnly
    Check prerequisites only, do not build VMs.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER NonInteractive
    Run without any user interaction (use with -Force).

.EXAMPLE
    .\setup-soc9000.ps1
    # Interactive menu

.EXAMPLE
    .\setup-soc9000.ps1 -All -Verbose
    # Build all VMs with verbose output

.EXAMPLE
    .\setup-soc9000.ps1 -Ubuntu -Windows -Verbose
    # Build only Ubuntu and Windows VMs

.EXAMPLE
    .\setup-soc9000.ps1 -PrereqsOnly
    # Check prerequisites only

.NOTES
    Version: 1.1.0
    Requires: PowerShell 5.1+ (auto-upgrades to PowerShell 7)
    Additional Requirements: Packer, VMware Workstation
#>

#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$All,
    [switch]$Ubuntu,
    [switch]$Windows,
    [switch]$Nessus,
    [switch]$PfSense,
    [switch]$PrereqsOnly,
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$SkipPowerShellUpgrade  # Internal parameter to prevent infinite loops
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================== POWERSHELL VERSION CHECK ====================

# Check if running in PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7 -and -not $SkipPowerShellUpgrade) {
    Write-Host ""
    Write-Host "================= PowerShell Version Check =================" -ForegroundColor Cyan
    Write-Host "Current PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "PowerShell 7+ is required for SOC-9000 Lab Setup" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Installing prerequisites (including PowerShell 7)..." -ForegroundColor Cyan
    Write-Host ""

    # Resolve script directory
    $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
    $PrereqScript = Join-Path $ScriptDir 'scripts' 'setup' 'install-prereqs.ps1'

    # Check if prerequisite script exists
    if (-not (Test-Path -LiteralPath $PrereqScript)) {
        Write-Host "ERROR: Prerequisite script not found at: $PrereqScript" -ForegroundColor Red
        Write-Host "Please ensure the SOC-9000 repository is complete." -ForegroundColor Red
        exit 1
    }

    # Run prerequisite installation script
    try {
        & $PrereqScript
        $prereqExitCode = $LASTEXITCODE

        if ($prereqExitCode -ne 0) {
            Write-Host ""
            Write-Host "ERROR: Prerequisite installation failed with exit code $prereqExitCode" -ForegroundColor Red
            Write-Host "Please resolve the issues above and try again." -ForegroundColor Red
            exit $prereqExitCode
        }
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: Failed to run prerequisite installation: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Find PowerShell 7
    Write-Host ""
    Write-Host "================= Switching to PowerShell 7 =================" -ForegroundColor Cyan

    $pwshPath = $null
    $pwshCandidates = @(
        (Get-Command pwsh -ErrorAction SilentlyContinue).Path,
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        'C:\Program Files\PowerShell\7\pwsh.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($pwshCandidates.Count -gt 0) {
        $pwshPath = $pwshCandidates[0]
    }

    if (-not $pwshPath) {
        Write-Host ""
        Write-Host "ERROR: PowerShell 7 was installed but cannot be found." -ForegroundColor Red
        Write-Host "Please restart your PowerShell session and run this script again." -ForegroundColor Yellow
        Write-Host "Or manually run: pwsh -File `"$($MyInvocation.MyCommand.Path)`"" -ForegroundColor Yellow
        exit 1
    }

    # Re-exec in PowerShell 7 with all original parameters
    Write-Host "PowerShell 7 found at: $pwshPath" -ForegroundColor Green
    Write-Host "Re-executing script in PowerShell 7..." -ForegroundColor Cyan
    Write-Host ""

    # Build parameter list for re-execution
    $reexecArgs = @(
        '-NoLogo'
        '-File'
        $MyInvocation.MyCommand.Path
        '-SkipPowerShellUpgrade'  # Prevent infinite loop
    )

    # Add original parameters
    if ($All) { $reexecArgs += '-All' }
    if ($Ubuntu) { $reexecArgs += '-Ubuntu' }
    if ($Windows) { $reexecArgs += '-Windows' }
    if ($Nessus) { $reexecArgs += '-Nessus' }
    if ($PfSense) { $reexecArgs += '-PfSense' }
    if ($PrereqsOnly) { $reexecArgs += '-PrereqsOnly' }
    if ($Force) { $reexecArgs += '-Force' }
    if ($NonInteractive) { $reexecArgs += '-NonInteractive' }
    if ($VerbosePreference -eq 'Continue') { $reexecArgs += '-Verbose' }

    # Execute in PowerShell 7
    & $pwshPath @reexecArgs
    exit $LASTEXITCODE
}

# If we're here, we're running in PowerShell 7+
if (-not $SkipPowerShellUpgrade) {
    Write-Host ""
    Write-Host "Running in PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green
    Write-Host ""
}

# ==================== MODULE IMPORTS ====================

# Resolve script directory (handle both -File and -Command execution)
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

$ModulesDir = Join-Path $ScriptDir 'modules'

try {
    Import-Module (Join-Path $ModulesDir 'SOC9000.Utils.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $ModulesDir 'SOC9000.Build.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $ModulesDir 'SOC9000.Platform.psm1') -Force -ErrorAction Stop
}
catch {
    Write-Host "ERROR: Failed to import modules from $ModulesDir" -ForegroundColor Red
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}

# ==================== CONFIGURATION ====================

$ConfigPath = Join-Path $ScriptDir 'config' 'soc9000.config.psd1'
$Config = Import-PowerShellDataFile -LiteralPath $ConfigPath

# ==================== BANNER ====================

Write-Banner -Title "SOC-9000 Lab Setup Orchestrator" -Subtitle "Version $($Config.Version)" -Color Cyan

# ==================== PREREQUISITES CHECK ====================

function Test-Prerequisites {
    Write-InfoLog "Checking system prerequisites..."

    $issues = @()

    # PowerShell 7+
    if (-not (Test-PowerShell7Available)) {
        $issues += "PowerShell 7.2+ is required. Install with: winget install Microsoft.PowerShell"
    }
    else {
        Write-SuccessLog "PowerShell 7+ detected"
    }

    # Packer
    $packer = Find-PackerExecutable
    if (-not $packer) {
        $issues += "Packer not found. Install with: winget install HashiCorp.Packer"
    }
    else {
        Write-SuccessLog "Packer found: $packer"
    }

    # VMware Workstation
    if (-not (Test-VMwareWorkstationVersion -MinimumVersion $Config.Tools.Optional.VMwareWorkstation.MinVersion)) {
        $issues += "VMware Workstation $($Config.Tools.Optional.VMwareWorkstation.MinVersion)+ is required"
    }

    # Administrator
    if (-not (Test-IsAdministrator)) {
        $issues += "Administrator privileges required for some operations"
        Write-WarnLog "Running without administrator privileges - some features may not work"
    }
    else {
        Write-SuccessLog "Running as Administrator"
    }

    # Pending reboot
    if (Test-PendingReboot) {
        $issues += "System reboot is pending. Please reboot and try again."
    }

    if ($issues.Count -gt 0) {
        Write-ErrorLog "Prerequisites check failed:"
        $issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        return $false
    }

    Write-SuccessLog "All prerequisites satisfied"
    return $true
}

# ==================== INTERACTIVE MENU ====================

function Show-Menu {
    Write-Host ""
    Write-Host "What would you like to build?" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Build All (Ubuntu + Windows + Nessus + pfSense)" -ForegroundColor White
    Write-Host "  [2] Build Ubuntu only" -ForegroundColor White
    Write-Host "  [3] Build Windows only" -ForegroundColor White
    Write-Host "  [4] Build Nessus only (stub)" -ForegroundColor DarkGray
    Write-Host "  [5] Build pfSense only (stub)" -ForegroundColor DarkGray
    Write-Host "  [6] Prerequisites check only" -ForegroundColor White
    Write-Host "  [Q] Quit" -ForegroundColor White
    Write-Host ""

    $choice = Read-Host "Choose an option"
    return $choice
}

# ==================== BUILD EXECUTION ====================

function Invoke-VMBuild {
    param(
        [string]$BuildScript,
        [string]$VMName,
        [int]$StepNumber,
        [int]$TotalSteps
    )

    Write-Banner -Title "Step $StepNumber/$TotalSteps`: Build $VMName VM" -Color Cyan

    $scriptPath = Join-Path $ScriptDir $BuildScript
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-ErrorLog "$BuildScript not found at $scriptPath"
        return $false
    }

    try {
        if ($PSCmdlet.ShouldProcess($VMName, "Build VM")) {
            & $scriptPath -Verbose:$VerbosePreference
            if ($LASTEXITCODE -eq 0) {
                Write-SuccessLog "$VMName build completed successfully"
                return $true
            }
            elseif ($LASTEXITCODE -eq 2) {
                Write-WarnLog "$VMName build not implemented (stub)"
                return $true  # Don't fail on stubs
            }
            else {
                Write-ErrorLog "$VMName build failed with exit code $LASTEXITCODE"
                return $false
            }
        }
        return $true
    }
    catch {
        Write-ErrorLog "$VMName build failed: $($_.Exception.Message)"
        return $false
    }
}

# ==================== MAIN EXECUTION ====================

# Check prerequisites first
if (-not (Test-Prerequisites)) {
    Write-ErrorLog "Prerequisites check failed. Please resolve the issues above and try again."
    exit 1
}

if ($PrereqsOnly) {
    Write-SuccessLog "Prerequisites check complete. Exiting."
    exit 0
}

# Determine what to build
$buildUbuntu = $false
$buildWindows = $false
$buildNessus = $false
$buildPfSense = $false

if ($All) {
    $buildUbuntu = $true
    $buildWindows = $true
    $buildNessus = $true
    $buildPfSense = $true
}
else {
    $buildUbuntu = $Ubuntu.IsPresent
    $buildWindows = $Windows.IsPresent
    $buildNessus = $Nessus.IsPresent
    $buildPfSense = $PfSense.IsPresent
}

# Interactive menu if no parameters specified
if (-not ($buildUbuntu -or $buildWindows -or $buildNessus -or $buildPfSense)) {
    if ($NonInteractive) {
        Write-ErrorLog "No build targets specified and running in non-interactive mode."
        Write-InfoLog "Use -All, -Ubuntu, -Windows, -Nessus, or -PfSense parameters."
        exit 1
    }

    $choice = Show-Menu

    switch ($choice.ToUpper()) {
        '1' {
            $buildUbuntu = $true
            $buildWindows = $true
            $buildNessus = $true
            $buildPfSense = $true
        }
        '2' { $buildUbuntu = $true }
        '3' { $buildWindows = $true }
        '4' { $buildNessus = $true }
        '5' { $buildPfSense = $true }
        '6' {
            Write-SuccessLog "Prerequisites already checked above. Exiting."
            exit 0
        }
        'Q' {
            Write-InfoLog "User cancelled. Exiting."
            exit 3
        }
        default {
            Write-ErrorLog "Invalid option: $choice"
            exit 1
        }
    }
}

# Confirm before starting builds
if (-not $Force -and -not $NonInteractive) {
    $buildList = @()
    if ($buildUbuntu) { $buildList += "Ubuntu" }
    if ($buildWindows) { $buildList += "Windows" }
    if ($buildNessus) { $buildList += "Nessus" }
    if ($buildPfSense) { $buildList += "pfSense" }

    Write-Host ""
    Write-Host "About to build: $($buildList -join ', ')" -ForegroundColor Yellow
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -notmatch '^[yY]') {
        Write-InfoLog "User cancelled. Exiting."
        exit 3
    }
}

# Calculate total steps
$totalSteps = 0
if ($buildUbuntu) { $totalSteps++ }
if ($buildWindows) { $totalSteps++ }
if ($buildNessus) { $totalSteps++ }
if ($buildPfSense) { $totalSteps++ }

$currentStep = 0
$failures = @()

# Execute builds
if ($buildUbuntu) {
    $currentStep++
    if (-not (Invoke-VMBuild -BuildScript 'ubuntu-build.ps1' -VMName 'Ubuntu' -StepNumber $currentStep -TotalSteps $totalSteps)) {
        $failures += 'Ubuntu'
    }
}

if ($buildWindows) {
    $currentStep++
    if (-not (Invoke-VMBuild -BuildScript 'windows-build.ps1' -VMName 'Windows' -StepNumber $currentStep -TotalSteps $totalSteps)) {
        $failures += 'Windows'
    }
}

if ($buildNessus) {
    $currentStep++
    if (-not (Invoke-VMBuild -BuildScript 'nessus-build.ps1' -VMName 'Nessus' -StepNumber $currentStep -TotalSteps $totalSteps)) {
        $failures += 'Nessus'
    }
}

if ($buildPfSense) {
    $currentStep++
    if (-not (Invoke-VMBuild -BuildScript 'pfsense-build.ps1' -VMName 'pfSense' -StepNumber $currentStep -TotalSteps $totalSteps)) {
        $failures += 'pfSense'
    }
}

# ==================== SUMMARY ====================

Write-Host ""
Write-Banner -Title "SOC-9000 Setup Complete" -Color Green

if ($failures.Count -gt 0) {
    Write-ErrorLog "Some builds failed: $($failures -join ', ')"
    Write-InfoLog "Check the log files for details"
    exit 1
}
else {
    Write-SuccessLog "All requested VMs built successfully!"
    Write-InfoLog "Next steps:"
    Write-InfoLog "  1. Review VM configurations in VMware Workstation"
    Write-InfoLog "  2. Start the VMs and verify connectivity"
    Write-InfoLog "  3. Configure your SOC lab environment"
    exit 0
}
