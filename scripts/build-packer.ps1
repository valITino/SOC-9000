# scripts/build-packer.ps1 — SSH key provisioning + progress/timeout + clean logging + artifact gate
[CmdletBinding()]
param(
  [ValidateSet('ubuntu','windows')]
  [string]$Only,
  [int]$UbuntuMaxMinutes  = 45,
  [int]$WindowsMaxMinutes = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
function Get-DotEnv([string]$Path){
  if(!(Test-Path $Path)){ throw ".env not found at $Path" }
  $m=@{}; Get-Content $Path | ? {$_ -and $_ -notmatch '^\s*#'} | % {
    if($_ -match '^([^=]+)=(.*)$'){ $m[$matches[1].Trim()] = $matches[2].Trim() }
  }; $m
}
function Assert-Tool([string]$exe,[string]$hint){ try { Get-Command $exe -ErrorAction Stop | Out-Null } catch { Write-Error "$exe not found. $hint"; exit 2 } }
function Assert-Exists([string]$p,[string]$label){ if(!(Test-Path $p)){ throw "$label not found: $p" } }
function Find-Iso([string]$dir,[string[]]$patterns){
  if(!(Test-Path $dir)){ return $null }
  $cands = foreach($pat in $patterns){ Get-ChildItem -Path $dir -Filter $pat -ErrorAction SilentlyContinue }
  $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# prints progress, but tails only when it actually changes (<= every 20s)
$script:_lastTail = ''
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
  $text = (Test-Path $log) ? ((Get-Content $log -Tail 200 -ErrorAction SilentlyContinue) -join "`n") : ''
  $done = 0; foreach($s in $stages){ if($text -match $s.P){ $done++ } }
  $pct = [int](($done / $stages.Count) * 100)
  $elapsed = (Get-Date)-$start
  $limit=[TimeSpan]::FromMinutes($max)
  Write-Progress -Activity "Packer build" -Status ("Elapsed {0:hh\:mm\:ss} / {1:hh\:mm}" -f $elapsed,$limit) -PercentComplete $pct

  if ($text) {
    $last = ((($text -split "`n") | Select-Object -Last 10) -join "`n")
    $since = ((Get-Date) - $script:_lastTailAt).TotalSeconds
    if ($last -ne $script:_lastTail -and $since -ge 20) {
      Write-Host "`n--- packer tail ---`n$last`n--------------------"
      $script:_lastTail   = $last
      $script:_lastTailAt = Get-Date
    }
  }
}

function Run-Packer([string]$tpl,[hashtable]$vars,[string]$name,[int]$max){
  $ts  = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $log = Join-Path $env:TEMP ("packer-{0}-{1}.log" -f $name,$ts)

  # Build args and enable Packer logging to $log (no Start-Process redirection needed)
  $args = @('build','-timestamp-ui','-color=false','-force')
  foreach($k in $vars.Keys){ $args += @('-var',("{0}={1}" -f $k,$vars[$k])) }
  $args += $tpl
  $env:PACKER_LOG      = '1'
  $env:PACKER_LOG_PATH = $log

  $p = Start-Process -FilePath 'packer' `
        -ArgumentList $args `
        -PassThru `
        -WorkingDirectory (Split-Path $tpl -Parent)

  $start = Get-Date
  while (-not $p.HasExited) {
    Show-Stage -log $log -start $start -max $max
    if (((Get-Date) - $start).TotalMinutes -ge $max) {
      try { Stop-Process -Id $p.Id -Force } catch {}
      throw "Timeout after $max min :: $name (log: $log)"
    }
    Start-Sleep -Seconds 5
    try { $p.Refresh() } catch {}
  }

  $exit = $p.ExitCode
  $tail = (Test-Path $log) ? ((Get-Content $log -Tail 200 -ErrorAction SilentlyContinue) -join "`n") : ''

  if ($exit -ne 0) {
    if ($tail -match '(?i)build was cancelled|received interrupt') {
      Write-Warning "Packer reported a cancellation for $name. Auto-retrying once in 10s (log: $log)..."
      Start-Sleep -Seconds 10
      return Run-Packer -tpl $tpl -vars $vars -name $name -max $max
    }
    throw "packer failed ($exit) :: $name (log: $log)`n--- last lines ---`n$tail"
  }

  Write-Progress -Activity "Packer build" -Completed
  Write-Host ("Build OK :: {0} (log: {1})" -f $name,$log) -ForegroundColor Green
}

# --- NEW: wait for VMX artifacts with their own progress bar ---
function Wait-ForArtifacts([array]$Targets,[int]$MaxSeconds=120){
  $t0 = Get-Date
  $found = @{}
  do {
    $ready = 0
    foreach ($t in $Targets) {
      if ($found.ContainsKey($t.Name)) { $ready++; continue }
      if (Test-Path $t.Dir) {
        $vmx = Get-ChildItem -Path $t.Dir -Filter $t.Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
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

# ---------- main ----------
$RepoRoot = Get-RepoRoot
Set-Location $RepoRoot
$EnvFile  = Join-Path $RepoRoot '.env'

Write-Host "== Packer preflight" -ForegroundColor Cyan
Assert-Tool 'packer' 'Install: winget install HashiCorp.Packer'
Assert-Tool 'ssh-keygen' 'Install Windows OpenSSH Client (optional feature)'
$pv = & packer --version; Write-Host "Packer: $pv"

$envMap  = Get-DotEnv $EnvFile
$IsoRoot = $envMap['ISO_DIR']; if(-not $IsoRoot){ throw ".env missing ISO_DIR" }
$InstallRoot = $envMap['INSTALL_ROOT']; if(-not $InstallRoot){ $InstallRoot = (Test-Path 'E:\') ? 'E:\SOC-9000-Install' : (Join-Path $env:SystemDrive 'SOC-9000-Install') }

# Ensure SSH keypair for Packer
$KeyDir  = Join-Path $InstallRoot 'keys'
$KeyPath = Join-Path $KeyDir 'id_ed25519'
$PubPath = "$KeyPath.pub"
New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
if (!(Test-Path $KeyPath)) {
  & ssh-keygen -t ed25519 -N "" -f $KeyPath | Out-Null
  Write-Host "Generated SSH key: $KeyPath"
}

# Assemble cloud-init seed (inject pubkey safely; single-quoted here-string to keep $6 hash literal)
$SeedDir = Join-Path $RepoRoot 'packer\ubuntu-container\http'
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null
$pub = (Get-Content $PubPath -Raw).Trim()

$ud = @'
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: containerhost
    username: labadmin
    # required by autoinstall; SSH password login stays OFF
    password: "$6$soc9000salt$3lw9WQteXTDh5dcIhNazz8ZsD8q5n59ReX.Jo2x96nLbu2tH5cMHSdrJNSDIWlfKRQzQJua4JXF0CwprHLBQh0"
  ssh:
    install-server: true
    allow-pw: false
  user-data:
    users:
      - name: labadmin
        ssh_authorized_keys:
          - __PUBKEY__
        groups: [sudo]
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
    package_update: true
    package_upgrade: true
    packages:
      - qemu-guest-agent
      - open-vm-tools
    runcmd:
      - systemctl enable --now qemu-guest-agent
      - systemctl enable --now ssh
'@
$ud = $ud.Replace('__PUBKEY__', $pub)
$ud = $ud -replace "`r",""
Set-Content -Path (Join-Path $SeedDir 'user-data') -Value $ud -Encoding UTF8 -NoNewline
Set-Content -Path (Join-Path $SeedDir 'meta-data') -Value "instance-id: iid-ubuntu-container`nlocal-hostname: containerhost`n" -Encoding UTF8

# Locate ISOs (prefer .env pin; else newest match)
$isoUbuntuName  = $envMap['ISO_UBUNTU'];  $isoUbuntu  = $isoUbuntuName  ? (Join-Path $IsoRoot $isoUbuntuName)  : $null
if (-not $isoUbuntu -or -not (Test-Path $isoUbuntu)) {
  $u = Find-Iso $IsoRoot @('ubuntu-22.04*.iso','ubuntu-22.04*server*.iso'); if ($u) { $isoUbuntu = $u.FullName; $isoUbuntuName = $u.Name }
}
$isoWindowsName = $envMap['ISO_WINDOWS']; $isoWindows = $isoWindowsName ? (Join-Path $IsoRoot $isoWindowsName) : $null
if (-not $isoWindows -or -not (Test-Path $isoWindows)) {
  $w = Find-Iso $IsoRoot @('Win*11*.iso','Windows*11*.iso','en-us_windows_11*.iso'); if ($w) { $isoWindows = $w.FullName; $isoWindowsName = $w.Name }
}
if ($Only -in @($null,'ubuntu')  -and -not (Test-Path $isoUbuntu))  { throw "Ubuntu ISO not found in $IsoRoot" }
if ($Only -in @($null,'windows') -and -not (Test-Path $isoWindows)) { throw "Windows 11 ISO not found in $IsoRoot" }

# Template paths
$Utpl = Join-Path $RepoRoot 'packer\ubuntu-container\ubuntu-container.pkr.hcl'
$Wtpl = Join-Path $RepoRoot 'packer\windows-victim\windows.pkr.hcl'
Assert-Exists $Utpl 'Ubuntu Packer template'
if (-not $Only) { Assert-Exists $Wtpl 'Windows Packer template' }

# ===== VM artifacts outside the repo =====
$VmRoot     = Join-Path $InstallRoot 'VMs'
$UbuntuOut  = Join-Path $VmRoot 'Ubuntu'
$WindowsOut = Join-Path $VmRoot 'Windows'
New-Item -ItemType Directory -Force -Path $UbuntuOut,$WindowsOut | Out-Null

# Resolve VMnet8 host IP for Packer's HTTP seed (prefer .env; else detect)
$Vmnet8Host = $envMap['VMNET8_HOSTIP']
if (-not $Vmnet8Host) {
  $Vmnet8Host = (Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet8" -AddressFamily IPv4 |
                 Select-Object -First 1 -ExpandProperty IPAddress)
}
if (-not $Vmnet8Host) { throw "Cannot resolve VMnet8 host IP (check VMware Virtual Network Editor)" }

# One-time firewall allow for port 8800 on Private (VMnet8)
try {
  New-NetFirewallRule -DisplayName "Packer HTTP Any (8800)" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 8800 -Profile Private -ErrorAction Stop | Out-Null
} catch { }  # ignore if it already exists

# Build vars per template
$varsUbuntu  = @{
  iso_path             = $isoUbuntu
  ssh_private_key_file = $KeyPath
  output_dir           = $UbuntuOut
  vmnet8_host_ip       = $Vmnet8Host
}
$varsWindows = @{
  iso_path   = $isoWindows
  output_dir = $WindowsOut
}

# Build selection
if ($Only -eq 'ubuntu')  {
  Run-Packer $Utpl $varsUbuntu  'ubuntu-container'  $UbuntuMaxMinutes
} elseif ($Only -eq 'windows') {
  Run-Packer $Wtpl $varsWindows 'windows-victim'    $WindowsMaxMinutes
} else {
  Run-Packer $Utpl $varsUbuntu  'ubuntu-container'  $UbuntuMaxMinutes
  Run-Packer $Wtpl $varsWindows 'windows-victim'    $WindowsMaxMinutes
}

# --- NEW: Gate on VMX presence with a clear progress bar, then persist paths ---
$targets = @()
if ($Only -eq 'ubuntu' -or -not $Only)  { $targets += @{ Name='Ubuntu';  Dir=$UbuntuOut;  Pattern='*.vmx' } }
if ($Only -eq 'windows' -or -not $Only) { $targets += @{ Name='Windows'; Dir=$WindowsOut; Pattern='*.vmx' } }

$artifacts = Wait-ForArtifacts -Targets $targets -MaxSeconds 120

$StateDir = Join-Path $InstallRoot 'state'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
# convert hashtable-of-name->vmx to an array for stable JSON
$artifactArray = @()
foreach ($k in $artifacts.Keys) { $artifactArray += @{ name = $k; vmx = $artifacts[$k] } }
$artifactJson = $artifactArray | ConvertTo-Json -Depth 3
$artifactFile = Join-Path $StateDir 'packer-artifacts.json'
Set-Content -Path $artifactFile -Value $artifactJson -Encoding UTF8

Write-Host "`nArtifacts ready:" -ForegroundColor Cyan
$artifactArray | ForEach-Object { Write-Host (" - {0}: {1}" -f $_.name, $_.vmx) }
Write-Host ("Saved: {0}" -f $artifactFile)

Write-Host "`nPacker builds completed." -ForegroundColor Green
Write-Host ("Seed server bind: http://{0}:8800 (VMnet8)" -f $Vmnet8Host) -ForegroundColor Cyan