[CmdletBinding()]
param(
  [switch]$ManualNetwork,
  [string]$ArtifactsDir,
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

function Ensure-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal $id
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null
    exit 0
  }
}

function Read-DotEnv([string]$Path) {
  if (-not (Test-Path $Path)) { return @{} }
  $m = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
  }
  return $m
}

function Show-Step([string]$Msg) {
  Write-Host ""
  Write-Host "==== $Msg ====" -ForegroundColor Cyan
}


function Run-IfExists([string]$ScriptPath,[string]$FriendlyName) {
  if (Test-Path $ScriptPath) {
    Write-Host ("Running {0} ..." -f $FriendlyName)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Verbose
    if ($LASTEXITCODE -ne 0) { throw ("{0} exited with code {1}" -f $FriendlyName,$LASTEXITCODE) }
    Write-Host ("{0}: OK" -f $FriendlyName) -ForegroundColor Green
  }
}

function Find-VNetLib {
  foreach ($p in @(
    "C:\\Program Files (x86)\\VMware\\VMware Workstation\\vnetlib64.exe",
    "C:\\Program Files\\VMware\\VMware Workstation\\vnetlib64.exe"
  )) { if (Test-Path $p) { return $p } }
  return $null
}

function Configure-VMnets([string]$RepoRoot,[string]$ArtifactsDir) {
  if ($ManualNetwork) { throw "Manual network configuration requested." }
  $cfg = Join-Path $RepoRoot 'scripts\\configure-vmnet.ps1'
  if (-not (Test-Path $cfg)) { throw "Missing configure-vmnet.ps1" }
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $cfg
  $cfgExit = $LASTEXITCODE
  if ($cfgExit -eq 0) {
    Write-Host "VMware networking: OK" -ForegroundColor Green
    return
  }
  Write-Warning ("configure-vmnet.ps1 failed ({0}); attempting fallback" -f $cfgExit)

  $gen = Join-Path $RepoRoot 'scripts\\generate-vmnet-profile.ps1'
  if (-not (Test-Path $gen)) { throw "Missing generate-vmnet-profile.ps1" }
  $profile = Join-Path $ArtifactsDir 'vmnet-profile.txt'
  Write-Host "Generating profile..." -ForegroundColor Yellow
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $profile
  $genExit = $LASTEXITCODE
  if ($genExit -ne 0) { throw "generate-vmnet-profile.ps1 failed ($genExit)" }

  $vnetlib = Find-VNetLib
  if (-not $vnetlib) { throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ and re-run." }

  Write-Host "Importing..." -ForegroundColor Yellow
  & $vnetlib -- stop dhcp
  $stopDhcp = $LASTEXITCODE
  & $vnetlib -- stop nat
  $stopNat  = $LASTEXITCODE
  & $vnetlib -- import $profile
  $importExit = $LASTEXITCODE
  & $vnetlib -- start dhcp
  $startDhcp = $LASTEXITCODE
  & $vnetlib -- start nat
  $startNat = $LASTEXITCODE

  foreach($s in @("VMware NAT Service","VMnetDHCP")){
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if($svc -and $svc.StartType -eq 'Disabled'){ Set-Service -Name $s -StartupType Automatic }
    try{ Start-Service -Name $s -ErrorAction SilentlyContinue }catch{}
  }

  if ($importExit -eq 0) {
    Write-Host "VMware networking (import): OK" -ForegroundColor Green
    return
  }

  Write-Warning ("vnetlib import failed ({0}). Launching Virtual Network Editor." -f $importExit)
  $vmnetcfg = @(
    "C:\\Program Files (x86)\\VMware\\VMware Workstation\\vmnetcfg.exe",
    "C:\\Program Files\\VMware\\VMware Workstation\\vmnetcfg.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($vmnetcfg) { Start-Process -FilePath $vmnetcfg -Wait }
  Read-Host 'Press ENTER when done' | Out-Null
}

# --- main ---

Ensure-Admin

$ScriptRoot = Split-Path -Parent $PSCommandPath
$RepoRoot   = (Resolve-Path (Join-Path $ScriptRoot '..')).Path
$envPath    = Join-Path $RepoRoot '.env'
if (-not (Test-Path $envPath)) {
  $example = Join-Path $RepoRoot '.env.example'
  if (Test-Path $example) {
    Copy-Item $example $envPath -Force
    Write-Host "Created .env from template." -ForegroundColor Yellow
  }
}
$envMap = Read-DotEnv $envPath
$Defaults = if (Test-Path 'E:\\') {
  @{ LAB_ROOT='E:\\SOC-9000'; ARTIFACTS_DIR='E:\\SOC-9000\\artifacts\\network'; ISO_DIR='E:\\SOC-9000-Install\\isos' }
} else {
  @{ LAB_ROOT=$RepoRoot; ARTIFACTS_DIR=(Join-Path $RepoRoot 'artifacts\\network'); ISO_DIR=(Join-Path $RepoRoot 'install\\isos') }
}

$LabRoot = if ($envMap.ContainsKey('LAB_ROOT')) { $envMap['LAB_ROOT'] } else { $Defaults.LAB_ROOT }
$ArtifactsDir = if ($PSBoundParameters.ContainsKey('ArtifactsDir')) { $ArtifactsDir } elseif ($envMap.ContainsKey('ARTIFACTS_DIR')) { $envMap['ARTIFACTS_DIR'] } else { $Defaults.ARTIFACTS_DIR }
$IsoDir = if ($PSBoundParameters.ContainsKey('IsoDir')) { $IsoDir } elseif ($envMap.ContainsKey('ISO_DIR')) { $envMap['ISO_DIR'] } else { $Defaults.ISO_DIR }
$LogDir = Join-Path $LabRoot 'logs'
$null = New-Item -ItemType Directory -Force -Path $LabRoot, $IsoDir, $ArtifactsDir, $LogDir

try { Stop-Transcript | Out-Null } catch {}
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $LogDir "setup-soc9000-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

Show-Step "Ensuring ISO downloads"
$dlScript = Join-Path $RepoRoot 'scripts\\download-isos.ps1'
if (Test-Path $dlScript) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $dlScript -IsoDir $IsoDir
  if ($LASTEXITCODE -ne 0) { throw "download-isos.ps1 failed ($LASTEXITCODE)" }
}
Show-Step "Verifying checksums"
$vhScript = Join-Path $RepoRoot 'scripts\\verify-hashes.ps1'
if (Test-Path $vhScript) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $vhScript -IsoDir $IsoDir
}

Show-Step "Configuring VMware networks"
try {
  Configure-VMnets -RepoRoot $RepoRoot -ArtifactsDir $ArtifactsDir
} catch {
  Write-Warning ("Automatic network setup failed: {0}" -f $_.Exception.Message)
  Write-Host "Please configure VMnets manually via Virtual Network Editor and press ENTER to continue."
  Read-Host 'Press ENTER when done' | Out-Null
}

Show-Step "Verifying networking"
Run-IfExists (Join-Path $RepoRoot 'scripts\\verify-networking.ps1') 'verify-networking.ps1'

Show-Step "Bootstrapping WSL and Ansible"
Run-IfExists (Join-Path $RepoRoot 'scripts\\wsl-prepare.ps1')       'wsl-prepare.ps1'
Run-IfExists (Join-Path $RepoRoot 'scripts\\wsl-bootstrap.ps1')     'wsl-bootstrap.ps1'
Run-IfExists (Join-Path $RepoRoot 'scripts\\copy-ssh-key-to-wsl.ps1') 'copy-ssh-key-to-wsl.ps1'
Run-IfExists (Join-Path $RepoRoot 'scripts\\lab-up.ps1')            'lab-up.ps1'

Write-Host ""
Write-Host 'All requested steps completed.' -ForegroundColor Green
Stop-Transcript | Out-Null
Read-Host 'Press ENTER to exit' | Out-Null

