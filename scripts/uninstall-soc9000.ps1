# uninstall-soc9000.ps1
# Unified graceful uninstall + hard cleanup fallback + BEFORE/AFTER probe (PS5-safe)

[CmdletBinding()] param()
$ErrorActionPreference = 'Continue'

function Info($m){ Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Skip($m){ Write-Host "[SKIP]  $m" -ForegroundColor DarkGray }
function Warn2($m){ Write-Warning $m }

# --- Logging ---
$LogPath = Join-Path $env:TEMP ("uninstall-soc9000-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
try { Start-Transcript -Path $LogPath -Append -ErrorAction Stop } catch {}

# --- Probe helpers ---
$Targets = @(
  "C:\Program Files\HashiCorp\Packer",
  "C:\Program Files (x86)\HashiCorp\Packer",
  "$env:LOCALAPPDATA\HashiCorp\Packer",
  "C:\Program Files\Git",
  "C:\Program Files\Git LFS",
  "C:\Program Files\Kubernetes",
  "C:\Program Files (x86)\Kubernetes",
  "C:\Program Files\TigerVNC",
  "C:\Program Files (x86)\TigerVNC",
  "$env:ProgramData\chocolatey\lib\packer",
  "$env:ProgramData\chocolatey\lib\git",
  "$env:ProgramData\chocolatey\lib\kubernetes-cli",
  "$env:ProgramData\chocolatey\lib\tigervnc"
)
$ShimPaths = @(
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links\packer.exe",
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links\git.exe",
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links\kubectl.exe",
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links\vncviewer.exe"
)
$WingetCacheGlobs = @(
  "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Packer*",
  "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Git.Git*",
  "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Kubernetes.kubectl*",
  "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\TigerVNC.TigerVNC*"
)

$Markers = @("HashiCorp\Packer","Git\cmd","Git\bin","Kubernetes","chocolatey\bin","TigerVNC","SOC-9000-Install")

function Show-Probe([string]$label){
  Write-Host ""
  Write-Host "=== PROBE: $label ===" -ForegroundColor Yellow

  # Paths that exist
  $exists = $Targets + $WingetCacheGlobs + $ShimPaths | ForEach-Object {
    if ($_ -like "*`*") { $_ } else { $_ }
  } | Where-Object { Test-Path $_ }
  if ($exists) {
    Write-Host "Paths existing:" -ForegroundColor Yellow
    $exists | ForEach-Object { "  - $_" }
  } else { Write-Host "Paths existing: (none)" -ForegroundColor Yellow }

  # PATH values
  Write-Host "`nPATH (Machine):" -ForegroundColor Yellow
  [Environment]::GetEnvironmentVariable('Path','Machine')
  Write-Host "`nPATH (User):" -ForegroundColor Yellow
  [Environment]::GetEnvironmentVariable('Path','User')

  # Resolvable binaries
  Write-Host "`nBinaries resolvable:" -ForegroundColor Yellow
  Get-Command packer,git,kubectl,vncviewer -ErrorAction SilentlyContinue |
    Select-Object Name,Path | Format-Table -AutoSize

  # VMware adapters (summary)
  try {
    $vmad = Get-NetAdapter -Name "VMware Network Adapter VMnet*" -ErrorAction SilentlyContinue |
      Select-Object Name,Status,MacAddress,ifIndex
    if ($vmad) {
      Write-Host "`nVMware Adapters:" -ForegroundColor Yellow
      $vmad | Format-Table -AutoSize
      foreach($a in $vmad){ 
        $ips = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ips) { $ips | Select-Object @{n='Adapter';e={$a.Name}},IPAddress,PrefixLength | Format-Table -AutoSize }
      }
    } else { Write-Host "`nVMware Adapters: (none)" -ForegroundColor Yellow }
  } catch {}

  # WSL features
  try {
    $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux,VirtualMachinePlatform
    Write-Host "`nWindows Features (WSL/VMPlatform):" -ForegroundColor Yellow
    $f | Select-Object FeatureName,State | Format-Table -AutoSize
  } catch {}

  Write-Host "=== END PROBE: $label ===`n" -ForegroundColor Yellow
}

function Remove-IfExists([string]$Path){
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (Test-Path -LiteralPath $Path) {
    Info "Removing: $Path"
    try {
      Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Attributes = 'Normal' } catch {}
      }
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch { Warn2 "Failed to remove $Path :: $($_.Exception.Message)" }
  } else { Skip "Not found: $Path" }
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
    if ($rm.Count -gt 0){ $rm | ForEach-Object { Info "PATH[$scope] remove: $_" } }
    [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), $scope)
  }
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

function Hard-Cleanup([string[]]$extraTargets){
  foreach($t in $extraTargets){ Remove-IfExists $t }
  foreach($g in $WingetCacheGlobs){ Get-ChildItem $g -ErrorAction SilentlyContinue | ForEach-Object { Remove-IfExists $_.FullName } }
  foreach($s in $ShimPaths){ Remove-IfExists $s }
}

function Winget-Installed($id){
  try {
    $out = winget list --id $id --exact --disable-interactivity 2>$null
    return ($out -match $id)
  } catch { return $false }
}

function Try-Uninstall($wingetId, $chocoId, $leftovers) {
  Info "Attempting to uninstall $wingetId / $chocoId"
  $found = $false

  # winget path
  if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    if (Winget-Installed $wingetId) {
      Info "winget uninstall $wingetId"
      try {
        winget uninstall --id $wingetId --exact --silent --force --disable-interactivity
        $found = $true
      } catch { Warn2 "winget uninstall failed for $wingetId :: $($_.Exception.Message)" }
    }
  }

  # choco path
  if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
    try {
      $cl = choco list --local-only 2>$null | Select-String -SimpleMatch "^$chocoId"
      if ($cl) {
        Info "choco uninstall $chocoId"
        choco uninstall $chocoId -y --nocolor --skip-autouninstaller
        $found = $true
      }
    } catch { Warn2 "choco query failed for $chocoId :: $($_.Exception.Message)" }
  }

  if (-not $found) {
    Info "No registered package found for $wingetId/$chocoId → hard cleanup"
    Hard-Cleanup $leftovers
  }
}

function Restore-VMware-Nets {
  Info "Restoring VMware networks to defaults (best-effort)"
  # Preferred: use vmnetcfg.exe if present (Workstation Pro)
  $vmcfg = Join-Path ${env:ProgramFiles(x86)} "VMware\VMware Workstation\vmnetcfg.exe"
  if (Test-Path $vmcfg) {
    try {
      # No CLI switches; we still launch it headless attempt (will just open UI if interactive).
      # As a non-interactive fallback, we at least restart services and report adapter state.
      Info "vmnetcfg.exe found: $vmcfg (manual UI may be required for full reset)"
    } catch { Warn2 "vmnetcfg.exe invocation failed: $($_.Exception.Message)" }
  } else {
    Skip "vmnetcfg.exe not found; using service restart only"
  }

  # Restart NAT/DHCP services to apply existing config
  foreach($svc in "VMnetDHCP","VMware NAT Service"){
    try {
      Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
      Start-Service -Name $svc -ErrorAction SilentlyContinue
      Info "Service restarted: $svc"
    } catch { Warn2 "Service restart failed: $svc :: $($_.Exception.Message)" }
  }
}

# ========== RUN ==========
Info "=== Uninstalling SOC-9000 prerequisites ==="

Show-Probe "BEFORE"

# 1) Packer
Try-Uninstall "HashiCorp.Packer" "packer" @(
  "C:\Program Files\HashiCorp\Packer",
  "C:\Program Files (x86)\HashiCorp\Packer",
  "$env:LOCALAPPDATA\HashiCorp\Packer"
)

# 2) Git
Try-Uninstall "Git.Git" "git" @(
  "C:\Program Files\Git",
  "C:\Program Files\Git LFS",
  "$env:ProgramData\chocolatey\lib\git",
  "$env:ProgramData\chocolatey\bin\git.exe"
)

# 3) kubectl
Try-Uninstall "Kubernetes.kubectl" "kubernetes-cli" @(
  "C:\Program Files\Kubernetes",
  "C:\Program Files (x86)\Kubernetes",
  "$env:ProgramData\chocolatey\lib\kubernetes-cli",
  "$env:ProgramData\chocolatey\bin\kubectl.exe"
)

# 4) TigerVNC
Try-Uninstall "TigerVNC.TigerVNC" "tigervnc" @(
  "C:\Program Files\TigerVNC",
  "C:\Program Files (x86)\TigerVNC",
  "$env:ProgramData\chocolatey\lib\tigervnc",
  "$env:ProgramData\chocolatey\bin\vncviewer.exe"
)

# 5) SOC-9000 staging dirs
Hard-Cleanup @("E:\SOC-9000-Install","$env:USERPROFILE\Downloads\SOC-9000-Install","$env:TEMP\SOC-9000*")

# 6) PATH cleanup
Clean-Path $Markers

# 7) VMware networks restore (best effort)
Restore-VMware-Nets

# 8) Disable WSL features
Info "Disabling Windows features: WSL + VirtualMachinePlatform"
try {
  dism.exe /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux /norestart | Out-Null
  dism.exe /online /disable-feature /featurename:VirtualMachinePlatform /norestart | Out-Null
} catch { Warn2 "DISM feature disable failed :: $($_.Exception.Message)" }

Show-Probe "AFTER"

Info "SOC-9000 uninstall completed (reboot recommended)"
if ($LogPath) { Info "Log written: $LogPath" }
try { Stop-Transcript | Out-Null } catch {}
