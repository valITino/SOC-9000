# uninstall-soc9000.ps1 — Deep uninstall for SOC-9000 prereqs (PS5-safe)
# Removes: Packer, Git, kubectl, TigerVNC, PowerShell 7, WSL (Store + features + services + payload)
# Excludes: VMware changes (user resets in GUI)

[CmdletBinding()] param()
$ErrorActionPreference = 'Continue'

function Info($m){ Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Skip($m){ Write-Host "[SKIP]  $m" -ForegroundColor DarkGray }
function Warn2($m){ Write-Warning $m }

# --- Admin guard ---
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { Write-Host "[X] Please run this script as Administrator." -ForegroundColor Red; exit 1 }
} catch {}

# --- Logging ---
$LogPath = Join-Path $env:TEMP ("uninstall-soc9000-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
try { Start-Transcript -Path $LogPath -Append -ErrorAction Stop } catch {}

# --- Constants ---
$WinGetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
$UserWinApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
$PFWSL       = 'C:\Program Files\WSL'

$ShimPaths = @(
  (Join-Path $WinGetLinks 'packer.exe'),
  (Join-Path $WinGetLinks 'git.exe'),
  (Join-Path $WinGetLinks 'kubectl.exe'),
  (Join-Path $WinGetLinks 'vncviewer.exe'),
  (Join-Path $WinGetLinks 'pwsh.exe'),
  (Join-Path $WinGetLinks 'pwsh-preview.exe'),
  (Join-Path $UserWinApps 'pwsh.exe'),
  (Join-Path $UserWinApps 'pwsh-preview.exe'),
  (Join-Path $UserWinApps 'wsl.exe'),
  (Join-Path $UserWinApps 'ubuntu.exe'),
  (Join-Path $UserWinApps 'ubuntu2004.exe'),
  (Join-Path $UserWinApps 'ubuntu2204.exe'),
  (Join-Path $UserWinApps 'debian.exe'),
  (Join-Path $UserWinApps 'kali.exe'),
  (Join-Path $UserWinApps 'opensuse.exe'),
  (Join-Path $UserWinApps 'sles.exe')
) | Where-Object { $_ }

$PathMarkers = @('HashiCorp\Packer','Git\cmd','Git\bin','Kubernetes','chocolatey\bin','TigerVNC','PowerShell\7')

# --- Helpers ---
function Remove-IfExists([string]$Path){
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (Test-Path -LiteralPath $Path) {
    Info ("Removing: {0}" -f $Path)
    try {
      Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Attributes = 'Normal' } catch {}
      }
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch { Warn2 ("Failed to remove {0} :: {1}" -f $Path, $_.Exception.Message) }
  } else { Skip ("Not found: {0}" -f $Path) }
}

function Clean-Path([string[]]$Needles){
  foreach($scope in 'User','Machine'){
    $cur = [Environment]::GetEnvironmentVariable('Path',$scope)
    if (-not $cur) { continue }
    $parts = $cur.Split(';') | Where-Object { $_ -and $_.Trim() -ne '' }
    $keep = New-Object System.Collections.Generic.List[string]
    $rm = @()
    foreach($p in $parts){
      $hit = $false
      foreach($n in $Needles){ if ($p -like "*$n*") { $hit=$true; break } }
      if ($hit){ $rm += $p } else { [void]$keep.Add($p) }
    }
    if ($rm.Count -gt 0){ $rm | ForEach-Object { Info ("PATH[{0}] remove: {1}" -f $scope, $_) } }
    [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), $scope)
  }
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

function Probe([string]$label){
  Write-Host ""
  Write-Host ("=== PROBE: {0} ===" -f $label) -ForegroundColor Yellow
  Write-Host "PATH (Machine):" -ForegroundColor Yellow
  [Environment]::GetEnvironmentVariable('Path','Machine')
  Write-Host "`nPATH (User):" -ForegroundColor Yellow
  [Environment]::GetEnvironmentVariable('Path','User')

  Write-Host "`nWSL Status:`n" -ForegroundColor Yellow
  try {
    $rows = @()
    foreach($n in 'Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform'){
      $f = Get-WindowsOptionalFeature -Online -FeatureName $n -ErrorAction SilentlyContinue
      if ($f){ $rows += $f }
    }
    if ($rows.Count -gt 0){ $rows | Select-Object FeatureName,State | Format-Table -AutoSize }
  } catch {}
  if (Test-Path $PFWSL) { "C:\Program Files\WSL exists (will be removed or at reboot)" }
  $wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
  if ($wslCmd) { "wsl.exe path: $($wslCmd.Source)" }
  Write-Host ("=== END PROBE: {0} ===`n" -f $label) -ForegroundColor Yellow
}

# -------------- WSL section --------------
function Stop-WSL-Services {
  Info "Stopping/disabling WSL services (best-effort)"
  foreach($svc in 'WSLService','LxssManager'){
    try {
      $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
      if ($s) {
        if ($s.Status -eq 'Running'){ Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
        & sc.exe config $svc start= disabled | Out-Null
      }
    } catch {}
  }
  foreach($p in 'wslservice','wslhost','wslg','wslrelay','wsl'){
    try { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Unregister-WSL-Distros {
  $payloadPresent = Test-Path (Join-Path $PFWSL 'wslhost.exe')
  if (-not $payloadPresent){ Skip "No WSL payload detected; skipping distro unregister"; return }
  try { $d = & wsl.exe --list --quiet 2>$null } catch { $d = $null }
  if (-not $d){ Skip "No WSL distros detected"; return }
  $names = $d -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object {
    $_ -ne '' -and ($_ -notmatch 'install|installieren|Vorgang|Timeout|abbrechen')
  }
  foreach($n in $names){
    Info ("Unregistering WSL distro: {0}" -f $n)
    try { & wsl.exe --unregister $n 2>$null | Out-Null } catch {}
  }
}

function Remove-WSL-Appx {
  Info "Removing WSL Store packages (AllUsers + deprovision)"
  $namePatterns = @(
    'MicrosoftCorporationII.WindowsSubsystemForLinux*',
    'MicrosoftCorporationII.WSLg*',
    'MicrosoftCorporationII.WslKernel*',
    'MicrosoftCorporationII.WslGuiAppProxy*'
  )
  foreach($nl in $namePatterns){
    try {
      Get-AppxPackage -AllUsers -Name $nl -ErrorAction SilentlyContinue | ForEach-Object {
        Info ("Remove-AppxPackage (AllUsers): {0}" -f $_.PackageFullName)
        try { Remove-AppxPackage -AllUsers -Package $_.PackageFullName -ErrorAction SilentlyContinue } catch {}
      }
    } catch {}
    try {
      Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $nl } | ForEach-Object {
        Info ("Remove-AppxProvisionedPackage: {0}" -f $_.PackageName)
        try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null } catch {}
        if ($_.PackageFamilyName){
          try { dism.exe /Online /Remove-ProvisionedAppxPackage /PackageFamilyName:$($_.PackageFamilyName) | Out-Null } catch {}
        }
      }
    } catch {}
  }
}

function Disable-WSL-Features {
  Info "Disabling Windows features: WSL + VirtualMachinePlatform"
  try { dism.exe /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux /norestart | Out-Null } catch {}
  try { dism.exe /online /disable-feature /featurename:VirtualMachinePlatform /norestart | Out-Null } catch {}
}

function Remove-WSL-StartMenu-And-Explorer {
  Info "Removing Start-Menu shortcuts for WSL and distros"
  $shortcuts = @(
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\WSL.lnk',
    'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\WSL Settings.lnk',
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Ubuntu.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Debian.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Kali Linux.lnk')
  )
  foreach($s in $shortcuts){ Remove-IfExists $s }
  foreach($folder in @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Ubuntu'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Debian'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Kali Linux')
  )){ Remove-IfExists $folder }

  # Explorer "Linux" namespace
  try {
    $nsRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace'
    $linuxGuid = '{B2B4A4D1-2754-4140-A2EB-9A76D9D7CDC6}'
    $key = Join-Path $nsRoot $linuxGuid
    if (Test-Path $key){ Info ("Removing Explorer namespace key: {0}" -f $key); Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $nsRoot -ErrorAction SilentlyContinue | ForEach-Object {
      try { $val = (Get-Item $_.PsPath -ErrorAction SilentlyContinue).GetValue('', $null) } catch { $val = $null }
      if ($val -and ($val -match '^(Linux|WSL|Windows Subsystem for Linux)$')){
        Info ("Removing Explorer namespace key (by name): {0}" -f $_.PsPath)
        try { Remove-Item $_.PsPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
      }
    }
    Info "Refreshing Explorer (to clear navigation pane)…"
    try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue } catch {}
  } catch {}
}

function Fix-NetworkProvider {
  try {
    $rk = 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider'
    $p = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
    if ($p){
      foreach($name in 'ProviderOrder','HWOrder'){
        $cur = $p.$name
        if ($cur -and ($cur -match 'WslNetworkProvider')){
          $new = ($cur -split ',') | Where-Object { $_ -and $_ -ne 'WslNetworkProvider' }
          Set-ItemProperty -Path $rk -Name $name -Value ($new -join ',') -ErrorAction SilentlyContinue
          Info ("NetworkProvider {0}: removed WslNetworkProvider" -f $name)
        }
      }
    }
  } catch {}
}

function Remove-WSL-Payload {
  if (-not (Test-Path $PFWSL)) { Skip "Program Files WSL folder not present"; return }
  Info ("Removing Program Files WSL folder: {0}" -f $PFWSL)
  try { takeown /f "$PFWSL" /r /d Y | Out-Null } catch {}
  try { icacls "$PFWSL" /grant "*S-1-5-32-544:(F)" /grant "NT AUTHORITY\SYSTEM:(F)" /t /c | Out-Null } catch {}
  try { attrib -r -s -h "$PFWSL" /s /d } catch {}
  try {
    Remove-Item -LiteralPath "$PFWSL" -Recurse -Force -ErrorAction Stop
  } catch {
    Warn2 ("Failed to remove {0} :: {1}" -f $PFWSL, $_.Exception.Message)
    Info  ("Scheduling deletion on next reboot: {0}" -f $PFWSL)
    $typeDef = @"
using System;
using System.Runtime.InteropServices;
public static class MoveEx {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool MoveFileEx(string existing, string replacement, int flags);
}
"@
    try { Add-Type -TypeDefinition $typeDef -ErrorAction SilentlyContinue } catch {}
    try {
      $ok = [MoveEx]::MoveFileEx($PFWSL, $null, 0x4)  # MOVEFILE_DELAY_UNTIL_REBOOT
      if ($ok){ Info ("Scheduled for deletion on next reboot: {0}" -f $PFWSL) } else { Warn2 "MoveFileEx returned false (already scheduled or ineligible)" }
    } catch {}
  }
}

function Uninstall-WSL {
  Info "=== Removing Windows Subsystem for Linux (complete) ==="
  Stop-WSL-Services
  Unregister-WSL-Distros
  Remove-WSL-Appx
  Disable-WSL-Features
  Remove-IfExists (Join-Path $env:LOCALAPPDATA 'lxss')
  Remove-IfExists (Join-Path $env:LOCALAPPDATA 'wsl')
  try { Remove-Item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Lxss' -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  Remove-WSL-StartMenu-And-Explorer
  Fix-NetworkProvider
  Remove-WSL-Payload
  Info "WSL removal staged. Reboot recommended to fully clear Search/feature state."
}

# -------------- App removers --------------
function Uninstall-By-UninstallString([string[]]$NameLike){
  foreach($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'){
    try {
      Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty -Path $_.PsPath -ErrorAction SilentlyContinue
        if ($p.DisplayName){
          foreach($nl in $NameLike){
            if ($p.DisplayName -like $nl){
              Info ("Registry uninstall: {0}" -f $p.DisplayName)
              try {
                if ($p.UninstallString){
                  $cmd = $p.UninstallString
                  if ($cmd -match 'msiexec\.exe'){
                    & cmd.exe /c "$cmd /qn /norestart" | Out-Null
                  } else {
                    & cmd.exe /c "$cmd /S" | Out-Null
                  }
                }
              } catch {}
            }
          }
        }
      }
    } catch {}
  }
}

function Remove-Shims { foreach($s in $ShimPaths){ Remove-IfExists $s } }

# -------------- RUN --------------
Info "=== Uninstalling SOC-9000 prerequisites (deep) ==="
Probe "BEFORE"

# --- Packer ---
Info "--- Packer ---"
Uninstall-By-UninstallString @('HashiCorp Packer*')
Remove-IfExists (Join-Path $env:APPDATA 'packer')
Remove-IfExists (Join-Path $env:APPDATA 'packer.d')
Remove-IfExists (Join-Path $env:LOCALAPPDATA 'packer')
Remove-IfExists (Join-Path $env:LOCALAPPDATA 'packer.d')
Remove-IfExists (Join-Path $env:USERPROFILE '.packer.d')
Remove-IfExists 'C:\Program Files\HashiCorp\Packer'
Remove-IfExists 'C:\Program Files (x86)\HashiCorp\Packer'
Remove-IfExists (Join-Path $env:LOCALAPPDATA 'HashiCorp\Packer')

# --- Git ---
Info "--- Git ---"
Uninstall-By-UninstallString @('Git*','Git LFS*','GitHub CLI*','GitHub Desktop*','vs_githubprotocolhandlermsi*')
Remove-IfExists (Join-Path $env:USERPROFILE '.gitconfig')
Remove-IfExists (Join-Path $env:USERPROFILE '.git-credentials')
Remove-IfExists (Join-Path $env:USERPROFILE '.git-credential-cache')
Remove-IfExists (Join-Path $env:LOCALAPPDATA 'Programs\Git')
Remove-IfExists (Join-Path $env:APPDATA 'git')
Remove-IfExists 'C:\Program Files\Git'
Remove-IfExists 'C:\Program Files\Git LFS'
Remove-IfExists 'C:\ProgramData\chocolatey\lib\git'
Remove-IfExists 'C:\ProgramData\chocolatey\bin\git.exe'

# --- kubectl ---
Info "--- kubectl ---"
Uninstall-By-UninstallString @('Kubernetes kubectl*','kubectl*')
Remove-IfExists (Join-Path $env:USERPROFILE '.kube')
Remove-IfExists 'C:\Program Files\Kubernetes'
Remove-IfExists 'C:\Program Files (x86)\Kubernetes'
Remove-IfExists 'C:\ProgramData\chocolatey\lib\kubernetes-cli'
Remove-IfExists 'C:\ProgramData\chocolatey\bin\kubectl.exe'

# --- TigerVNC ---
Info "--- TigerVNC ---"
Uninstall-By-UninstallString @('TigerVNC*','RealVNC*','UltraVNC*')
Remove-IfExists (Join-Path $env:APPDATA 'TigerVNC')
Remove-IfExists 'C:\Program Files\TigerVNC'
Remove-IfExists 'C:\Program Files (x86)\TigerVNC'
Remove-IfExists 'C:\ProgramData\chocolatey\lib\tigervnc'
Remove-IfExists 'C:\ProgramData\chocolatey\bin\vncviewer.exe'

# --- PowerShell 7 ---
Info "--- PowerShell 7 ---"
Uninstall-By-UninstallString @('PowerShell* 7*','PowerShell* Preview*')
Remove-IfExists (Join-Path $env:USERPROFILE 'Documents\PowerShell')
Remove-IfExists (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell')
Remove-IfExists (Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell')
Remove-IfExists 'C:\Program Files\PowerShell\7'
Remove-IfExists 'C:\Program Files\PowerShell\7-preview'

# --- Remove WinGet & WindowsApps shims (all tools) ---
Remove-Shims

# --- PATH cleanup ---
Clean-Path $PathMarkers

# --- WSL (deep) ---
Uninstall-WSL

# --- SOC-9000 staging dirs ---
Remove-IfExists 'E:\SOC-9000-Install'
Remove-IfExists (Join-Path $env:USERPROFILE 'Downloads\SOC-9000-Install')
Remove-IfExists (Join-Path $env:TEMP 'SOC-9000*')

Probe "AFTER"

if ($LogPath) { Info ("Log written: {0}" -f $LogPath) }

# --- UX: Offer reboot ---
$resp = Read-Host "`nPress ENTER to reboot now (recommended), or type N then ENTER to skip"
if ($resp -eq '') {
  try { Stop-Transcript | Out-Null } catch {}
  try { Restart-Computer -Force } catch { try { shutdown /r /t 5 } catch {} }
  exit
} else {
  Info "Reboot skipped by user."
  try { Stop-Transcript | Out-Null } catch {}
}
