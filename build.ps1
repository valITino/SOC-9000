<#
.SYNOPSIS
    Build helper - Runs PSScriptAnalyzer and Pester tests

.DESCRIPTION
    Validates PowerShell code quality and runs all tests.
    Use this before committing changes.

.PARAMETER SkipAnalyzer
    Skip PSScriptAnalyzer checks

.PARAMETER SkipTests
    Skip Pester tests

.PARAMETER Fix
    Auto-fix PSScriptAnalyzer issues where possible

.EXAMPLE
    .\build.ps1
    .\build.ps1 -SkipAnalyzer
    .\build.ps1 -Fix
#>

#requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipTests,
    [switch]$Fix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot

Write-Host "SOC-9000 Build Helper" -ForegroundColor Cyan
Write-Host "===================="

# ==================== PSScriptAnalyzer ====================
if (-not $SkipAnalyzer) {
    Write-Host "`n[1/2] Running PSScriptAnalyzer..." -ForegroundColor Yellow

    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Write-Host "Installing PSScriptAnalyzer..." -ForegroundColor Cyan
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
    }

    $settingsPath = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'
    $results = Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Settings $settingsPath

    if ($results) {
        Write-Host "Found $($results.Count) PSScriptAnalyzer issue(s):" -ForegroundColor Red
        $results | Format-Table -AutoSize

        if ($Fix) {
            Write-Host "`nAttempting auto-fix..." -ForegroundColor Yellow
            Invoke-ScriptAnalyzer -Path $RepoRoot -Recurse -Settings $settingsPath -Fix
            Write-Host "Auto-fix completed. Re-run build to verify." -ForegroundColor Green
        }

        exit 1
    }
    else {
        Write-Host "PSScriptAnalyzer: PASS" -ForegroundColor Green
    }
}

# ==================== PESTER TESTS ====================
if (-not $SkipTests) {
    Write-Host "`n[2/2] Running Pester tests..." -ForegroundColor Yellow

    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge '5.0.0' })) {
        Write-Host "Installing Pester 5.x..." -ForegroundColor Cyan
        Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
    }

    $testsPath = Join-Path $RepoRoot 'tests'
    $config = New-PesterConfiguration
    $config.Run.Path = $testsPath
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = Join-Path $RepoRoot 'testresults.xml'

    $result = Invoke-Pester -Configuration $config

    if ($result.FailedCount -gt 0) {
        Write-Host "`nPester: FAILED ($($result.FailedCount) failed)" -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "`nPester: PASS ($($result.PassedCount) passed)" -ForegroundColor Green
    }
}

Write-Host "`n===================="
Write-Host "Build completed successfully!" -ForegroundColor Green
exit 0
