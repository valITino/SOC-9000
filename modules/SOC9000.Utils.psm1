<#
.SYNOPSIS
    SOC9000 Utilities Module - Logging, validation, paths, and retries.

.DESCRIPTION
    Provides common utility functions for the SOC-9000 Lab automation:
    - Logging (Info/Warn/Error helpers)
    - Input validation
    - Path resolution and management
    - Retry/backoff logic for network operations
    - Environment file parsing

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7.2+
#>

#requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================== LOGGING ====================

<#
.SYNOPSIS
    Writes an informational message.
#>
function Write-InfoLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[>] $Message" -ForegroundColor Cyan
}

<#
.SYNOPSIS
    Writes a success message.
#>
function Write-SuccessLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

<#
.SYNOPSIS
    Writes a warning message.
#>
function Write-WarnLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

<#
.SYNOPSIS
    Writes an error message.
#>
function Write-ErrorLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[X] $Message" -ForegroundColor Red
}

<#
.SYNOPSIS
    Writes a banner with title and optional subtitle.
#>
function Write-Banner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle = '',
        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )
    $line = '=' * 76
    Write-Host ''
    Write-Host $line -ForegroundColor $Color
    Write-Host ("  >> {0}" -f $Title) -ForegroundColor $Color
    if ($Subtitle) { Write-Host ("     {0}" -f $Subtitle) -ForegroundColor DarkGray }
    Write-Host $line -ForegroundColor $Color
}

<#
.SYNOPSIS
    Writes a panel with title and content lines.
#>
function Write-Panel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Lines
    )
    $line = '+' + ('-' * 74) + '+'
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ('| {0}' -f $Title) -ForegroundColor DarkCyan
    Write-Host $line -ForegroundColor DarkCyan
    foreach ($ln in $Lines) { Write-Host ('| {0}' -f $ln) }
    Write-Host $line -ForegroundColor DarkCyan
}

# ==================== ENVIRONMENT & CONFIGURATION ====================

<#
.SYNOPSIS
    Loads a .env file into a hashtable.

.DESCRIPTION
    Parses KEY=VALUE pairs from a .env file, ignoring comments and blank lines.

.PARAMETER Path
    Path to the .env file.

.EXAMPLE
    $config = Get-DotEnvConfig -Path 'C:\repo\.env'
#>
function Get-DotEnvConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $envMap = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $envMap }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim()
            if ($k) { $envMap[$k] = $v }
        }
    }
    return $envMap
}

<#
.SYNOPSIS
    Refreshes the current session's PATH from registry.
#>
function Update-SessionPath {
    [CmdletBinding()]
    param()

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = "$machinePath;$userPath"
}

# ==================== PATH UTILITIES ====================

<#
.SYNOPSIS
    Ensures a directory exists, creating it if necessary.
#>
function Confirm-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

<#
.SYNOPSIS
    Resolves the repository root directory.
#>
function Get-RepositoryRoot {
    [CmdletBinding()]
    param([string]$StartPath = $PSScriptRoot)

    # Navigate up to find repo root
    $current = $StartPath
    while ($current) {
        if (Test-Path (Join-Path $current '.git')) {
            return $current
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }

    # Fallback: assume scripts are in scripts/ subdirectory
    if ($StartPath -like '*\scripts*') {
        return (Resolve-Path (Join-Path $StartPath '..')).Path
    }

    return $StartPath
}

# ==================== VALIDATION ====================

<#
.SYNOPSIS
    Validates that a file exists, throwing if not.
#>
function Assert-FileExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'File'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

<#
.SYNOPSIS
    Validates that a tool/command is available in PATH.
#>
function Assert-CommandExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [string]$InstallHint = ''
    )

    try {
        Get-Command $CommandName -ErrorAction Stop | Out-Null
    }
    catch {
        $msg = "$CommandName not found."
        if ($InstallHint) { $msg += " $InstallHint" }
        throw $msg
    }
}

# ==================== RETRY LOGIC ====================

<#
.SYNOPSIS
    Invokes a script block with retry logic and exponential backoff.

.PARAMETER ScriptBlock
    The code to execute.

.PARAMETER MaxAttempts
    Maximum number of attempts (default: 3).

.PARAMETER InitialDelaySeconds
    Initial delay between retries (default: 2).

.PARAMETER BackoffFactor
    Multiplier for delay on each retry (default: 2).

.EXAMPLE
    Invoke-WithRetry { Test-Connection -ComputerName example.com -Count 1 -Quiet }
#>
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 2,
        [double]$BackoffFactor = 2.0
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw "Failed after $MaxAttempts attempts: $($_.Exception.Message)"
            }
            Write-WarnLog "Attempt $attempt/$MaxAttempts failed. Retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
            $delay = [int]($delay * $BackoffFactor)
        }
    }
}

# ==================== ADMIN & ELEVATION ====================

<#
.SYNOPSIS
    Tests if the current session is running as Administrator.
#>
function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
.SYNOPSIS
    Ensures the script is running as Administrator, re-launching if needed.
#>
function Assert-Administrator {
    [CmdletBinding()]
    param(
        [string]$ScriptPath = $PSCommandPath,
        [string[]]$Arguments = @()
    )

    if (Test-IsAdministrator) { return }

    Write-InfoLog 'Requesting elevation...'
    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + $Arguments
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList -Wait
    exit 0
}

# ==================== EXPORTS ====================

Export-ModuleMember -Function @(
    'Write-InfoLog',
    'Write-SuccessLog',
    'Write-WarnLog',
    'Write-ErrorLog',
    'Write-Banner',
    'Write-Panel',
    'Get-DotEnvConfig',
    'Update-SessionPath',
    'Confirm-Directory',
    'Get-RepositoryRoot',
    'Assert-FileExists',
    'Assert-CommandExists',
    'Invoke-WithRetry',
    'Test-IsAdministrator',
    'Assert-Administrator'
)
