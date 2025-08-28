[CmdletBinding()]
param(
  [ValidateSet('ubuntu','windows')]
  [string]$Only,
  [int]$UbuntuMaxMinutes  = 45,
  [int]$WindowsMaxMinutes = 120,
  [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pinpoint any parameter-binding or runtime errors
trap {
  $inv = $_.InvocationInfo
  Write-Host "`n[ERR] $($inv.MyCommand) :: $($_.Exception.Message)" -ForegroundColor Red
  if ($inv.PositionMessage) { Write-Host $inv.PositionMessage -ForegroundColor DarkGray }
  throw
}

# Disable colored output globally for all subcommands (avoids '-color' flag issue)
$env:PACKER_NO_COLOR = '1'

# --------------------- UX ---------------------
function Write-Info([string]$m){ Write-Host "[> ] $m" -ForegroundColor Cyan }
function Write-Ok  ([string]$m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Fail([string]$m){ Write-Host "[X]  $m" -ForegroundColor Red }

# --------------------- Helpers ---------------------
function Get-RepoRoot { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }

function Get-DotEnv([string]$Path){
  $m=@{}
  if (!(Test-Path -LiteralPath $Path)) { return $m }
  Get-Content -LiteralPath $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    if ($_ -match '^([^=]+)=(.*)$') {
      $k=$matches[1].Trim(); $v=$matches[2].Trim()
      if ($k) { $m[$k]=$v }
    }
  }
  return $m
}

function Assert-Tool([string]$exe,[string]$hint){
  try { Get-Command $exe -ErrorAction Stop | Out-Null }
  catch { Write-Fail "$exe not found. $hint"; exit 2 }
}

function Assert-Exists([string]$p,[string]$label){
  if(!(Test-Path -LiteralPath $p)){ throw "$label not found: $p" }
}

function New-Directory([string]$path){
  if (-not $path) { return }
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

function Find-Iso([string]$dir,[string[]]$patterns){
  if(!(Test-Path -LiteralPath $dir)){ return $null }
  $cands = foreach($pat in $patterns){ Get-ChildItem -LiteralPath $dir -Filter $pat -ErrorAction SilentlyContinue }
  $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Find-PackerExe {
  $cmd = Get-Command packer -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Path) { return $cmd.Path }

  $cands = @()
  if ($env:LOCALAPPDATA) {
    $cands += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\packer.exe')
    $cands += (Join-Path $env:LOCALAPPDATA 'HashiCorp\Packer\packer.exe')
  }
  if ($env:ProgramFiles)        { $cands += (Join-Path $env:ProgramFiles        'HashiCorp\Packer\packer.exe') }
  if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'HashiCorp\Packer\packer.exe') }
  if ($env:ChocolateyInstall)   { $cands += (Join-Path $env:ChocolateyInstall   'bin\packer.exe') }
  $cands += 'C:\ProgramData\chocolatey\bin\packer.exe'

  foreach ($p in $cands | Where-Object { $_ }) {
    try { if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path } } catch {}
  }

  $roots = @()
  if ($env:LOCALAPPDATA) {
    $roots += (Join-Path $env:LOCALAPPDATA 'HashiCorp')
    $roots += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
  }
  if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'HashiCorp') }

  foreach ($r in $roots | Where-Object { $_ -and (Test-Path $_) }) {
    try {
      $found = Get-ChildItem -Path $r -Filter 'packer.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1 -ExpandProperty FullName
      if ($found) { return $found }
    } catch {}
  }
  return $null
}

# Progress/tail helper
$script:_lastTail   = ''
$script:_lastTailAt = Get-Date 0
function Show-Stage([string]$log,[datetime]$start,[int]$max){
  $stages = @(
    @{N='Booting ISO';         P='(boot|Starting HTTP|vmware-iso: VM)'},
    @{N='Waiting for SSH';     P='Waiting for SSH'},
    @{N='Connected via SSH';   P='Connected to SSH|SSH handshake'},
    @{N='Provisioning';        P='Provisioning|Uploading|Executing'},
    @{N='Shutdown';            P='Gracefully|Stopping|Powering off'},
    @{N='Artifact complete';   P='Builds finished|Artifact'}
  )
  $text = ''
  if (Test-Path -LiteralPath $log) {
    $text = ((Get-Content -LiteralPath $log -Tail 200 -ErrorAction SilentlyContinue) -join "`n")
  }
  $done = 0; foreach($s in $stages){ if($text -match $s.P){ $done++ } }
  $pct = [int](($done / $stages.Count) * 100)
  $elapsed = (Get-Date)-$start
  $limit=[TimeSpan]::FromMinutes($max)
  Write-Progress -Activity "Packer build" -Status ("Elapsed {0:hh\:mm\:ss} / {1:hh\:mm}" -f $elapsed,$limit) -PercentComplete $pct

  if ($text) {
    $last  = ((($text -split "`n") | Select-Object -Last 10) -join "`n")
    $since = ((Get-Date) - $script:_lastTailAt).TotalSeconds
    if ($last -ne $script:_lastTail -and $since -ge 20) {
      Write-Host "`n--- packer tail ---`n$last`n--------------------"
      $script:_lastTail   = $last
      $script:_lastTailAt = Get-Date
    }
  }
}

function Wait-ForArtifacts([array]$Targets,[int]$MaxSeconds=120){
  $t0 = Get-Date
  $found = @{}
  do {
    $ready = 0
    foreach ($t in $Targets) {
      if ($found.ContainsKey($t.Name)) { $ready++; continue }
      if (Test-Path -LiteralPath $t.Dir) {
        $vmx = Get-ChildItem -Path $t.Dir -Filter $t.Pattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vmx) { $found[$t.Name] = $vmx.FullName; $ready++ }
      }
    }
    $pct = [int](($ready / [math]::Max(1,$Targets.Count)) * 100)
    Write-Progress -Activity "Verifying VM artifacts" -Status ("{0}/{1} ready" -f $ready,$Targets.Count) -PercentComplete $pct
    if ($ready -eq $Targets.Count) {
      Write-Progress -Activity "Verifying VM artifacts" -Completed
      return $found
    }
    Start-Sleep -Seconds 2
  } while (((Get-Date) - $t0).TotalSeconds -lt $MaxSeconds)
  $missing = $Targets | Where-Object { -not $found.ContainsKey($_.Name) } | ForEach-Object { "{0} in {1}" -f $_.Name,$_.Dir }
  throw "Artifacts not found after $MaxSeconds sec: $($missing -join '; ')"
}

# --------------------- Repo / paths / logging ---------------------
$RepoRoot = Get-RepoRoot
Set-Location $RepoRoot
$EnvFile  = Join-Path $RepoRoot '.env'
$envMap   = Get-DotEnv $EnvFile

Write-Host "== Packer preflight" -ForegroundColor Cyan

# Prefer external install root when present
$InstallRoot = $envMap['INSTALL_ROOT']
if (-not $InstallRoot) {
  if (Test-Path 'E:\') { $InstallRoot = 'E:\SOC-9000-Install' }
  else { $InstallRoot = (Join-Path $env:SystemDrive 'SOC-9000-Install') }
}

# Logs directory (prefer E:\...)
$LogDir = Join-Path $InstallRoot 'logs\packer'
New-Directory $LogDir
function New-LogFile([string]$name){
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  Join-Path $LogDir ("{0}-{1}.log" -f $name,$stamp)
}

# OS-specific Packer cache
$CacheDir = Join-Path $InstallRoot "cache\packer\$Only"
if (-not $Only) { $CacheDir = Join-Path $InstallRoot "cache\packer\all" }
New-Directory $CacheDir
$env:PACKER_CACHE_DIR = $CacheDir

# Temporary directory for packer
$TmpDir = Join-Path $InstallRoot "tmp\packer"
if (Test-Path $TmpDir) {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
New-Directory $TmpDir
$env:PACKER_TMP_DIR = $TmpDir

# Clean up any packer_cache directories in the source tree
Write-Info "Cleaning up any packer_cache directories in the repo..."
Get-ChildItem -Path $RepoRoot -Recurse -Depth 3 -Directory -Name 'packer_cache' | ForEach-Object {
    Remove-Item -Recurse -Force (Join-Path $RepoRoot $_) -ErrorAction SilentlyContinue
}

# ssh-key provisioning dir
$KeyDir  = Join-Path $InstallRoot 'keys'
New-Directory $KeyDir
$KeyPath = Join-Path $KeyDir 'id_ed25519'
$PubPath = "$KeyPath.pub"

# Ensure packer + ssh-keygen
$PackerExe = Find-PackerExe
if (-not $PackerExe) {
  Write-Fail "packer.exe nicht gefunden. Installiere z.B.: winget install HashiCorp.Packer"
  exit 1
}
Assert-Tool 'ssh-keygen' 'Install Windows OpenSSH Client (optional feature)'

# Print packer version
try {
  $vOut = & $PackerExe -v 2>&1
  Write-Ok ("Packer: {0}" -f ($vOut -join ' '))
} catch { Write-Warn "Konnte Packer-Version nicht abfragen." }

# Ensure SSH keypair
if (!(Test-Path -LiteralPath $KeyPath)) {
  & ssh-keygen -t ed25519 -N "" -f $KeyPath | Out-Null
  Write-Info "Generated SSH key: $KeyPath"
}

# seed http directory for ubuntu build
$SeedDir = Join-Path $RepoRoot 'packer\ubuntu-container\http'
New-Directory $SeedDir
$pub = (Get-Content -LiteralPath $PubPath -Raw).Trim()

# -----------------------------------------------------------

# ISOs
$IsoRoot = $envMap['ISO_DIR']
if (-not $IsoRoot) { $IsoRoot = Join-Path $InstallRoot 'isos' }
New-Directory $IsoRoot

$isoUbuntuName  = $envMap['ISO_UBUNTU'];  $isoUbuntu  = $null
if ($isoUbuntuName) { $isoUbuntu = Join-Path $IsoRoot $isoUbuntuName }
if (-not $isoUbuntu -or -not (Test-Path -LiteralPath $isoUbuntu)) {
  $u = Find-Iso $IsoRoot @('ubuntu-22.04*.iso','ubuntu-22.04*server*.iso')
  if ($u) { $isoUbuntu = $u.FullName; $isoUbuntuName = $u.Name }
}
$isoWindowsName = $envMap['ISO_WINDOWS']; $isoWindows = $null
if ($isoWindowsName) { $isoWindows = Join-Path $IsoRoot $isoWindowsName }
if (-not $isoWindows -or -not (Test-Path -LiteralPath $isoWindows)) {
  $w = Find-Iso $IsoRoot @('Win*11*.iso','Windows*11*.iso','en-us_windows_11*.iso')
  if ($w) { $isoWindows = $w.FullName; $isoWindowsName = $w.Name }
}

# Templates
$Utpl = Join-Path $RepoRoot 'packer\ubuntu-container\ubuntu-container.pkr.hcl'
$Wtpl = Join-Path $RepoRoot 'packer\windows-victim\windows.pkr.hcl'
Assert-Exists $Utpl 'Ubuntu Packer template'
if (-not $Only) { Assert-Exists $Wtpl 'Windows Packer template' }

# Resolve VMnet8 host IP (from .env or detect)
$Vmnet8Host = $envMap['VMNET8_HOSTIP']
if (-not $Vmnet8Host) {
  try {
    $ipObj = Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet8" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ipObj) { $Vmnet8Host = $ipObj.IPAddress }
  } catch {}
}
if (-not $Vmnet8Host -and ($Only -eq 'ubuntu' -or -not $Only)) {
  throw "Cannot resolve VMnet8 host IP (set VMNET8_HOSTIP in .env or check VMware vmnet8)."
}

# Ports: HTTP 8800 on Private (vmnet8)
try {
  New-NetFirewallRule -DisplayName "Packer HTTP Any (8800)" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 8800 -Profile Private -ErrorAction Stop | Out-Null
} catch { } # ignore exists/non-admin

# Output dirs
$VmRoot     = Join-Path $InstallRoot 'VMs'
$UbuntuOut  = Join-Path $VmRoot 'Ubuntu'
$WindowsOut = Join-Path $VmRoot 'Windows'
New-Directory $UbuntuOut
New-Directory $WindowsOut

# ---------- Runtime headless preference (CLI > ENV > HCL default) ----------
$HeadlessPref = $Headless.IsPresent
Write-Info ("Forcing headless mode: {0}" -f $HeadlessPref)

# ---------- Packer run helpers ----------
function Invoke-PackerInit([string]$tpl,[string]$log){
  $tplDir  = [System.IO.Path]::GetDirectoryName($tpl)
  $tplLeaf = [System.IO.Path]::GetFileName($tpl)
  $args    = @('init', $tplLeaf)
  Write-Info ("RUN: init {0}" -f $tpl)
  Push-Location $tplDir
  try {
    & $PackerExe @args 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) {
      $tail = (Test-Path $log) ? ((Get-Content $log -Tail 60) -join "`n") : ''
      throw "packer init failed ($LASTEXITCODE) :: $tpl`n--- last lines ---`n$tail"
    }
  } finally { Pop-Location }
}

function Invoke-PackerValidate([string]$tpl,[string]$log,[hashtable]$vars){
  $tplDir  = [System.IO.Path]::GetDirectoryName($tpl)
  $tplLeaf = [System.IO.Path]::GetFileName($tpl)
  $args    = @('validate')
  foreach($k in $vars.Keys){ $args += @('-var',("{0}={1}" -f $k,$vars[$k])) }
  $args += $tplLeaf
  Write-Info ("RUN: validate {0}" -f $tpl)
  Push-Location $tplDir
  try {
    & $PackerExe @args 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) {
      $tail = (Test-Path $log) ? ((Get-Content $log -Tail 60) -join "`n") : ''
      throw "packer validate failed ($LASTEXITCODE) :: $tpl`n--- last lines ---`n$tail"
    }
  } finally { Pop-Location }
}

function Invoke-PackerBuild([string]$tpl,[string]$log,[hashtable]$vars,[int]$maxMinutes){
  $env:PACKER_LOG      = '1'
  $env:PACKER_LOG_PATH = $log

  $tplDir  = [System.IO.Path]::GetDirectoryName($tpl)
  $tplLeaf = [System.IO.Path]::GetFileName($tpl)

  $args = @('build','-timestamp-ui','-force')
  foreach($k in $vars.Keys){ $args += @('-var',("{0}={1}" -f $k,$vars[$k])) }
  $args += $tplLeaf

  # PS 5.1: -ArgumentList must be ONE string
  $argStr = ($args | ForEach-Object {
    if ($_ -match '[\s"`]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
  }) -join ' '

  Write-Info ("RUN: build {0}" -f $tpl)
  $p = Start-Process -FilePath $PackerExe -ArgumentList $argStr -PassThru -WorkingDirectory $tplDir

  $start = Get-Date
  while (-not $p.HasExited) {
    Show-Stage -log $log -start $start -max $maxMinutes
    if (((Get-Date) - $start).TotalMinutes -ge $maxMinutes) {
      try { Stop-Process -Id $p.Id -Force } catch {}
      throw "Timeout after $maxMinutes min (log: $log)"
    }
    Start-Sleep -Seconds 5
    try { $p.Refresh() } catch {}
  }
  if ($p.ExitCode -ne 0) {
    $tail = ''
    if (Test-Path -LiteralPath $log) {
      $tail = ((Get-Content -LiteralPath $log -Tail 200 -ErrorAction SilentlyContinue) -join "`n")
    }
    if ($tail -match '(?i)build was cancelled|received interrupt') {
      Write-Warn "Packer reported a cancellation. Auto-retrying once in 10s (log: $log)..."
      Start-Sleep -Seconds 10
      return Invoke-PackerBuild $tpl $log $vars $maxMinutes
    }
    throw "packer build failed ($($p.ExitCode)) (log: $log)`n--- last lines ---`n$tail"
  }
  Write-Progress -Activity "Packer build" -Completed
  Write-Ok ("Build OK (log: {0})" -f $log)
}

# ---------- Ubuntu build (optional) ----------
if ($Only -eq 'ubuntu' -or -not $Only) {
  if (-not (Test-Path -LiteralPath $isoUbuntu)) { throw "Ubuntu ISO not found in $IsoRoot" }
  $logU = New-LogFile 'ubuntu'
  Write-Info ("Ubuntu build log: {0}" -f $logU)

  # --- Seed prep (read from repo, inject key, rotate instance-id) ---
  $udPath     = Join-Path $SeedDir 'user-data'
  $mdPath     = Join-Path $SeedDir 'meta-data'
  if (-not (Test-Path -LiteralPath $udPath)) { throw "Missing user-data at $udPath" }

  $origUd     = Get-Content -LiteralPath $udPath -Raw
  $utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

  try {
    # 1) inject public key into placeholder, normalize to LF, write back without BOM
    $patchedUd = $origUd.Replace('__PUBKEY__', $pub) -replace "`r",""
    [System.IO.File]::WriteAllText($udPath, $patchedUd, $utf8NoBom)

    # 2) write meta-data with fresh instance-id each run
    $iid = 'iid-containerhost-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $md  = "instance-id: $iid`nlocal-hostname: containerhost`n"
    [System.IO.File]::WriteAllText($mdPath, $md, $utf8NoBom)

    # 3) run packer with your existing vars
    $varsU = @{
      iso_path             = $isoUbuntu
      ssh_private_key_file = $KeyPath
      output_dir           = $UbuntuOut
      vmnet8_host_ip       = $Vmnet8Host
      ssh_username         = 'labadmin'
    }

    Invoke-PackerInit     $Utpl $logU
    Invoke-PackerValidate $Utpl $logU $varsU
    Invoke-PackerBuild    $Utpl $logU $varsU $UbuntuMaxMinutes
  }
  finally {
    # Restore the committed file (with __PUBKEY__) so secrets aren't left in repo
    [System.IO.File]::WriteAllText($udPath, $origUd, $utf8NoBom)
    Write-Info "Restored template user-data (placeholder version) at $udPath"
  }
}

# ---------- Windows build (optional) ----------
if ($Only -eq 'windows' -or -not $Only) {
    if (-not (Test-Path -LiteralPath $isoWindows)) { 
        throw "Windows 11 ISO not found in $IsoRoot" 
    }
    
    # Add this line to define the log file for Windows build
    $logW = New-LogFile 'windows'
    
    $windowsBuildScript = Join-Path $PSScriptRoot 'windows-build.ps1'
    & $windowsBuildScript -IsoWindows $isoWindows -WindowsOut $WindowsOut -LogW $logW `
                         -Wtpl $Wtpl -PackerExe $PackerExe -WindowsMaxMinutes $WindowsMaxMinutes
}

# ---------- Artifact gate + persist ----------
$targets = @()
if ($Only -eq 'ubuntu'  -or -not $Only) { $targets += @{ Name='Ubuntu';  Dir=$UbuntuOut;  Pattern='*.vmx' } }
if ($Only -eq 'windows' -or -not $Only) { $targets += @{ Name='Windows'; Dir=$WindowsOut; Pattern='*.vmx' } }

$artifacts = Wait-ForArtifacts -Targets $targets -MaxSeconds 120

$StateDir = Join-Path $InstallRoot 'state'
New-Directory $StateDir
$artifactArray = @()
foreach ($k in $artifacts.Keys) { $artifactArray += @{ name = $k; vmx = $artifacts[$k] } }
$artifactJson = $artifactArray | ConvertTo-Json -Depth 3
$artifactFile = Join-Path $StateDir 'packer-artifacts.json'
Set-Content -LiteralPath $artifactFile -Value $artifactJson -Encoding UTF8

Write-Host "`nArtifacts ready:" -ForegroundColor Cyan
$artifactArray | ForEach-Object { Write-Host (" - {0}: {1}" -f $_.name, $_.vmx) }
Write-Host ("Saved: {0}" -f $artifactFile)

Write-Host "`nPacker builds completed." -ForegroundColor Green
if ($Vmnet8Host) { Write-Host ("Seed server bind: http://{0}:8800 (VMnet8)" -f $Vmnet8Host) -ForegroundColor Cyan }