[CmdletBinding()]
param(
    [switch]$ManualNetwork,      # force manual editor
    [string]$ArtifactsDir,       # back-compat: treated as CONFIG_NETWORK_DIR
    [string]$IsoDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    Write-Error $_
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host 'Press ENTER to exit' | Out-Null
    exit 1
}

function Start-PwshAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal $id
    $needsAdmin = -not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $needsPwsh  = $PSVersionTable.PSVersion.Major -lt 7
    if ($needsAdmin -or $needsPwsh) {
        Write-Host "Relaunching in elevated PowerShell 7..." -ForegroundColor Cyan
        $pwshArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
        $verb = if ($needsAdmin) { 'RunAs' } else { 'Open' }
        Start-Process pwsh -Verb $verb -ArgumentList $pwshArgs | Out-Null
        exit 0
    }
}

# One-shot resume task cleanup (if we came back after reboot)
try {
    $t = Get-ScheduledTask -TaskName 'SOC-9000-Setup-Resume' -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName 'SOC-9000-Setup-Resume' -Confirm:$false }
} catch {}

function Get-DotEnvMap([string]$Path) {
    if (-not (Test-Path $Path)) { return @{} }
    $m = @{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
        $k,$v = $_ -split '=',2
        if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
    }
    return $m
}

function Set-EnvKeyIfMissing([string]$Key,[string]$Value) {
    if (-not (Test-Path $EnvFile)) { New-Item -ItemType File -Path $EnvFile -Force | Out-Null }
    $existing = Get-Content $EnvFile
    if ($existing -notmatch "^\s*$Key\s*=") { Add-Content -Path $EnvFile -Value "$Key=$Value" }
}

function Invoke-IfScriptExists(
    [string]$ScriptPath,
    [string]$FriendlyName,
    [int[]]$AllowedExitCodes = @(0),
    [int[]]$RebootExitCodes  = @(2),
    [switch]$AutoResume
) {
    if (-not (Test-Path $ScriptPath)) { return }

    function Register-ResumeTask {
        param([string[]]$ExtraArgs)
        try {
            $existing = Get-ScheduledTask -TaskName 'SOC-9000-Setup-Resume' -ErrorAction SilentlyContinue
            if ($existing) { Unregister-ScheduledTask -TaskName 'SOC-9000-Setup-Resume' -Confirm:$false }
            $action  = New-ScheduledTaskAction -Execute 'pwsh.exe' `
                -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" {1}" -f $PSCommandPath, ($ExtraArgs -join ' '))
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType InteractiveToken -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 120)
            Register-ScheduledTask -TaskName 'SOC-9000-Setup-Resume' -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings | Out-Null
        } catch {
            throw "Failed to register resume task: $($_.Exception.Message)"
        }
    }

    Write-Host ("Running {0} ..." -f $FriendlyName)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Verbose
    $code = $LASTEXITCODE

    if ($RebootExitCodes -contains $code) {
        if ($AutoResume) {
            Register-ResumeTask -ExtraArgs $MyInvocation.UnboundArguments
            try { Stop-Transcript | Out-Null } catch {}
            Write-Warning ("{0} requested a reboot (exit code {1}). Rebooting now and will automatically resume..." -f $FriendlyName,$code)
            Restart-Computer -Force
            Start-Sleep -Seconds 2
            exit 0
        } else {
            Write-Warning ("{0} requested a reboot (exit code {1}). Please reboot, then rerun setup." -f $FriendlyName,$code)
            try { Stop-Transcript | Out-Null } catch {}
            Read-Host 'Press ENTER to exit' | Out-Null
            exit 0
        }
    }

    if ($AllowedExitCodes -notcontains $code) {
        throw ("{0} exited with code {1}" -f $FriendlyName,$code)
    }

    Write-Host ("{0}: OK" -f $FriendlyName) -ForegroundColor Green
}

function Get-VNetLibPath {
    foreach ($p in @(
        "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe",
        "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe"
    )) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+."
}

function Open-VirtualNetworkEditor {
    $candidates = @(
        'C:\Program Files\VMware\VMware Workstation\vmnetcfg.exe',
        'C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfg.exe'
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) {
        throw 'vmnetcfg.exe (Virtual Network Editor) not found. Open VMware Workstation > Edit > Virtual Network Editor.'
    }
    Write-Host 'Launching Virtual Network Editor...' -ForegroundColor Yellow
    Write-Host 'Configure VMnet8 as NAT (DHCP on). Create VMnet9–VMnet12 as Host-only (255.255.255.0). Close the editor when done.' -ForegroundColor Yellow
    Start-Process -FilePath $exe -Wait | Out-Null
}

function Convert-FileToAsciiCrLf([string]$Path) {
    $raw   = Get-Content $Path -Raw
    $ascii = [System.Text.Encoding]::ASCII.GetString([System.Text.Encoding]::UTF8.GetBytes($raw))
    $clean = ($ascii -replace "`r?`n","`r`n") -replace '[^\x00-\x7F]', ''
    Set-Content -Path $Path -Value $clean -Encoding Ascii
}

function Resolve-InstallRoot([hashtable]$EnvMap) {
    if ($EnvMap['INSTALL_ROOT']) { return $EnvMap['INSTALL_ROOT'] }
    if (Test-Path 'E:\') { return 'E:\SOC-9000-Install' }
    Write-Warning "E:\ not found; falling back to C:\SOC-9000-Install"
    return (Join-Path $env:SystemDrive 'SOC-9000-Install')
}

# ---------- main ----------
Start-PwshAdmin

# Repo + .env
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvFile  = Join-Path $RepoRoot '.env'
$EnvMap   = Get-DotEnvMap $EnvFile

# Resolve roots (ENV > E:\ > C:\)
$InstallRoot = Resolve-InstallRoot $EnvMap

# Derived paths (ENV overrides still respected)
$ConfigNetworkDir = if ($EnvMap['CONFIG_NETWORK_DIR']) { $EnvMap['CONFIG_NETWORK_DIR'] } else { Join-Path $InstallRoot 'config\network' }
if ($PSBoundParameters.ContainsKey('ArtifactsDir') -and $ArtifactsDir) { $ConfigNetworkDir = $ArtifactsDir } # back-compat

$IsoRoot = if ($IsoDir) { $IsoDir } elseif ($EnvMap['ISO_DIR']) { $EnvMap['ISO_DIR'] } else { Join-Path $InstallRoot 'isos' }
$LogDir  = Join-Path $InstallRoot 'logs\installation'
$StateDir= Join-Path $InstallRoot 'state'

# Ensure dirs
New-Item -ItemType Directory -Force -Path $InstallRoot,$ConfigNetworkDir,$IsoRoot,$LogDir,$StateDir | Out-Null

# Persist keys back to .env if missing (so next run is deterministic)
Set-EnvKeyIfMissing 'INSTALL_ROOT'       $InstallRoot
Set-EnvKeyIfMissing 'CONFIG_NETWORK_DIR' $ConfigNetworkDir
Set-EnvKeyIfMissing 'ISO_DIR'            $IsoRoot
Set-EnvKeyIfMissing 'HOSTONLY_VMNET_IDS' '9,10,11,12'

# Transcript
try { Stop-Transcript | Out-Null } catch {}
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $LogDir "setup-soc9000-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# --------- ISO download + HARD CHECK ----------
Write-Host "`n==== Ensuring ISO downloads ====" -ForegroundColor Cyan
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\download-isos.ps1') -IsoDir $IsoRoot
if ($LASTEXITCODE -ne 0) { throw "download-isos.ps1 failed with exit code $LASTEXITCODE" }

Write-Host "`n==== Checking required files ====" -ForegroundColor Cyan
function Test-IsosReady {
    param([string]$IsoRoot)
    $ubuntu  = Get-ChildItem -Path $IsoRoot -Filter 'ubuntu-22.04*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
    $windows = Get-ChildItem -Path $IsoRoot -Filter '*.iso' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(Windows|Win).*11' -or $_.Name -match 'Windows11' } | Select-Object -First 1
    $pfsense = Get-ChildItem -Path $IsoRoot -Filter '*.iso' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(pfsense|netgate).*' } | Select-Object -First 1
    $nessus  = Get-ChildItem -Path $IsoRoot -Filter '*.deb' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'nessus.*(amd64|x86_64)' } | Select-Object -First 1
    $missing = @()
    if (-not $ubuntu)  { $missing += 'Ubuntu 22.04 ISO (ubuntu-22.04*.iso)' }
    if (-not $windows) { $missing += 'Windows 11 ISO' }
    if (-not $pfsense) { $missing += 'pfSense / Netgate installer ISO' }
    if (-not $nessus)  { $missing += 'Nessus Essentials .deb' }
    [pscustomobject]@{
        Ready   = ($missing.Count -eq 0)
        Missing = $missing
        Found   = @($ubuntu,$windows,$pfsense,$nessus) | Where-Object { $_ }
    }
}
$check = Test-IsosReady -IsoRoot $IsoRoot
if (-not $check.Ready) {
    Write-Host "Missing files:" -ForegroundColor Yellow
    $check.Missing | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Please place the missing files into: $IsoRoot" -ForegroundColor Yellow
    Write-Host "Aborting before host configuration." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

Write-Host "`n==== ISO summary ====" -ForegroundColor Cyan
Get-ChildItem -Path $IsoRoot -File | Sort-Object Length -Descending | Select-Object Name,Length,LastWriteTime | Format-Table

# =================== NETWORKING ===================
Write-Host "`n==== Configuring VMware networks ====" -ForegroundColor Cyan
if ($ManualNetwork) {
    Open-VirtualNetworkEditor
} else {
    $profilePath = Join-Path $ConfigNetworkDir 'vmnet-profile.txt'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\generate-vmnet-profile.ps1') `
      -OutFile $profilePath -EnvPath (Join-Path $RepoRoot '.env') -CopyToLogs
    if ($LASTEXITCODE -ne 0) { throw "generate-vmnet-profile.ps1 failed ($LASTEXITCODE)." }

    $cfgPath = Join-Path $RepoRoot 'scripts\configure-vmnet.ps1'
    Convert-FileToAsciiCrLf $cfgPath
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $cfgPath
    if ($LASTEXITCODE -ne 0) { throw "Automated network configuration failed (configure-vmnet.ps1 exit $LASTEXITCODE)." }
}

Write-Host "`n==== Verifying networking ====" -ForegroundColor Cyan
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\verify-networking.ps1')
if ($LASTEXITCODE -ne 0) { Write-Error "Networking verification failed. See log at: $log"; Stop-Transcript | Out-Null; exit 1 }

# =================== WSL + LAB ===================
Write-Host "`n==== Bootstrapping WSL and Ansible ====" -ForegroundColor Cyan
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\wsl-prepare.ps1')         'wsl-prepare.ps1' -AllowedExitCodes @(0) -RebootExitCodes @(2) -AutoResume
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\wsl-init-user.ps1')       'wsl-init-user.ps1' -AllowedExitCodes @(0)
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\copy-ssh-key-to-wsl.ps1') 'copy-ssh-key-to-wsl.ps1' -AllowedExitCodes @(0)
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\wsl-bootstrap.ps1')       'wsl-bootstrap.ps1'

Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\lab-up.ps1')              'lab-up.ps1'

# Final banner reflects actual state flag under INSTALL_ROOT
$ReadyFlag = Join-Path $StateDir 'lab-ready.txt'
Write-Host ""
if (Test-Path $ReadyFlag) {
    Write-Host 'All requested steps completed.' -ForegroundColor Green
} else {
    Write-Host 'Host/WSL prep completed; lab build steps may still be in progress/pending.' -ForegroundColor Yellow
    Write-Host 'See lab-up.ps1 output for details.' -ForegroundColor Yellow
}
Stop-Transcript | Out-Null
Read-Host 'Press ENTER to exit' | Out-Null