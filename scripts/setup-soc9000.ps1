[CmdletBinding()]
param([switch]$ManualNetwork)

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

function Wait-ForManualDownloads([string]$IsoDir) {
  $patterns = @(
    @{Name='Windows 11 ISO'; Pattern='(?i).*win(dows)?[^\w]*11.*\.iso$'},
    @{Name='pfSense ISO';    Pattern='(?i)(pfsense|netgate).*\.iso(\.gz)?$'},
    @{Name='Nessus DEB';     Pattern='(?i)^nessus.*amd64.*\.deb$'}
  )
  while ($true) {
    $missing = @()
    $files = Get-ChildItem -Path $IsoDir -File -ErrorAction SilentlyContinue
    foreach ($p in $patterns) {
      if (-not ($files | Where-Object { $_.Name -match $p.Pattern })) {
        $missing += $p
      }
    }
    if ($missing.Count -eq 0) { return }
    Write-Warning "Manual downloads required:"
    foreach ($m in $missing) { Write-Host ("  - {0}" -f $m.Name) }
    Write-Host ("Place the files in: {0}" -f $IsoDir)
    $ans = Read-Host "[R]e-check or [A]bort"
    if ($ans -match '^[Aa]') { throw "Missing manual downloads." }
  }
}

function Run-IfExists([string]$ScriptPath,[string]$FriendlyName) {
  if (Test-Path $ScriptPath) {
    Write-Host ("Running {0} ..." -f $FriendlyName)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Verbose
    if ($LASTEXITCODE -ne 0) { throw ("{0} exited with code {1}" -f $FriendlyName,$LASTEXITCODE) }
    Write-Host ("{0}: OK" -f $FriendlyName) -ForegroundColor Green
  }
}

function Configure-VMnets([string]$RepoRoot) {
  if ($ManualNetwork) { throw "Manual network configuration requested." }
  $cfg = Join-Path $RepoRoot 'scripts\\configure-vmnet.ps1'
  if (-not (Test-Path $cfg)) { throw "Missing configure-vmnet.ps1" }
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $cfg
  if ($LASTEXITCODE -ne 0) { throw "configure-vmnet.ps1 failed ($LASTEXITCODE)." }
  Write-Host "VMware networking: OK" -ForegroundColor Green
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
$IsoDir       = if ($envMap.ContainsKey('ISO_DIR')) { $envMap['ISO_DIR'] } else { Join-Path $RepoRoot 'isos' }
$ArtifactsDir = if ($envMap.ContainsKey('ARTIFACTS_DIR')) { $envMap['ARTIFACTS_DIR'] } else { Join-Path $RepoRoot 'artifacts' }
$NetworkDir   = Join-Path $ArtifactsDir 'network'
$LogDir       = Join-Path $RepoRoot 'logs'
$null = New-Item -ItemType Directory -Force -Path $IsoDir, $ArtifactsDir, $NetworkDir, $LogDir

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

Show-Step "Waiting for manual downloads"
Wait-ForManualDownloads -IsoDir $IsoDir

Show-Step "Verifying checksums"
$vhScript = Join-Path $RepoRoot 'scripts\\verify-hashes.ps1'
if (Test-Path $vhScript) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $vhScript -IsoDir $IsoDir -Strict
  if ($LASTEXITCODE -ne 0) { throw "verify-hashes.ps1 failed ($LASTEXITCODE)" }
}

Show-Step "Configuring VMware networks"
try {
  Configure-VMnets -RepoRoot $RepoRoot
} catch {
  Write-Warning ("Automatic network setup failed: {0}" -f $_.Exception.Message)
  Write-Host "Please configure VMnets manually via Virtual Network Editor and press ENTER to continue."
  $vmnetcfg = @(
    "C:\\Program Files (x86)\\VMware\\VMware Workstation\\vmnetcfg.exe",
    "C:\\Program Files\\VMware\\VMware Workstation\\vmnetcfg.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($vmnetcfg) { Start-Process -FilePath $vmnetcfg -Wait } else { Read-Host 'Press ENTER when done' | Out-Null }
}

Show-Step "Verifying networking"
Run-IfExists (Join-Path $RepoRoot 'scripts\\verify-networking.ps1') 'verify-networking.ps1'

Show-Step "Bootstrapping WSL and Ansible"
Run-IfExists (Join-Path $RepoRoot 'scripts\\wsl-prepare.ps1')       'wsl-prepare.ps1'
Run-IfExists (Join-Path $RepoRoot 'scripts\\wsl-bootstrap.ps1')     'wsl-bootstrap.ps1'
Run-IfExists (Join-Path $RepoRoot 'scripts\\copy-ssh-key-to-wsl.ps1') 'copy-ssh-key-to-wsl.ps1'
Run-IfExists (Join-Path $RepoRoot 'scripts\\host-prepare.ps1')      'host-prepare.ps1'
Run-IfExists (Join-Path $RepoRoot 'scripts\\lab-up.ps1')            'lab-up.ps1'

Write-Host ""
Write-Host 'All requested steps completed.' -ForegroundColor Green
Stop-Transcript | Out-Null
Read-Host 'Press ENTER to exit' | Out-Null

