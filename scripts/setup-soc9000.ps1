[CmdletBinding()]
param(
    [switch]$ManualNetwork,
    [string]$ArtifactsDir,   # backward-compat: treated as CONFIG_NETWORK_DIR
    [string]$IsoDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    Write-Error $_
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host 'Press ENTER to exit'
    exit 1
}

function Start-PwshAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal $id
    $needsAdmin = -not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $needsPwsh  = $PSVersionTable.PSVersion.Major -lt 7
    if ($needsAdmin -or $needsPwsh) {
        Write-Host "Relaunching in elevated PowerShell 7..." -ForegroundColor Cyan
        $pass = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
        $verb = if ($needsAdmin) { 'RunAs' } else { 'Open' }
        Start-Process pwsh -Verb $verb -ArgumentList $pass | Out-Null
        exit 0
    }
}

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

function Invoke-IfScriptExists([string]$ScriptPath,[string]$FriendlyName) {
    if (Test-Path $ScriptPath) {
        Write-Host ("Running {0} ..." -f $FriendlyName)
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Verbose
        if ($LASTEXITCODE -ne 0) { throw ("{0} exited with code {1}" -f $FriendlyName,$LASTEXITCODE) }
        Write-Host ("{0}: OK" -f $FriendlyName) -ForegroundColor Green
    }
}

function Start-VMwareNetworkServices {
    $svcNames = @(
        @{ Name='VMnetNatSvc'; Display='VMware NAT Service'   },
        @{ Name='VMnetDHCP';   Display='VMware DHCP Service'  }
    )
    foreach ($s in $svcNames) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if (-not $svc) { $svc = Get-Service -DisplayName $s.Display -ErrorAction SilentlyContinue }
        if ($svc) {
            try {
                $wmi = Get-WmiObject -Class Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
                if ($wmi -and $wmi.StartMode -ne 'Auto') { $null = $wmi.ChangeStartMode('Automatic') }
            } catch {}
            if ($svc.Status -ne 'Running') {
                try { Start-Service -InputObject $svc -ErrorAction Stop } catch { Write-Warning "Failed to start '$($svc.Name)': $($_.Exception.Message)" }
                $deadline = (Get-Date).AddSeconds(20)
                do { Start-Sleep -Milliseconds 500; $svc.Refresh() } while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline)
            }
            if ($svc.Status -ne 'Running') { throw "Service '$($svc.Name)' failed to reach Running state." }
        } else {
            Write-Warning "VMware service '$($s.Name)' not found."
        }
    }
}

# --- main ---

Start-PwshAdmin

# Resolve roots
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EExists  = Test-Path 'E:\'
$DefaultInstallRoot = $(if ($EExists) { 'E:\SOC-9000-Install' } else { Join-Path $env:SystemDrive 'SOC-9000-Install' })

# .env coalesce
$EnvFile = Join-Path $RepoRoot '.env'
$EnvMap  = Get-DotEnvMap $EnvFile

$InstallRoot = $DefaultInstallRoot
if ($EnvMap.ContainsKey('INSTALL_ROOT') -and $EnvMap['INSTALL_ROOT']) { $InstallRoot = $EnvMap['INSTALL_ROOT'] }

# Directories under InstallRoot
$ConfigNetworkDir = Join-Path $InstallRoot 'config\network'
$IsoRoot          = Join-Path $InstallRoot 'isos'
$LogDir           = Join-Path $InstallRoot 'logs\installation'

# Back-compat overrides
if ($EnvMap.ContainsKey('CONFIG_NETWORK_DIR') -and $EnvMap['CONFIG_NETWORK_DIR']) { $ConfigNetworkDir = $EnvMap['CONFIG_NETWORK_DIR'] }
if ($EnvMap.ContainsKey('ISO_DIR') -and $EnvMap['ISO_DIR']) { $IsoRoot = $EnvMap['ISO_DIR'] }
if ($PSBoundParameters.ContainsKey('ArtifactsDir') -and $ArtifactsDir) { $ConfigNetworkDir = $ArtifactsDir }  # compat
if ($PSBoundParameters.ContainsKey('IsoDir') -and $IsoDir) { $IsoRoot = $IsoDir }

# Ensure dirs
New-Item -ItemType Directory -Force -Path $InstallRoot,$ConfigNetworkDir,$IsoRoot,$LogDir | Out-Null

# Persist keys
Set-EnvKeyIfMissing 'INSTALL_ROOT'       $InstallRoot
Set-EnvKeyIfMissing 'CONFIG_NETWORK_DIR' $ConfigNetworkDir
Set-EnvKeyIfMissing 'ISO_DIR'            $IsoRoot

try { Stop-Transcript | Out-Null } catch {}
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $LogDir "setup-soc9000-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

# ISOs (informational only)
Write-Host "`n==== Ensuring ISO downloads ====" -ForegroundColor Cyan
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\download-isos.ps1') -IsoDir $IsoRoot
if ($LASTEXITCODE -ne 0) { throw "download-isos.ps1 failed with exit code $LASTEXITCODE" }

Write-Host "`n==== ISO summary (informational) ====" -ForegroundColor Cyan
Get-ChildItem -Path $IsoRoot -File | Sort-Object Length -Descending | Select-Object Name,Length,LastWriteTime | Format-Table

# Networking
Write-Host "`n==== Configuring VMware networks ====" -ForegroundColor Cyan
if ($ManualNetwork) {
    Write-Host "Manual network configuration requested."
    Write-Host "Open the Virtual Network Editor, configure VMnets, then press ENTER to continue."
    Read-Host 'Press ENTER when done' | Out-Null
} else {
    $cfg = Join-Path $RepoRoot 'scripts\configure-vmnet.ps1'
    try {
        if (Test-Path $cfg) {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $cfg
            if ($LASTEXITCODE -ne 0) { throw "configure-vmnet.ps1 failed ($LASTEXITCODE)." }
            Start-VMwareNetworkServices
        } else {
            throw "configure-vmnet.ps1 not found"
        }
    }
    catch {
        Write-Warning "$($_.Exception.Message); attempting fallback"
        $gen = Join-Path $RepoRoot 'scripts\generate-vmnet-profile.ps1'
        $profilePath = Join-Path $ConfigNetworkDir 'vmnet-profile.txt'

        Write-Host "Generating profile..."
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $profilePath -EnvPath (Join-Path $RepoRoot '.env')
        if ($LASTEXITCODE -ne 0) { throw "generate-vmnet-profile.ps1 failed ($LASTEXITCODE)." }
        Write-Host "VMnet profile written: $profilePath"

        $vnetlib = @(
            "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe",
            "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $vnetlib) { throw "vnetlib64.exe not found" }

        Write-Host "Importing..."
        $p = Start-Process -FilePath $vnetlib -ArgumentList @('--','stop','dhcp') -Wait -PassThru;  if ($p.ExitCode -ne 0) { throw "stop dhcp failed: $($p.ExitCode)" }
        $p = Start-Process -FilePath $vnetlib -ArgumentList @('--','stop','nat')  -Wait -PassThru;  if ($p.ExitCode -ne 0) { throw "stop nat failed: $($p.ExitCode)" }
        $p = Start-Process -FilePath $vnetlib -ArgumentList @('--','import',"$profilePath") -Wait -PassThru; if ($p.ExitCode -ne 0) { throw "import failed: $($p.ExitCode)" }
        [void](Start-Process -FilePath $vnetlib -ArgumentList @('--','start','dhcp') -Wait -PassThru)
        [void](Start-Process -FilePath $vnetlib -ArgumentList @('--','start','nat')  -Wait -PassThru)

        Start-VMwareNetworkServices
        Write-Host "VMware networking (import): OK"
    }
}

Write-Host "`n==== Verifying networking ====" -ForegroundColor Cyan
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\verify-networking.ps1')
if ($LASTEXITCODE -ne 0) { throw "verify-networking.ps1 exited with code $LASTEXITCODE" }

Write-Host "`n==== Bootstrapping WSL and Ansible ====" -ForegroundColor Cyan
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\wsl-prepare.ps1')         'wsl-prepare.ps1'
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\wsl-bootstrap.ps1')       'wsl-bootstrap.ps1'
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\copy-ssh-key-to-wsl.ps1') 'copy-ssh-key-to-wsl.ps1'
Invoke-IfScriptExists (Join-Path $RepoRoot 'scripts\lab-up.ps1')              'lab-up.ps1'

Write-Host ""
Write-Host 'All requested steps completed.' -ForegroundColor Green
Stop-Transcript | Out-Null
Read-Host 'Press ENTER to exit' | Out-Null