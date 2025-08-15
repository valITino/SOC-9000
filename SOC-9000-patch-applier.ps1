# path: SOC-9000-patch-applier.ps1
[CmdletBinding()]
param(
  # Where your repo root is (defaults to current folder).
  [string]$RepoRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "== SOC-9000 :: Patch applier ==" -ForegroundColor Cyan
Write-Host "Repo: $RepoRoot"

# ---------- file contents ----------
$Files = [ordered]@{

'scripts\generate-vmnet-profile.ps1' = @'
[CmdletBinding()]
param(
  [string]$EnvPath,
  [string]$OutFile,
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-DotEnv([string]$Path){
  $m=@{}; if(Test-Path $Path){
    Get-Content $Path | Where-Object {$_ -and $_ -notmatch '^\s*#'} | ForEach-Object {
      if($_ -match '^([^=]+)=(.*)$'){ $m[$matches[1].Trim()]=$matches[2].Trim() }
    }
  }; $m
}
function ThrowIfFalse($cond,[string]$msg){ if(-not $cond){ throw $msg } }
function Is-IPv4([string]$ip){
  if($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$'){ return $false }
  foreach($oct in $ip -split '\.'){ if([int]$oct -gt 255){ return $false } }
  return $true
}
function Is-IPv4Mask([string]$mask){
  if(-not (Is-IPv4 $mask)){ return $false }
  $bytes=[Net.IPAddress]::Parse($mask).GetAddressBytes()
  $bits = ($bytes|%{[Convert]::ToString($_,2).PadLeft(8,'0')}) -join ''
  return ($bits -notmatch '01')
}
function Is-Network24([string]$subnet){
  if(-not (Is-IPv4 $subnet)){ return $false }
  $oct = $subnet -split '\.'
  return ($oct[3] -eq '0')
}
function HostOnlyIP([string]$subnet){
  $oct = $subnet -split '\.'; "$($oct[0]).$($oct[1]).$($oct[2]).1"
}
$repoRoot = Split-Path $PSScriptRoot -Parent
$envFile  = if($EnvPath){ $EnvPath } elseif (Test-Path (Join-Path $repoRoot '.env')) { Join-Path $repoRoot '.env' } elseif (Test-Path (Join-Path $repoRoot '.env.example')) { Join-Path $repoRoot '.env.example' } else { $null }
$envMap   = if($envFile){ Read-DotEnv $envFile } else { @{} }
$Vmnet8Subnet  = $envMap['VMNET8_SUBNET'];  if(-not $Vmnet8Subnet){  $Vmnet8Subnet  = '192.168.37.0' }
$Vmnet8Mask    = $envMap['VMNET8_MASK'];    if(-not $Vmnet8Mask){    $Vmnet8Mask    = '255.255.255.0' }
$Vmnet8HostIp  = $envMap['VMNET8_HOSTIP'];  if(-not $Vmnet8HostIp){  $Vmnet8HostIp  = '192.168.37.1' }
$Vmnet8Gateway = $envMap['VMNET8_GATEWAY']; if(-not $Vmnet8Gateway){ $Vmnet8Gateway = '192.168.37.2' }
$HostOnlyMask  = $envMap['HOSTONLY_MASK'];  if(-not $HostOnlyMask){  $HostOnlyMask  = '255.255.255.0' }
$Vmnet20Subnet = $envMap['VMNET20_SUBNET']; if(-not $Vmnet20Subnet){ $Vmnet20Subnet = '172.22.10.0' }
$Vmnet21Subnet = $envMap['VMNET21_SUBNET']; if(-not $Vmnet21Subnet){ $Vmnet21Subnet = '172.22.20.0' }
$Vmnet22Subnet = $envMap['VMNET22_SUBNET']; if(-not $Vmnet22Subnet){ $Vmnet22Subnet = '172.22.30.0' }
$Vmnet23Subnet = $envMap['VMNET23_SUBNET']; if(-not $Vmnet23Subnet){ $Vmnet23Subnet = '172.22.40.0' }
ThrowIfFalse (Is-Network24 $Vmnet8Subnet)   "VMNET8_SUBNET is invalid (must be A.B.C.0)."
ThrowIfFalse (Is-IPv4Mask $Vmnet8Mask)      "VMNET8_MASK is invalid."
ThrowIfFalse (Is-IPv4 $Vmnet8HostIp)        "VMNET8_HOSTIP is invalid."
ThrowIfFalse (Is-IPv4 $Vmnet8Gateway)       "VMNET8_GATEWAY is invalid."
foreach($s in @($Vmnet20Subnet,$Vmnet21Subnet,$Vmnet22Subnet,$Vmnet23Subnet)){
  ThrowIfFalse (Is-Network24 $s) "Host-only subnet '$s' is invalid (must be A.B.C.0)."
}
ThrowIfFalse (Is-IPv4Mask $HostOnlyMask) "HOSTONLY_MASK is invalid."
$lines = @()
$lines += @(
  "add vnet vmnet8",
  "set vnet vmnet8 addr $Vmnet8Subnet",
  "set vnet vmnet8 mask $Vmnet8Mask",
  "set adapter vmnet8 addr $Vmnet8HostIp",
  "set nat vmnet8 internalipaddr $Vmnet8Gateway",
  "update adapter vmnet8",
  "update nat vmnet8",
  "update dhcp vmnet8",
  ""
)
foreach($def in @(@{n=20;s=$Vmnet20Subnet},@{n=21;s=$Vmnet21Subnet},@{n=22;s=$Vmnet22Subnet},@{n=23;s=$Vmnet23Subnet})) {
  $hn = "vmnet$($def.n)"; $hip = HostOnlyIP $def.s
  $lines += @(
    "add vnet $hn",
    "set vnet $hn addr $($def.s)",
    "set vnet $hn mask $HostOnlyMask",
    "set adapter $hn addr $hip",
    "update adapter $hn",
    ""
  )
}
$text = ($lines -join "`r`n")
$art = Join-Path $repoRoot 'artifacts\network'
if (-not $OutFile) { $OutFile = Join-Path $art 'vmnet-profile.txt' }
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
Set-Content -Path $OutFile -Value $text -Encoding ASCII
$logDir = Join-Path $repoRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"; $logCopy = Join-Path $logDir "vmnet-profile-$ts.txt"
Set-Content -Path $logCopy -Value $text -Encoding ASCII
Write-Host "VMnet profile written: $OutFile"
if ($PassThru) { $text }
'@

'scripts\setup-soc9000.ps1' = @'
[CmdletBinding()]
param([switch]$ManualNetwork)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Ensure-Admin {
  $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null; exit 0
  }
}
function Read-DotEnv([string]$Path){
  if(-not (Test-Path $Path)){ return @{} }
  $m=@{}; Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($v -ne $null) { $m[$k.Trim()] = $v.Trim() }
  }; $m
}
function Require-DriveE { if (-not (Test-Path 'E:\')) { throw "Drive E:\ was not found. Please attach/create an E: volume, then re-run." } }
function Ensure-Dirs([string]$InstallRoot,[string]$RepoRoot){
  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot 'isos') | Out-Null
  New-Item -ItemType Directory -Force -Path $RepoRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'artifacts\network') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'logs') | Out-Null
}
function Get-RequiredIsos([hashtable]$EnvMap,[string]$IsoDir){
  $pairs = @()
  foreach ($key in $EnvMap.Keys) {
    if ($key -like 'ISO_*' -or $key -eq 'NESSUS_DEB') {
      $name = $EnvMap[$key]; if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $pairs += [pscustomobject]@{ Key=$key; FileName=$name; FullPath=(Join-Path $IsoDir $name); Exists=(Test-Path (Join-Path $IsoDir $name)) }
    }
  }; $pairs
}
function Prompt-MissingIsosLoop([pscustomobject[]]$IsoList, [string]$IsoDir){
  while ($true) {
    $missing = $IsoList | Where-Object { -not $_.Exists }
    if ($missing.Count -eq 0) { return }
    Write-Warning "You need to download the following ISOs/packages before continuing:"
    $missing | ForEach-Object { Write-Host ("  - {0}  →  {1}" -f $_.Key, $_.FileName) -ForegroundColor Yellow }
    Write-Host ""; Write-Host ("Store them here: {0}" -f $IsoDir) -ForegroundColor Cyan
    $ans = Read-Host "[L]et's re-check or [A]bort mission?"
    if ($ans -match '^[Aa]') { Write-Host "Aborting as requested." -ForegroundColor Yellow; exit 1 }
    foreach ($x in $IsoList) { $x.Exists = Test-Path $x.FullPath }
  }
}
function Find-Exe([string[]]$Candidates){ foreach($p in $Candidates){ if(Test-Path $p){ return $p } } $null }
function Import-VMnetProfile([string]$RepoRoot,[switch]$ForceManual){
  $gen = Join-Path $RepoRoot 'scripts\generate-vmnet-profile.ps1'
  if(-not (Test-Path $gen)){ throw "Missing $gen" }
  $out = Join-Path $RepoRoot 'artifacts\network\vmnet-profile.txt'
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $out
  if ($LASTEXITCODE -ne 0) { throw "generate-vmnet-profile.ps1 failed." }
  if ($ForceManual) { throw "Forced manual networking" }
  $vnetlib = Find-Exe @("C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe","C:\Program Files\VMware\VMware Workstation\vnetlib64.exe")
  if (-not $vnetlib) { throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run." }
  Write-Host "Importing VMnet profile via vnetlib64 ..." -ForegroundColor Cyan
  & $vnetlib -- stop dhcp; if($LASTEXITCODE -ne 0){ Write-Warning "stop dhcp returned $LASTEXITCODE" }
  & $vnetlib -- stop nat;  if($LASTEXITCODE -ne 0){ Write-Warning "stop nat returned $LASTEXITCODE" }
  & $vnetlib -- import $out
  if($LASTEXITCODE -ne 0){ throw "vnetlib64 import failed ($LASTEXITCODE). See logs\vmnet-profile-*.txt" }
  & $vnetlib -- start dhcp; if($LASTEXITCODE -ne 0){ Write-Warning "start dhcp returned $LASTEXITCODE" }
  & $vnetlib -- start nat;  if($LASTEXITCODE -ne 0){ Write-Warning "start nat returned $LASTEXITCODE" }
  Write-Host "VMware networking: OK (import applied)" -ForegroundColor Green
}
function Run-IfExists([string]$ScriptPath, [string]$FriendlyName){
  if (Test-Path $ScriptPath) {
    Write-Host "Running $FriendlyName ..." -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Verbose
    if ($LASTEXITCODE -ne 0) { throw "$FriendlyName exited with code $LASTEXITCODE" }
    Write-Host "$FriendlyName: OK" -ForegroundColor Green
  }
}
Ensure-Admin; Require-DriveE
$InstallRoot = 'E:\SOC-9000-Install'; $RepoRoot = 'E:\SOC-9000'; $IsoDir = Join-Path $InstallRoot 'isos'
Ensure-Dirs -InstallRoot $InstallRoot -RepoRoot $RepoRoot
$envPath = Join-Path $RepoRoot '.env'
if (-not (Test-Path $envPath)) { $envExample = Join-Path $RepoRoot '.env.example'; if (Test-Path $envExample) { Copy-Item $envExample $envPath -Force; Write-Host "No .env found; seeded it from .env.example." -ForegroundColor Yellow } }
$envMap = Read-DotEnv $envPath
if (-not $envMap.ContainsKey('ISO_DIR')) { $envMap['ISO_DIR'] = $IsoDir }
$isoList = Get-RequiredIsos -EnvMap $envMap -IsoDir $envMap['ISO_DIR']
if ($isoList.Count -gt 0) { Prompt-MissingIsosLoop -IsoList $isoList -IsoDir $envMap['ISO_DIR'] } else { Write-Host "No required ISO keys were found in .env — skipping ISO check." -ForegroundColor Yellow }
try { Import-VMnetProfile -RepoRoot $RepoRoot -ForceManual:$ManualNetwork }
catch {
  Write-Warning "Automatic network import failed: $($_.Exception.Message)"
  Write-Host "Please configure the VMnets manually in the Virtual Network Editor, then close it to continue." -ForegroundColor Yellow
  $vmnetcfg = Find-Exe @("C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfg.exe","C:\Program Files\VMware\VMware Workstation\vmnetcfg.exe")
  if ($vmnetcfg) { Start-Process -FilePath $vmnetcfg -Wait } else {
    Write-Warning "vmnetcfg.exe was not found. Open VMware Workstation → Edit → Virtual Network Editor, configure, then come back."
    Read-Host "Press ENTER to continue after you’ve finished configuring the networks"
  }
}
try {
  Run-IfExists (Join-Path $RepoRoot 'scripts\wsl-prepare.ps1')       'wsl-prepare.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\wsl-bootstrap.ps1')     'wsl-bootstrap.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\host-prepare.ps1')      'host-prepare.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\verify-networking.ps1') 'verify-networking.ps1'
  Run-IfExists (Join-Path $RepoRoot 'scripts\lab-up.ps1')            'lab-up.ps1'
} catch { Write-Error "A follow-up step failed: $($_.Exception.Message)"; Write-Host "Fix the issue above and re-run this script. Nothing destructive was done." -ForegroundColor Yellow; exit 1 }
Write-Host ""; Write-Host "All requested steps completed." -ForegroundColor Green
'@

# Replaces the previous network config call; avoids duplicate -Verbose definitions
'scripts\host-prepare.ps1' = @'
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Ensure-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal $id
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
    Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null; exit 0
  }
}
function Find-Exe([string[]]$Candidates){ foreach($p in $Candidates){ if(Test-Path $p){ return $p } } $null }
Ensure-Admin
$logDir = Join-Path $PSScriptRoot "..\logs"; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try { Stop-Transcript | Out-Null } catch {}
$ts  = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "host-prepare-$ts.log"
Start-Transcript -Path $log -Force | Out-Null
try {
  $gen = Join-Path $PSScriptRoot 'generate-vmnet-profile.ps1'
  $out = Join-Path $PSScriptRoot '..\artifacts\network\vmnet-profile.txt'
  if (-not (Test-Path $gen)) { throw "Missing $gen" }
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $out
  if ($LASTEXITCODE -ne 0) { throw "generate-vmnet-profile.ps1 exited with code $LASTEXITCODE" }
  $vnetlib = Find-Exe @("C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe","C:\Program Files\VMware\VMware Workstation\vnetlib64.exe")
  if (-not $vnetlib) { throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+ (Virtual Network Editor) and re-run." }
  & $vnetlib -- stop dhcp; & $vnetlib -- stop nat
  & $vnetlib -- import $out
  if ($LASTEXITCODE -ne 0) { throw "vnetlib64 import failed: $LASTEXITCODE" }
  & $vnetlib -- start dhcp; & $vnetlib -- start nat
  Write-Host "Host network prepared via import." -ForegroundColor Green
  Stop-Transcript | Out-Null; exit 0
} catch {
  Write-Error "Host preparation FAILED: $($_.Exception.Message)"
  Write-Host  "See transcript: $log" -ForegroundColor Yellow
  Stop-Transcript | Out-Null; exit 1
}
'@

'ansible\roles\nessus_vm\tasks\main.yml' = @'
---
- name: Determine Nessus .deb name
  set_fact:
    nessus_deb: "{{ lookup('env', 'NESSUS_DEB') | default('nessus_latest_amd64.deb') }}"

- name: Fail if ISO_DIR_WSL not provided
  fail:
    msg: "ISO_DIR_WSL env not provided from host. Ensure the launcher passes ISO_DIR_WSL."
  when: lookup('env','ISO_DIR_WSL') | default('') | length == 0

- name: Copy Nessus .deb from Windows mount (isos dir)
  ansible.builtin.copy:
    src: "{{ lookup('env','ISO_DIR_WSL') }}/{{ nessus_deb }}"
    dest: "/tmp/{{ nessus_deb }}"
    remote_src: no
  become: yes

- name: Install Nessus .deb
  ansible.builtin.apt:
    deb: "/tmp/{{ nessus_deb }}"
    state: present
  become: yes

- name: Enable & start nessusd
  ansible.builtin.systemd:
    name: nessusd
    enabled: true
    state: started
  become: yes

- name: Register Nessus with activation code (if provided)
  when: lookup('env','NESSUS_ACTIVATION_CODE') | default('') | length > 0
  ansible.builtin.command: /opt/nessus/sbin/nessuscli fetch --register {{ lookup('env','NESSUS_ACTIVATION_CODE') }}
  register: nessus_vm_reg_out
  changed_when: "'already' not in (nessus_vm_reg_out.stdout | lower)"
  become: yes

- name: Wait for Nessus web UI
  ansible.builtin.uri:
    url: https://127.0.0.1:8834
    validate_certs: no
    status_code: 200,302,401
  register: nessus_ui
  until: nessus_ui is succeeded
  retries: 30
  delay: 5

- name: Optionally create admin user
  when: (lookup('env','NESSUS_ADMIN_USER') | default('')) | length > 0 and (lookup('env','NESSUS_ADMIN_PASS') | default('')) | length > 0
  ansible.builtin.shell: |
    /opt/nessus/sbin/nessuscli adduser --login {{ lookup('env','NESSUS_ADMIN_USER') }} --password {{ lookup('env','NESSUS_ADMIN_PASS') }} --admin yes <<EOF
    y
    EOF
  args:
    executable: /bin/bash
  changed_when: false
  become: yes
'@

'tests\Unit.EnvDefaults.Tests.ps1' = @'
# Tags: unit
[CmdletBinding()] param()
BeforeAll {
  $repo = Split-Path $PSScriptRoot -Parent
  $envExample = Join-Path $repo '.env.example'
  if (-not (Test-Path $envExample)) { throw ".env.example missing at repo root" }
  $content = Get-Content $envExample -Raw
  $script:globals = @(
    'LAB_ROOT','REPO_ROOT','ISO_DIR','ARTIFACTS_DIR','TEMP_DIR',
    'VMNET8_SUBNET','VMNET8_MASK','VMNET8_HOSTIP','VMNET8_GATEWAY',
    'VMNET20_SUBNET','VMNET21_SUBNET','VMNET22_SUBNET','VMNET23_SUBNET','HOSTONLY_MASK',
    'NESSUS_DEB','BACKUP_DIR','SNAPSHOT_RETENTION'
  )
  $script:content = $content
}
Describe ".env.example baseline" -Tag 'unit' {
  It "contains the required keys" {
    foreach($k in $script:globals){ $script:content | Should -Match ("^$k=") }
  }
}
'@

'tests\Unit.VMnetProfile.Tests.ps1' = @'
# Tags: unit
[CmdletBinding()] param()
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path $here -Parent
$gen  = Join-Path $repo 'scripts\generate-vmnet-profile.ps1'
Describe "VMnet profile generator" -Tag 'unit' {
  It "generates expected content from a sample env" {
    $tmpEnv = Join-Path $env:TEMP 'soc9000-test.env'
    @"
VMNET8_SUBNET=192.168.37.0
VMNET8_MASK=255.255.255.0
VMNET8_HOSTIP=192.168.37.1
VMNET8_GATEWAY=192.168.37.2
VMNET20_SUBNET=172.22.10.0
VMNET21_SUBNET=172.22.20.0
VMNET22_SUBNET=172.22.30.0
VMNET23_SUBNET=172.22.40.0
HOSTONLY_MASK=255.255.255.0
"@ | Set-Content -Path $tmpEnv -Encoding ASCII
    $out = Join-Path $env:TEMP 'soc9000-vmnet-import.txt'
    $text = & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -EnvPath $tmpEnv -OutFile $out -PassThru
    $expected = @"
add vnet vmnet8
set vnet vmnet8 addr 192.168.37.0
set vnet vmnet8 mask 255.255.255.0
set adapter vmnet8 addr 192.168.37.1
set nat vmnet8 internalipaddr 192.168.37.2
update adapter vmnet8
update nat vmnet8
update dhcp vmnet8

add vnet vmnet20
set vnet vmnet20 addr 172.22.10.0
set vnet vmnet20 mask 255.255.255.0
set adapter vmnet20 addr 172.22.10.1
update adapter vmnet20

add vnet vmnet21
set vnet vmnet21 addr 172.22.20.0
set vnet vmnet21 mask 255.255.255.0
set adapter vmnet21 addr 172.22.20.1
update adapter vmnet21

add vnet vmnet22
set vnet vmnet22 addr 172.22.30.0
set vnet vmnet22 mask 255.255.255.0
set adapter vmnet22 addr 172.22.30.1
update adapter vmnet22

add vnet vmnet23
set vnet vmnet23 addr 172.22.40.0
set vnet vmnet23 mask 255.255.255.0
set adapter vmnet23 addr 172.22.40.1
update adapter vmnet23
"@ -replace "`r`n","`n"
    ($text -replace "`r`n","`n") | Should -BeExactly $expected
    Test-Path $out | Should -BeTrue
  }
}
'@

'tests\Unit.IsoKeys.Tests.ps1' = @'
# Tags: unit
[CmdletBinding()] param()
function Get-RequiredIsosLocal {
  param([hashtable]$EnvMap,[string]$IsoDir)
  $pairs = @()
  foreach ($key in $EnvMap.Keys) {
    if ($key -like 'ISO_*' -or $key -eq 'NESSUS_DEB') {
      $name = $EnvMap[$key]
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $full = Join-Path $IsoDir $name
      $pairs += [pscustomobject]@{ Key=$key; FileName=$name; FullPath=$full; Exists=(Test-Path $full) }
    }
  }
  $pairs
}
Describe "ISO key detection" -Tag 'unit' {
  It "detects ISO_* and NESSUS_DEB entries" {
    $envMap = @{
      'ISO_UBUNTU' = 'ubuntu-24.04.1-live-server-amd64.iso'
      'ISO_PFSENSE' = 'pfSense-CE-2.7.2-RELEASE-amd64.iso'
      'NESSUS_DEB' = 'Nessus-10.8.1-ubuntu1404_amd64.deb'
      'OTHER_KEY' = 'ignored.txt'
    }
    $pairs = Get-RequiredIsosLocal -EnvMap $envMap -IsoDir 'C:\isos'
    ($pairs | Measure-Object).Count | Should -Be 3
    ($pairs | Where-Object Key -eq 'ISO_UBUNTU').FullPath | Should -BeExactly 'C:\isos\ubuntu-24.04.1-live-server-amd64.iso'
    ($pairs | Where-Object Key -eq 'NESSUS_DEB').FileName | Should -BeExactly 'Nessus-10.8.1-ubuntu1404_amd64.deb'
  }
}
'@

'tests\Integration.VMware.Tests.ps1' = @'
# Tags: integration
[CmdletBinding()] param()
function Find-VNetLib {
  foreach($p in @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe",
    "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe"
  )){ if (Test-Path $p) { return $p } }
  $null
}
Describe "VMware presence and non-destructive ops" -Tag 'integration' {
  It "finds vnetlib64.exe or skips" {
    $v = Find-VNetLib
    if (-not $v) { Set-ItResult -Skipped -Because "vnetlib64.exe not present"; return }
    Test-Path $v | Should -BeTrue
  }
  It "exports current profile (non-destructive) if vnetlib64.exe present" {
    $v = Find-VNetLib
    if (-not $v) { Set-ItResult -Skipped -Because "vnetlib64.exe not present"; return }
    $tmp = Join-Path $env:TEMP 'soc9000-export.txt'
    & $v -- export $tmp
    $LASTEXITCODE | Should -Be 0
    Test-Path $tmp | Should -BeTrue
  }
  It "optionally imports generated profile when SOC9000_ALLOW_IMPORT_IN_TESTS=1" {
    $v = Find-VNetLib
    if (-not $v) { Set-ItResult -Skipped -Because "vnetlib64.exe not present"; return }
    if ($env:SOC9000_ALLOW_IMPORT_IN_TESTS -ne '1') { Set-ItResult -Skipped -Because "import not enabled"; return }
    $repo = Split-Path $PSScriptRoot -Parent
    $gen  = Join-Path $repo 'scripts\generate-vmnet-profile.ps1'
    $out = Join-Path $env:TEMP 'soc9000-vmnet-import.txt'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $gen -OutFile $out
    & $v -- stop dhcp; & $v -- stop nat
    & $v -- import $out; $LASTEXITCODE | Should -Be 0
    & $v -- start dhcp; & $v -- start nat
  }
}
'@

'.github\workflows\windows-ci.yml' = @'
name: windows-ci
on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]
  workflow_dispatch:
jobs:
  test:
    runs-on: windows-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Install Pester
        shell: pwsh
        run: |
          Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
          Install-Module Pester -Scope CurrentUser -Force
      - name: Run unit tests
        shell: pwsh
        run: |
          Invoke-Pester -Path tests -Tag unit -CI -Output Detailed -OutputFormat NUnitXml -OutputFile TestResults.xml
      - name: Upload test results
        uses: actions/upload-artifact@v4
        with:
          name: pester-results
          path: TestResults.xml
'@

'README-PATCH.txt' = @'
This bundle installs:
- scripts\generate-vmnet-profile.ps1 (builds artifacts\network\vmnet-profile.txt from .env)
- scripts\setup-soc9000.ps1 (import-only vnetlib flow; manual fallback)
- scripts\host-prepare.ps1 (uses the same import-only flow)
- ansible\roles\nessus_vm\tasks\main.yml (reads NESSUS_* from env; auto-registers if activation code provided)
- tests\*.ps1 (Pester unit & integration tests; CI runs unit only)
- .github\workflows\windows-ci.yml (Windows CI with Pester)

Run:
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\SOC-9000-patch-applier.ps1
'@

'.env.example' = @'
LAB_ROOT=E:\SOC-9000
REPO_ROOT=E:\SOC-9000
ISO_DIR=E:\SOC-9000-Install\isos
ARTIFACTS_DIR=E:\SOC-9000\artifacts
TEMP_DIR=E:\SOC-9000\temp
VMNET8_SUBNET=192.168.37.0
VMNET8_MASK=255.255.255.0
VMNET8_HOSTIP=192.168.37.1
VMNET8_GATEWAY=192.168.37.2
VMNET20_SUBNET=172.22.10.0
VMNET21_SUBNET=172.22.20.0
VMNET22_SUBNET=172.22.30.0
VMNET23_SUBNET=172.22.40.0
HOSTONLY_MASK=255.255.255.0
NESSUS_DEB=nessus_latest_amd64.deb
NESSUS_ACTIVATION_CODE=
NESSUS_ADMIN_USER=nessusadmin
NESSUS_ADMIN_PASS=ChangeMe_S0C!
BACKUP_DIR=E:\SOC-9000\backups
SNAPSHOT_RETENTION=5
'@
}

# ---------- write files ----------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($rel in $Files.Keys) {
  $dst = Join-Path $RepoRoot $rel
  New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
  [System.IO.File]::WriteAllText($dst, $Files[$rel], $utf8NoBom)
  Write-Host "Wrote: $rel"
}

# Remove SOC-9000-installer.ps1 if present
$inst = Get-ChildItem -Path $RepoRoot -Filter 'SOC-9000-installer.ps1' -Recurse -ErrorAction SilentlyContinue
foreach ($i in $inst) {
  try { Remove-Item $i.FullName -Force -ErrorAction Stop; Write-Host ("Removed: {0}" -f $i.FullName) } catch {}
}

Write-Host ""
Write-Host "Patch files written into your repo."
