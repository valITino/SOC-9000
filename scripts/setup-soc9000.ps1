[CmdletBinding()]
param(
    [switch]$ManualNetwork,
    [string]$ArtifactsDir,
    [string]$IsoDir,
    [switch]$AutoPartitionE,
    [switch]$Headless,
    [switch]$SkipPrereqs   # internal: used when we relaunch into PS7 after installing it
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------- UX Helpers (ASCII) --------------------
function Banner([string]$Title, [string]$Subtitle = '', [ConsoleColor]$Color = [ConsoleColor]::Cyan) {
  $line = '============================================================================'
  Write-Host ''
  Write-Host $line -ForegroundColor $Color
  Write-Host ('  >> {0}' -f $Title) -ForegroundColor $Color
  if ($Subtitle) { Write-Host ('     {0}' -f $Subtitle) -ForegroundColor DarkGray }
  Write-Host $line -ForegroundColor $Color
}
function Line([string]$Text, [string]$Kind = 'info') {
  $fg = @{ info='Gray'; ok='Green'; warn='Yellow'; err='Red'; step='White'; ask='Magenta' }[$Kind]
  $tag = @{ info='[i]'; ok='[OK]'; warn='[!]'; err='[X]'; step='[>]'; ask='[?]' }[$Kind]
  Write-Host ('  {0} {1}' -f $tag, $Text) -ForegroundColor $fg
}
function Panel([string]$Title, [string[]]$Lines) {
  $line = '+--------------------------------------------------------------------------+'
  Write-Host $line -ForegroundColor DarkCyan
  Write-Host ('| {0}' -f $Title) -ForegroundColor DarkCyan
  Write-Host $line -ForegroundColor DarkCyan
  foreach ($ln in $Lines) { Write-Host ('| {0}' -f $ln) }
  Write-Host $line -ForegroundColor DarkCyan
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

# -------------------- Elevation & Shell helpers --------------------
function Ensure-Admin-CurrentHost {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
               IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) { return }
  $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
  Write-Host 'Requesting elevation...' -ForegroundColor Cyan
  $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
  Start-Process -FilePath $exe -Verb RunAs -ArgumentList $args | Out-Null
  exit 0
}

function Get-PreferredShellExe {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) { return 'pwsh' }
  return 'powershell'
}

Ensure-Admin-CurrentHost

# -------------------- Paths / Logs --------------------
$ScriptRoot = Split-Path -Parent $PSCommandPath
$RepoRoot   = (Resolve-Path (Join-Path $ScriptRoot '..')).Path
$EnvFile    = Join-Path $RepoRoot '.env'

if (Test-Path 'E:\') { $InstallRoot = 'E:\SOC-9000-Install' } else { $InstallRoot = 'C:\SOC-9000-Install' }
$LogRoot      = Join-Path $InstallRoot 'logs'
$SetupLogDir  = Join-Path $LogRoot 'setup'
$PackerLogDir = Join-Path $LogRoot 'packer'
# Always keep ISOs under install root (unless user overrides explicitly)
if ($IsoDir) { $IsoRoot = $IsoDir } else { $IsoRoot = Join-Path $InstallRoot 'isos' }

New-Item -ItemType Directory -Force -Path $InstallRoot,$LogRoot,$SetupLogDir,$PackerLogDir,$IsoRoot | Out-Null

$ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
$TranscriptPath = Join-Path $SetupLogDir ('setup-{0}.log' -f $ts)
try { Start-Transcript -Path $TranscriptPath -Force | Out-Null } catch {}

trap {
  Line ('Unexpected error: {0}' -f $_.Exception.Message) 'err'
  try { Stop-Transcript | Out-Null } catch {}
  Read-Host 'Press ENTER to exit' | Out-Null
  exit 1
}

# -------------------- .env loader --------------------
$EnvMap = @{}
if (Test-Path $EnvFile) {
  foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
    $k,$v = $line -split '=',2
    if ($k -and $v) { $EnvMap[$k.Trim()] = $v.Trim() }
  }
}

# -------------------- Session Overview --------------------
$overview = @(
  ('Repo Root     : {0}' -f $RepoRoot),
  ('ISOs Path     : {0}' -f $IsoRoot),
  ('Logs (setup)  : {0}' -f $SetupLogDir),
  ('Logs (packer) : {0}' -f $PackerLogDir),
  ('User          : {0}@{1}' -f $env:USERNAME, $env:COMPUTERNAME),
  ('Shell         : PowerShell {0} {1}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition),
  ('Started       : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
)
Banner 'SOC-9000 Setup Orchestrator' 'Steps 1-6 with clean, readable UX'
Panel 'Session Overview' $overview

# =====================================================================
# Step 1 - PREREQUISITES (ALWAYS RUN FIRST; DO NOT FORCE PS7 UPFRONT)
# =====================================================================
if (-not $SkipPrereqs) {
  Banner 'Step 1 of 6 - Prerequisites' 'Runs install-prereqs.ps1; may prompt for VMware install or reboot.'
  $Step1Shell = Get-PreferredShellExe   # use pwsh if present, otherwise powershell (PS5)
  $preReqs = Join-Path $RepoRoot 'scripts\install-prereqs.ps1'
  if ($AutoPartitionE) {
    & $Step1Shell -NoProfile -ExecutionPolicy Bypass -File $preReqs -AutoPartitionE -Verbose
  } else {
    & $Step1Shell -NoProfile -ExecutionPolicy Bypass -File $preReqs -Verbose
  }
  $code = $LASTEXITCODE
  if ($code -eq 2) {
    Line 'Prereqs complete; a reboot is required to finalize WSL activation.' 'warn'
    Read-Host '  [?] Press ENTER to reboot now' | Out-Null
    try { Stop-Transcript | Out-Null } catch {}
    Restart-Computer -Force
    exit
  } elseif ($code -ne 0) {
    throw ('install-prereqs.ps1 failed with exit code {0}' -f $code)
  }
  Line 'Prerequisites complete.' 'ok'

  # If we're still in PS5 but pwsh now exists, relaunch self in PS7 for the rest
  Refresh-Path
  $nowHasPwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  $isCore     = $PSVersionTable.PSEdition -eq 'Core'
  if ($nowHasPwsh -and -not $isCore) {
    Line 'Switching to PowerShell 7 for remaining steps...' 'info'
    $unbound = $MyInvocation.UnboundArguments + @('-SkipPrereqs')
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $unbound
    Start-Process -FilePath 'pwsh' -Verb RunAs -ArgumentList $args | Out-Null
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
  }
} else {
  Line 'SkipPrereqs flag detected — continuing at Step 2.' 'info'
}

# =====================================================================
# Step 2 - Repository (use current tree; no cloning)
# =====================================================================
Banner 'Step 2 of 6 - Repository' 'Using the current working tree; cloning disabled.'
$CurrentRepo  = (Resolve-Path (Join-Path $ScriptRoot '..')).Path

# Quick sanity check that we are in the SOC-9000 tree
$Sentinels = @(
  (Join-Path $CurrentRepo 'scripts\build-packer.ps1'),
  (Join-Path $CurrentRepo 'scripts\download-isos.ps1'),
  (Join-Path $CurrentRepo 'packer\ubuntu-container\ubuntu-container.pkr.hcl')
)
$LooksLikeRepo = $true
foreach ($s in $Sentinels) { if (-not (Test-Path $s)) { $LooksLikeRepo = $false; break } }

if (-not $LooksLikeRepo) {
  throw "This folder doesn't look like SOC-9000. Open an elevated PowerShell in your cloned repo and rerun scripts\setup-soc9000.ps1."
}

Line ("Using current tree: {0}" -f $CurrentRepo) 'ok'
$RepoRoot = $CurrentRepo

# =====================================================================
# Step 3 - Directories & ISOs
# =====================================================================
Banner 'Step 3 of 6 - Directories and ISO Validation' 'Verifies ISOs; opens official vendor pages when manual download is needed.'
New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot 'artifacts') | Out-Null
Line 'Running ISO downloader...' 'step'
$Shell = Get-PreferredShellExe
& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\download-isos.ps1') -IsoDir $IsoRoot -Verbose
$isos = Get-ChildItem -Path $IsoRoot -Filter *.iso -ErrorAction SilentlyContinue
if (-not $isos -or $isos.Count -eq 0) {
  Line ('No ISO detected in {0}.' -f $IsoRoot) 'warn'
  Read-Host '  [?] Place the required ISO(s) into the folder above, then press ENTER to re-check' | Out-Null
  $isos = Get-ChildItem -Path $IsoRoot -Filter *.iso -ErrorAction SilentlyContinue
  if (-not $isos -or $isos.Count -eq 0) { throw 'ISO(s) still missing; cannot continue.' }
}
Line ('{0} ISO(s) present.' -f $isos.Count) 'ok'

# =====================================================================
# Step 4 - Networking
# =====================================================================
Banner 'Step 4 of 6 - VMware Networking' 'Verify first; configure only if needed.'
Line 'Verifying VMware networks...' 'step'
& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\verify-networking.ps1') -Verbose
if ($LASTEXITCODE -ne 0) {
  Line 'Verification failed; applying configuration from .env ...' 'warn'
  if ($ManualNetwork) {
    $vmnetcfg = @(
      "${env:ProgramFiles}\VMware\VMware Workstation\vmnetcfg.exe",
      "${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmnetcfg.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($vmnetcfg) { & $vmnetcfg } else { Line 'vmnetcfg.exe not found; proceeding with automated script.' 'warn' }
  }
  & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\configure-vmnet.ps1') -Verbose
  if ($LASTEXITCODE -ne 0) { throw ('Automated network configuration failed (configure-vmnet.ps1 exit {0}).' -f $LASTEXITCODE) }
  Line 'Re-verifying VMware networks...' 'step'
  & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\verify-networking.ps1') -Verbose
  if ($LASTEXITCODE -ne 0) { throw 'Networking verification failed after configuration.' }
  Line 'Networks configured.' 'ok'
} else {
  Line 'Networks already correctly configured; no changes applied.' 'ok'
}

# =====================================================================
# Step 5 - WSL & SSH keys
# =====================================================================
Banner 'Step 5 of 6 - WSL Check and SSH Keys' 'Quick WSL ping; generate host SSH keys if missing; initialize WSL user.'
Line 'WSL quick status...' 'step'
try { wsl.exe --status | Out-Null; Line 'WSL responding.' 'ok' } catch { Line ('WSL status warning: {0}' -f $_.Exception.Message) 'warn' }
$SshDir = Join-Path $env:USERPROFILE '.ssh'
if (-not (Test-Path (Join-Path $SshDir 'id_ed25519')) -and -not (Test-Path (Join-Path $SshDir 'id_rsa'))) {
  Line 'Generating host SSH keypair (ed25519 preferred)...' 'step'
  New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
  try { & ssh-keygen -t ed25519 -N '' -f (Join-Path $SshDir 'id_ed25519') | Out-Null; Line 'ed25519 key generated.' 'ok' }
  catch { & ssh-keygen -t rsa -b 4096 -N '' -f (Join-Path $SshDir 'id_rsa') | Out-Null; Line 'RSA-4096 key generated.' 'ok' }
} else { Line 'Host SSH key(s) already present.' 'ok' }
& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\wsl-prepare.ps1') -Verbose
& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\wsl-init-user.ps1') -Verbose

# =====================================================================
# Step 6 - Build (Ubuntu first)
# =====================================================================
Banner 'Step 6 of 6 - Build Lab (Ubuntu First)' 'Shows VMware UI if your Packer template supports headless=false.'
New-Item -ItemType Directory -Force -Path $PackerLogDir | Out-Null
$UbuntuLog = Join-Path $PackerLogDir ('ubuntu-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))

# Tell build script what we want (string "true"/"false", not boolean)
$env:PACKER_HEADLESS = if ($Headless) { 'true' } else { 'false' }

Line ('Starting Ubuntu build; logging to: {0}' -f $UbuntuLog) 'step'
& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\build-packer.ps1') -Only ubuntu -Headless:$Headless -Verbose *>&1 | Tee-Object -FilePath $UbuntuLog
if ($LASTEXITCODE -ne 0) { throw ('Ubuntu build failed. See {0}' -f $UbuntuLog) }
Line 'Ubuntu build completed.' 'ok'

# -------------------- Credential Summary --------------------
# Ubuntu username (prefer .env, else parse user-data, else default)
$UbuntuUser = $EnvMap['UBUNTU_USERNAME']
if (-not $UbuntuUser) {
  $UserDataPath = Join-Path $RepoRoot 'packer\ubuntu-container\http\user-data'
  if (Test-Path $UserDataPath) {
    $m = Select-String -Path $UserDataPath -Pattern '^\s*username:\s*(\S+)' | Select-Object -First 1
    if ($m) { $UbuntuUser = $m.Matches[0].Groups[1].Value.Trim() }
  }
  if (-not $UbuntuUser) { $UbuntuUser = 'labadmin' }
} else {
  $UserDataPath = Join-Path $RepoRoot 'packer\ubuntu-container\http\user-data'
}

# SSH key paths
$PrivKeys = @()
$PubKeys  = @()
$k1 = Join-Path $SshDir 'id_ed25519'
$k2 = Join-Path $SshDir 'id_rsa'
if (Test-Path $k1) { $PrivKeys += $k1; if (Test-Path ($k1 + '.pub')) { $PubKeys += ($k1 + '.pub') } }
if (Test-Path $k2) { $PrivKeys += $k2; if (Test-Path ($k2 + '.pub')) { $PubKeys += ($k2 + '.pub') } }

$StateDir   = Join-Path $InstallRoot 'state'
$StateFile  = Join-Path $StateDir 'packer-artifacts.json'
$UbuntuVMX  = $null
if (Test-Path $StateFile) {
  try {
    $json = Get-Content $StateFile -Raw | ConvertFrom-Json
    $UbuntuVMX = $json.ubuntu.vmx
  } catch {}
}
if (-not $UbuntuVMX) {
  $UbuntuVMX = (Get-ChildItem -Path (Join-Path $InstallRoot 'VMs\Ubuntu') -Filter *.vmx -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName)
}

Panel 'Ubuntu Access & Credentials' @(
  ('Username            : {0}' -f $UbuntuUser),
  ('Password login      : disabled (SSH key auth)'),
  ('SSH private key(s)  : {0}' -f ($(if($PrivKeys){$PrivKeys -join ', '}else{'(none)'}))),
  ('SSH public key(s)   : {0}' -f ($(if($PubKeys){$PubKeys -join ', '}else{'(none)'}))),
  ('VMX path            : {0}' -f ($(if($UbuntuVMX){$UbuntuVMX}else{'(not found)'}))),
  '',
  ('Defined in .env     : {0}' -f $EnvFile),
  ('Autoinstall file    : {0}' -f ($(if(Test-Path $UserDataPath){$UserDataPath}else{'(missing)'}))),
  ('State JSON          : {0}' -f ($(if(Test-Path $StateFile){$StateFile}else{'(missing)'})))
)

Panel 'Logs & Artifacts' @(
  ('Packer logs         : {0}' -f $PackerLogDir),
  ('Setup transcript    : {0}' -f $TranscriptPath),
  ('ISOs directory      : {0}' -f $IsoRoot),
  'VMware Workstation  : Library -> Ubuntu -> Console (VNC optional via builder)'
)

Read-Host '  [?] Press ENTER to finish' | Out-Null

Banner 'Setup Steps 1-6 Complete' 'You can proceed to Step 7 (Windows) when ready.'
Write-Host 'NOTE: Credentials shown above also appear in this transcript log.' -ForegroundColor Yellow
try { Stop-Transcript | Out-Null } catch {}
Read-Host 'Press ENTER to exit' | Out-Null
