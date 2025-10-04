<#
.SYNOPSIS
    Deployment helper - Validates and deploys SOC-9000 lab

.DESCRIPTION
    Pre-deployment checks and orchestrated deployment of the SOC-9000 lab.

.PARAMETER ValidateOnly
    Only run validation checks without deploying

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\deploy.ps1 -ValidateOnly
    .\deploy.ps1 -Force
#>

#requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot

# Import utilities
Import-Module (Join-Path $RepoRoot 'modules' 'SOC9000.Utils.psm1') -Force
Import-Module (Join-Path $RepoRoot 'modules' 'SOC9000.Platform.psm1') -Force

Write-Banner -Title "SOC-9000 Deployment Helper" -Color Cyan

# ==================== VALIDATION ====================
Write-InfoLog "Running pre-deployment validation..."

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7.2+ required. Current: $($PSVersionTable.PSVersion)"
}
Write-SuccessLog "PowerShell version: $($PSVersionTable.PSVersion)"

# Check prerequisites
$tools = @(
    @{ Name = 'packer'; Hint = 'Install: winget install HashiCorp.Packer' },
    @{ Name = 'kubectl'; Hint = 'Install: winget install Kubernetes.kubectl' },
    @{ Name = 'git'; Hint = 'Install: winget install Git.Git' }
)

foreach ($tool in $tools) {
    try {
        $cmd = Get-Command $tool.Name -ErrorAction Stop
        Write-SuccessLog "$($tool.Name): $($cmd.Source)"
    }
    catch {
        Write-ErrorLog "$($tool.Name) not found. $($tool.Hint)"
        throw
    }
}

# Check VMware Workstation
$vmwareVersion = Get-VMwareWorkstationVersion
if (-not $vmwareVersion) {
    Write-ErrorLog "VMware Workstation not found"
    throw "VMware Workstation 17+ required"
}
Write-SuccessLog "VMware Workstation: $vmwareVersion"

# Check WSL
try {
    wsl -l -v 2>$null | Out-Null
    Write-SuccessLog "WSL: Available"
}
catch {
    Write-ErrorLog "WSL not available. Run: wsl --install -d Ubuntu"
    throw
}

# Check .env file
$envPath = Join-Path $RepoRoot '.env'
if (-not (Test-Path $envPath)) {
    $examplePath = Join-Path $RepoRoot '.env.example'
    if (Test-Path $examplePath) {
        Write-WarnLog ".env not found. Copying from .env.example..."
        Copy-Item $examplePath $envPath
        Write-InfoLog "Review .env file and re-run deployment"
        exit 2
    }
    else {
        throw ".env file not found at $RepoRoot"
    }
}
Write-SuccessLog ".env: Found"

# Check critical .env variables
$envMap = Get-DotEnvConfig -Path $envPath
$requiredVars = @('INSTALL_ROOT', 'ISO_DIR')
foreach ($var in $requiredVars) {
    if (-not $envMap[$var]) {
        throw ".env missing required variable: $var"
    }
    Write-SuccessLog "$var = $($envMap[$var])"
}

Write-SuccessLog "Validation complete!"

if ($ValidateOnly) {
    Write-InfoLog "Validation-only mode. Exiting."
    exit 0
}

# ==================== DEPLOYMENT ====================
Write-Banner -Title "Ready to Deploy" -Color Yellow

if (-not $Force) {
    $response = Read-Host "Deploy SOC-9000 lab? (y/N)"
    if ($response -ne 'y') {
        Write-InfoLog "Deployment cancelled by user"
        exit 3
    }
}

Write-InfoLog "Starting deployment..."

# Run main orchestrator
$setupScript = Join-Path $RepoRoot 'setup-soc9000.ps1'
if (-not (Test-Path $setupScript)) {
    throw "setup-soc9000.ps1 not found at $RepoRoot"
}

& pwsh -NoProfile -ExecutionPolicy Bypass -File $setupScript -All -Verbose

if ($LASTEXITCODE -ne 0) {
    Write-ErrorLog "Deployment failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Banner -Title "Deployment Complete" -Color Green
Write-InfoLog "Run 'scripts/utils/lab-status.ps1' to view lab status"

exit 0
