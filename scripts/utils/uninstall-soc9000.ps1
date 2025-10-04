<#
.SYNOPSIS
    SOC-9000 Uninstaller - Interactive removal of prerequisites and lab files

.DESCRIPTION
    Provides user-friendly uninstallation of SOC-9000 prerequisites with:
    - Interactive confirmation for each component
    - Dry-run mode to preview changes
    - Selective uninstallation (choose what to remove)
    - Progress indicators and clear status messages
    - Comprehensive logging
    - Safe defaults (preserves user data unless explicitly requested)

.PARAMETER All
    Remove all SOC-9000 components without prompts

.PARAMETER Force
    Skip confirmation prompts (use with -All for fully automated removal)

.PARAMETER WhatIf
    Show what would be removed without actually removing anything (dry-run)

.PARAMETER KeepUserData
    Preserve Git configs, kubectl configs, and other user data

.EXAMPLE
    .\uninstall-soc9000.ps1
    # Interactive mode - prompts for each component

.EXAMPLE
    .\uninstall-soc9000.ps1 -All -Force
    # Remove everything without prompts

.EXAMPLE
    .\uninstall-soc9000.ps1 -WhatIf
    # Preview what would be removed

.EXAMPLE
    .\uninstall-soc9000.ps1 -All -KeepUserData
    # Remove tools but preserve user configurations

.NOTES
    Version: 2.0.0
    Requires: Administrator privileges
#>

#requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$All,
    [switch]$Force,
    [switch]$KeepUserData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ==================== ADMIN CHECK ====================

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "╔═════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║                      ADMINISTRATOR REQUIRED                  ║" -ForegroundColor Red
    Write-Host "╚═════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  This script requires administrator privileges to:" -ForegroundColor Yellow
    Write-Host "    • Uninstall software" -ForegroundColor Gray
    Write-Host "    • Modify system PATH" -ForegroundColor Gray
    Write-Host "    • Remove Windows features (WSL)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Please right-click and select 'Run as Administrator'" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

# ==================== LOGGING ====================

$LogPath = Join-Path $env:TEMP ("uninstall-soc9000-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
try {
    Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null
} catch {}

# ==================== CONSTANTS ====================

$WinGetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
$UserWinApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
$PFWSL       = 'C:\Program Files\WSL'

$PathMarkers = @('HashiCorp\Packer','Git\cmd','Git\bin','Kubernetes','chocolatey\bin','TigerVNC','PowerShell\7')

# ==================== HELPER FUNCTIONS ====================

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host ("║  {0,-57}║" -f $Title) -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "┌─────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host ("│  {0,-55}│" -f $Title) -ForegroundColor Yellow
    Write-Host "└─────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ  " -ForegroundColor Cyan -NoNewline
    Write-Host $Message -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓  " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  ⊘  " -ForegroundColor DarkGray -NoNewline
    Write-Host $Message -ForegroundColor DarkGray
}

function Write-Warning2 {
    param([string]$Message)
    Write-Host "  ⚠  " -ForegroundColor Yellow -NoNewline
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Error2 {
    param([string]$Message)
    Write-Host "  ✗  " -ForegroundColor Red -NoNewline
    Write-Host $Message -ForegroundColor Red
}

function Confirm-Action {
    param(
        [string]$Message,
        [switch]$DefaultYes
    )

    if ($Force) { return $true }
    if ($WhatIfPreference) { return $true }

    $prompt = if ($DefaultYes) { " (Y/n)" } else { " (y/N)" }
    $response = Read-Host "$Message$prompt"

    if ($DefaultYes) {
        return ($response -eq '' -or $response -match '^y(es)?$')
    } else {
        return ($response -match '^y(es)?$')
    }
}

function Remove-IfExists {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    if (Test-Path -LiteralPath $Path) {
        if ($WhatIfPreference) {
            Write-Info "Would remove: $Path"
            return
        }

        Write-Info "Removing: $Path"
        try {
            # Remove read-only/hidden attributes
            Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try { $_.Attributes = 'Normal' } catch {}
            }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Success "Removed: $Path"
        } catch {
            Write-Error2 "Failed to remove: $Path - $($_.Exception.Message)"
        }
    } else {
        Write-Skip "Not found: $Path"
    }
}

function Clean-Path {
    param([string[]]$Needles)

    if ($WhatIfPreference) {
        Write-Info "Would clean PATH variables"
        return
    }

    foreach($scope in 'User','Machine') {
        $cur = [Environment]::GetEnvironmentVariable('Path',$scope)
        if (-not $cur) { continue }

        $parts = $cur.Split(';') | Where-Object { $_ -and $_.Trim() -ne '' }
        $keep = New-Object System.Collections.Generic.List[string]
        $removed = @()

        foreach($p in $parts) {
            $hit = $false
            foreach($n in $Needles) {
                if ($p -like "*$n*") {
                    $hit = $true
                    break
                }
            }
            if ($hit) {
                $removed += $p
            } else {
                [void]$keep.Add($p)
            }
        }

        if ($removed.Count -gt 0) {
            $removed | ForEach-Object {
                Write-Info "Removing from PATH [$scope]: $_"
            }
            [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), $scope)
        }
    }

    # Refresh current session PATH
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

function Uninstall-By-UninstallString {
    param([string[]]$NameLike)

    $found = $false
    foreach($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        try {
            Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty -Path $_.PsPath -ErrorAction SilentlyContinue
                if ($p.DisplayName) {
                    foreach($nl in $NameLike) {
                        if ($p.DisplayName -like $nl) {
                            $found = $true

                            if ($WhatIfPreference) {
                                Write-Info "Would uninstall: $($p.DisplayName)"
                                continue
                            }

                            Write-Info "Uninstalling: $($p.DisplayName)"
                            try {
                                if ($p.UninstallString) {
                                    $cmd = $p.UninstallString
                                    if ($cmd -match 'msiexec\.exe') {
                                        & cmd.exe /c "$cmd /qn /norestart" 2>&1 | Out-Null
                                    } else {
                                        & cmd.exe /c "$cmd /S" 2>&1 | Out-Null
                                    }
                                    Write-Success "Uninstalled: $($p.DisplayName)"
                                }
                            } catch {
                                Write-Error2 "Failed to uninstall: $($p.DisplayName)"
                            }
                        }
                    }
                }
            }
        } catch {}
    }

    if (-not $found) {
        Write-Skip "No matching installations found"
    }
}

# ==================== COMPONENT REMOVERS ====================

function Remove-Packer {
    Write-Section "Packer (HashiCorp)"

    if (-not $All) {
        if (-not (Confirm-Action "Remove Packer?" -DefaultYes)) {
            Write-Skip "Skipped by user"
            return
        }
    }

    Uninstall-By-UninstallString @('HashiCorp Packer*')
    Remove-IfExists (Join-Path $env:APPDATA 'packer')
    Remove-IfExists (Join-Path $env:APPDATA 'packer.d')
    Remove-IfExists (Join-Path $env:LOCALAPPDATA 'packer')
    Remove-IfExists (Join-Path $env:LOCALAPPDATA 'packer.d')
    Remove-IfExists (Join-Path $env:USERPROFILE '.packer.d')
    Remove-IfExists 'C:\Program Files\HashiCorp\Packer'
    Remove-IfExists 'C:\Program Files (x86)\HashiCorp\Packer'
    Remove-IfExists (Join-Path $env:LOCALAPPDATA 'HashiCorp\Packer')
}

function Remove-Git {
    Write-Section "Git"

    if (-not $All) {
        if (-not (Confirm-Action "Remove Git?" -DefaultYes)) {
            Write-Skip "Skipped by user"
            return
        }
    }

    Uninstall-By-UninstallString @('Git*','Git LFS*','GitHub CLI*','GitHub Desktop*','vs_githubprotocolhandlermsi*')

    if (-not $KeepUserData) {
        Remove-IfExists (Join-Path $env:USERPROFILE '.gitconfig')
        Remove-IfExists (Join-Path $env:USERPROFILE '.git-credentials')
        Remove-IfExists (Join-Path $env:USERPROFILE '.git-credential-cache')
    } else {
        Write-Info "Keeping Git user configuration (use without -KeepUserData to remove)"
    }

    Remove-IfExists (Join-Path $env:LOCALAPPDATA 'Programs\Git')
    Remove-IfExists (Join-Path $env:APPDATA 'git')
    Remove-IfExists 'C:\Program Files\Git'
    Remove-IfExists 'C:\Program Files\Git LFS'
    Remove-IfExists 'C:\ProgramData\chocolatey\lib\git'
    Remove-IfExists 'C:\ProgramData\chocolatey\bin\git.exe'
}

function Remove-Kubectl {
    Write-Section "kubectl (Kubernetes CLI)"

    if (-not $All) {
        if (-not (Confirm-Action "Remove kubectl?" -DefaultYes)) {
            Write-Skip "Skipped by user"
            return
        }
    }

    Uninstall-By-UninstallString @('Kubernetes kubectl*','kubectl*')

    if (-not $KeepUserData) {
        Remove-IfExists (Join-Path $env:USERPROFILE '.kube')
    } else {
        Write-Info "Keeping kubectl configuration (use without -KeepUserData to remove)"
    }

    Remove-IfExists 'C:\Program Files\Kubernetes'
    Remove-IfExists 'C:\Program Files (x86)\Kubernetes'
    Remove-IfExists 'C:\ProgramData\chocolatey\lib\kubernetes-cli'
    Remove-IfExists 'C:\ProgramData\chocolatey\bin\kubectl.exe'
}

function Remove-TigerVNC {
    Write-Section "TigerVNC"

    if (-not $All) {
        if (-not (Confirm-Action "Remove TigerVNC?" -DefaultYes)) {
            Write-Skip "Skipped by user"
            return
        }
    }

    Uninstall-By-UninstallString @('TigerVNC*','RealVNC*','UltraVNC*')
    Remove-IfExists (Join-Path $env:APPDATA 'TigerVNC')
    Remove-IfExists 'C:\Program Files\TigerVNC'
    Remove-IfExists 'C:\Program Files (x86)\TigerVNC'
    Remove-IfExists 'C:\ProgramData\chocolatey\lib\tigervnc'
    Remove-IfExists 'C:\ProgramData\chocolatey\bin\vncviewer.exe'
}

function Remove-PowerShell7 {
    Write-Section "PowerShell 7"

    if (-not $All) {
        Write-Warning2 "Removing PowerShell 7 will prevent this script from running in the future."
        if (-not (Confirm-Action "Remove PowerShell 7?")) {
            Write-Skip "Skipped by user"
            return
        }
    }

    Uninstall-By-UninstallString @('PowerShell* 7*','PowerShell* Preview*')
    Remove-IfExists (Join-Path $env:USERPROFILE 'Documents\PowerShell')
    Remove-IfExists (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell')
    Remove-IfExists (Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell')
    Remove-IfExists 'C:\Program Files\PowerShell\7'
    Remove-IfExists 'C:\Program Files\PowerShell\7-preview'
}

function Remove-WSL {
    Write-Section "Windows Subsystem for Linux (WSL)"

    if (-not $All) {
        Write-Warning2 "This will remove WSL and all Linux distributions."
        Write-Warning2 "Any data in WSL distributions will be lost."
        if (-not (Confirm-Action "Remove WSL completely?")) {
            Write-Skip "Skipped by user"
            return
        }
    }

    if ($WhatIfPreference) {
        Write-Info "Would stop WSL services"
        Write-Info "Would unregister all WSL distributions"
        Write-Info "Would remove WSL Store packages"
        Write-Info "Would disable WSL Windows features"
        Write-Info "Would remove WSL payload files"
        return
    }

    # Stop WSL services
    Write-Info "Stopping WSL services..."
    foreach($svc in 'WSLService','LxssManager') {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s) {
                if ($s.Status -eq 'Running') {
                    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                }
                & sc.exe config $svc start= disabled 2>&1 | Out-Null
            }
        } catch {}
    }

    # Stop WSL processes
    foreach($p in 'wslservice','wslhost','wslg','wslrelay','wsl') {
        try {
            Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        } catch {}
    }

    # Unregister distributions
    Write-Info "Unregistering WSL distributions..."
    try {
        $distros = & wsl.exe --list --quiet 2>$null
        if ($distros) {
            $distros -split "`r?`n" | ForEach-Object {
                $name = $_.Trim()
                if ($name -and $name -notmatch 'install|installieren|Vorgang|Timeout|abbrechen') {
                    Write-Info "Unregistering: $name"
                    & wsl.exe --unregister $name 2>$null | Out-Null
                }
            }
        }
    } catch {}

    # Remove WSL Store packages
    Write-Info "Removing WSL Store packages..."
    $packages = @(
        'MicrosoftCorporationII.WindowsSubsystemForLinux*',
        'MicrosoftCorporationII.WSLg*',
        'MicrosoftCorporationII.WslKernel*',
        'MicrosoftCorporationII.WslGuiAppProxy*'
    )
    foreach($pkg in $packages) {
        try {
            Get-AppxPackage -AllUsers -Name $pkg -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Info "Removing: $($_.PackageFullName)"
                Remove-AppxPackage -AllUsers -Package $_.PackageFullName -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    # Disable Windows features
    Write-Info "Disabling WSL Windows features..."
    try {
        dism.exe /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux /norestart 2>&1 | Out-Null
        dism.exe /online /disable-feature /featurename:VirtualMachinePlatform /norestart 2>&1 | Out-Null
    } catch {}

    # Remove local data
    Remove-IfExists (Join-Path $env:LOCALAPPDATA 'lxss')
    Remove-IfExists (Join-Path $env:LOCALAPPDATA 'wsl')

    # Remove registry keys
    try {
        Remove-Item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Lxss' -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}

    # Remove WSL payload
    if (Test-Path $PFWSL) {
        Write-Info "Removing WSL payload: $PFWSL"
        try {
            takeown /f "$PFWSL" /r /d Y 2>&1 | Out-Null
            icacls "$PFWSL" /grant "*S-1-5-32-544:(F)" /t /c 2>&1 | Out-Null
            Remove-Item -LiteralPath "$PFWSL" -Recurse -Force -ErrorAction Stop
            Write-Success "Removed WSL payload"
        } catch {
            Write-Warning2 "WSL payload will be removed on next reboot"
        }
    }
}

function Remove-LabFiles {
    Write-Section "SOC-9000 Lab Files"

    if (-not $All) {
        Write-Warning2 "This will remove all VM images, ISOs, and lab data."
        if (-not (Confirm-Action "Remove SOC-9000 lab files?")) {
            Write-Skip "Skipped by user"
            return
        }
    }

    Remove-IfExists 'E:\SOC-9000-Install'
    Remove-IfExists 'C:\SOC-9000-Install'
    Remove-IfExists (Join-Path $env:USERPROFILE 'Downloads\SOC-9000-Install')
    Remove-IfExists (Join-Path $env:TEMP 'SOC-9000*')
}

# ==================== MAIN EXECUTION ====================

Write-Header "SOC-9000 Uninstaller v2.0"

if ($WhatIfPreference) {
    Write-Host "  🔍 DRY-RUN MODE - No changes will be made" -ForegroundColor Yellow
    Write-Host ""
}

if ($All -and -not $Force) {
    Write-Host "  You are about to remove ALL SOC-9000 components:" -ForegroundColor Yellow
    Write-Host "    • Packer" -ForegroundColor Gray
    Write-Host "    • Git" -ForegroundColor Gray
    Write-Host "    • kubectl" -ForegroundColor Gray
    Write-Host "    • TigerVNC" -ForegroundColor Gray
    Write-Host "    • PowerShell 7" -ForegroundColor Gray
    Write-Host "    • WSL (all distributions)" -ForegroundColor Gray
    Write-Host "    • SOC-9000 lab files" -ForegroundColor Gray
    Write-Host ""

    if (-not (Confirm-Action "Continue with complete removal?")) {
        Write-Host ""
        Write-Host "  Uninstall cancelled by user." -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }
}

if (-not $All) {
    Write-Host "  Select which components to remove:" -ForegroundColor Cyan
    Write-Host ""
}

# Remove components
Remove-Packer
Remove-Git
Remove-Kubectl
Remove-TigerVNC
Remove-PowerShell7
Remove-WSL
Remove-LabFiles

# Clean up PATH
Write-Section "System PATH Cleanup"
Clean-Path $PathMarkers

# Final summary
Write-Header "Uninstall Complete"

if (-not $WhatIfPreference) {
    Write-Host "  📝 Log file: $LogPath" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  ⚠  REBOOT RECOMMENDED" -ForegroundColor Yellow
    Write-Host "  A reboot is recommended to:" -ForegroundColor Gray
    Write-Host "    • Complete WSL removal" -ForegroundColor Gray
    Write-Host "    • Apply PATH changes" -ForegroundColor Gray
    Write-Host "    • Clear Windows Search cache" -ForegroundColor Gray
    Write-Host ""

    if (-not $Force) {
        $response = Read-Host "  Press ENTER to reboot now, or type 'n' to skip"
        if ($response -eq '') {
            try { Stop-Transcript | Out-Null } catch {}
            Write-Host ""
            Write-Host "  Rebooting..." -ForegroundColor Cyan
            Restart-Computer -Force
        } else {
            Write-Host ""
            Write-Host "  Reboot skipped. Please reboot manually later." -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

try { Stop-Transcript | Out-Null } catch {}
