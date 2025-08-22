<#
  install-prereqs.ps1  (SOC-9000)
  - PowerShell 5.1 kompatibel (kein modernes '??' etc.)
  - Installiert/prüft: PowerShell 7, HashiCorp Packer, kubectl, Git, TigerVNC (viewer)
  - Prüft: VMware Workstation Pro (>= 17), E:\ Laufwerk
  - Aktiviert Windows-Features: WSL, VirtualMachinePlatform (ohne Neustart)
  - Vermeidet Windows Updates; nur Tool-/Feature-Prüfungen + winget-Installationen
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------- UX helpers --------------------
function Write-Info([string]$Msg){ Write-Host "[>] $Msg" -ForegroundColor Cyan }
function Write-Ok  ([string]$Msg){ Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg){ Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err ([string]$Msg){ Write-Host "[X] $Msg" -ForegroundColor Red }

# -------------------- PATH helper --------------------
function Add-PathOnce {
  param([Parameter(Mandatory=$true)][string]$Dir)
  try {
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $dirResolved = (Resolve-Path -LiteralPath $Dir).Path
    $parts = ($env:PATH -split ';') | Where-Object { $_ }
    if ($parts -notcontains $dirResolved) {
      $env:PATH = ($parts + $dirResolved) -join ';'
    }
  } catch {}
}

# -------------------- WinGet helpers --------------------
function Ensure-WinGet {
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if ($wg) { return $true }
  Write-Err "WinGet nicht gefunden. Bitte 'App Installer' aus dem Microsoft Store installieren und anschließend dieses Skript erneut starten."
  return $false
}

function Winget-Source-Update {
  try {
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wg) { return }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "winget"
    $psi.Arguments = "source update"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $null = $p.WaitForExit(90 * 1000)
  } catch { }
}

function Winget-Install {
  param(
    [Parameter(Mandatory=$true)][string]$Id
  )
  if (-not (Ensure-WinGet)) { throw "WinGet fehlt" }
  Winget-Source-Update
  $args = @(
    "install","-e","--id",$Id,"--source","winget",
    "--accept-source-agreements","--accept-package-agreements"
  )
  $p = Start-Process -FilePath "winget" -ArgumentList $args -PassThru -Wait -NoNewWindow
  return $p.ExitCode
}

# -------------------- Pending reboot check --------------------
function Test-PendingReboot {
  try {
    $keys = @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
      'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )
    foreach ($k in $keys) {
      if (Test-Path $k) {
        if ($k -like '*Session Manager') {
          $val = (Get-ItemProperty -Path $k -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
          if ($val) { return $true }
        } else {
          return $true
        }
      }
    }
  } catch { }
  return $false
}

# -------------------- Packer locate helpers --------------------
function Find-PackerExe {
  # 1) PATH
  $cmd = Get-Command packer -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Path) { return $cmd.Path }

  # 2) Typische Orte (WinGet-Link / HashiCorp / Chocolatey)
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\packer.exe'),
    (Join-Path $env:LOCALAPPDATA 'HashiCorp\Packer\packer.exe'),
    (Join-Path $env:ProgramFiles    'HashiCorp\Packer\packer.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'HashiCorp\Packer\packer.exe'),
    (Join-Path $env:ChocolateyInstall 'bin\packer.exe'),
    'C:\ProgramData\chocolatey\bin\packer.exe'
  ) | Where-Object { $_ }

  foreach ($p in $candidates) {
    try {
      if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
    } catch {}
  }

  # 3) Schnelle Heuristik-Suche in HashiCorp/WinGet-Bäumen
  $roots = @(
    (Join-Path $env:LOCALAPPDATA 'HashiCorp'),
    (Join-Path $env:ProgramFiles 'HashiCorp'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($r in $roots) {
    try {
      $found = Get-ChildItem -Path $r -Filter 'packer.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1 -ExpandProperty FullName
      if ($found) { return $found }
    } catch {}
  }

  return $null
}

# -------------------- Ensure: PowerShell 7 --------------------
function Ensure-Pwsh {
  Write-Info "Checking PowerShell 7..."
  $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Path) {
    try {
      $v = & $cmd.Path -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
      Write-Ok ("PowerShell 7 vorhanden: {0}" -f $v)
    } catch {
      Write-Ok ("PowerShell 7 vorhanden (Version unbekannt)")
    }
    return
  }
  Write-Info "PowerShell 7 nicht gefunden – Installation via winget..."
  $rc = Winget-Install -Id "Microsoft.PowerShell"
  if ($rc -ne 0) { Write-Warn "winget ExitCode=$rc (pwsh). Prüfe Pfad/Link..." }
  # WinGet Links-Ordner zur Session-PATH hinzufügen
  Add-PathOnce (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
  $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($cmd) { Write-Ok "PowerShell 7 installiert."; return }
  Write-Err "PowerShell 7 konnte nicht gefunden werden, obwohl Installation versucht wurde."
}

# -------------------- Ensure: Packer --------------------
function Ensure-Packer {
  Write-Info "Checking HashiCorp Packer..."
  $exe = Find-PackerExe
  if ($exe) {
    Add-PathOnce (Split-Path $exe -Parent)
    $ver = ""
    try { $ver = (& $exe -v 2>$null) } catch {}
    if (-not $ver) { $ver = "(Version unbekannt)" }
    Write-Ok ("Packer vorhanden: {0}" -f $ver)
    return
  }

  Write-Info "Packer nicht gefunden – Installation wird versucht..."
  $rc = Winget-Install -Id "HashiCorp.Packer"
  if ($rc -ne 0) { Write-Warn "winget ExitCode=$rc (Packer). Prüfe Pfad/Link..." }

  $exe = Find-PackerExe
  if ($exe) {
    Add-PathOnce (Split-Path $exe -Parent)
    $v = ""
    try { $v = (& $exe -v 2>$null) } catch {}
    Write-Ok ("Packer installiert: {0}" -f ($v -ne "" ? $v : "(Version unbekannt)"))
  } else {
    Write-Err "Packer weiterhin nicht auffindbar nach Installation."
    throw "packer not found after install"
  }
}

# -------------------- Ensure: kubectl --------------------
function Ensure-Kubectl {
  Write-Info "Checking kubectl..."
  $cmd = Get-Command kubectl -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Path) {
    $ver = ""
    try { $ver = (& $cmd.Path version --client --short 2>$null) } catch {}
    Write-Ok ("kubectl vorhanden: {0}" -f ($ver -ne "" ? $ver : "(Version unbekannt)"))
    return
  }
  Write-Info "kubectl nicht gefunden – Installation via winget..."
  $rc = Winget-Install -Id "Kubernetes.kubectl"
  if ($rc -ne 0) { Write-Warn "winget ExitCode=$rc (kubectl). Prüfe Pfad/Link..." }
  Add-PathOnce (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
  $cmd = Get-Command kubectl -ErrorAction SilentlyContinue
  if ($cmd) { Write-Ok "kubectl installiert."; return }
  Write-Err "kubectl weiterhin nicht auffindbar nach Installation."
}

# -------------------- Ensure: Git --------------------
function Ensure-Git {
  Write-Info "Checking Git..."
  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Path) {
    $ver = ""
    try { $ver = (& $cmd.Path --version 2>$null) } catch {}
    Write-Ok ("Git vorhanden: {0}" -f ($ver -ne "" ? $ver : "(Version unbekannt)"))
    return
  }
  Write-Info "Git nicht gefunden – Installation via winget..."
  $rc = Winget-Install -Id "Git.Git"
  if ($rc -ne 0) { Write-Warn "winget ExitCode=$rc (Git). Prüfe Pfad/Link..." }
  Add-PathOnce (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd) { Write-Ok "Git installiert."; return }
  Write-Err "Git weiterhin nicht auffindbar nach Installation."
}

# -------------------- Ensure: TigerVNC Viewer --------------------
function Ensure-TigerVNC {
  Write-Info "Checking TigerVNC (viewer)..."
  $cmd = Get-Command vncviewer -ErrorAction SilentlyContinue
  if (-not $cmd) {
    # Try common install path
    $default = 'C:\Program Files\TigerVNC\vncviewer.exe'
    if (Test-Path $default) { $cmd = @{ Path = $default } }
  }
  if ($cmd -and $cmd.Path) {
    Write-Ok ("TigerVNC vorhanden: {0}" -f $cmd.Path)
    return
  }
  Write-Info "TigerVNC nicht gefunden – Installation via winget..."
  $rc = Winget-Install -Id "TigerVNC.TigerVNC"
  if ($rc -ne 0) { Write-Warn "winget ExitCode=$rc (TigerVNC). Prüfe Pfad/Link..." }
  Add-PathOnce (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
  $cmd = Get-Command vncviewer -ErrorAction SilentlyContinue
  if (-not $cmd -and (Test-Path 'C:\Program Files\TigerVNC\vncviewer.exe')) {
    $cmd = @{ Path = 'C:\Program Files\TigerVNC\vncviewer.exe' }
  }
  if ($cmd) { Write-Ok "TigerVNC installiert."; return }
  Write-Err "TigerVNC weiterhin nicht auffindbar nach Installation."
}

# -------------------- Check: VMware Workstation (>=17) --------------------
function Check-VMware {
  Write-Info "Checking VMware Workstation Pro (>= 17)..."
  $ver = $null
  try {
    $paths = @(
      'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation',
      'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation'
    )
    foreach ($rk in $paths) {
      if (Test-Path $rk) {
        $p = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
        if ($p -and $p.DisplayVersion) { $ver = $p.DisplayVersion; break }
        if ($p -and $p.Version)        { $ver = $p.Version;        break }
      }
    }
  } catch {}

  if ($ver) {
    Write-Ok ("VMware Workstation vorhanden: Version {0}" -f $ver)
    # grober Versionscheck: 17.x oder größer
    $maj = $null
    try { $maj = [int]($ver -split '\.' | Select-Object -First 1) } catch {}
    if ($maj -and $maj -lt 17) {
      Write-Warn "VMware Version < 17 erkannt. Bitte auf >= 17 aktualisieren."
    }
  } else {
    Write-Warn "VMware Workstation nicht gefunden. (Nicht automatisch installiert; bitte separat installieren – Version >= 17 empfohlen.)"
  }
}

# -------------------- Ensure: WSL & VirtualMachinePlatform --------------------
function Ensure-WSL-VMP {
  Write-Info "Checking WSL and VirtualMachinePlatform..."
  $changed = $false
  try {
    $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    if (-not $wsl -or $wsl.State -ne 'Enabled') {
      Write-Info "Aktiviere Microsoft-Windows-Subsystem-Linux..."
      Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction SilentlyContinue | Out-Null
      $changed = $true
    }
  } catch {}

  try {
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
    if (-not $vmp -or $vmp.State -ne 'Enabled') {
      Write-Info "Aktiviere VirtualMachinePlatform..."
      Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction SilentlyContinue | Out-Null
      $changed = $true
    }
  } catch {}

  if ($changed) {
    Write-Warn "WSL/VMP wurden (teilweise) aktiviert. Ein Neustart kann erforderlich sein."
  } else {
    Write-Ok "WSL und VirtualMachinePlatform sind aktiviert."
  }
}

# -------------------- Check: E:\ drive --------------------
function Check-EDrive {
  param([int]$MinFreeGB = 50)
  Write-Info "Checking E:\ Laufwerk..."
  if (-not (Test-Path 'E:\')) {
    Write-Warn "E:\ nicht gefunden. Falls ISOs/Logs dort erwartet werden, bitte Laufwerk bereitstellen."
    return
  }
  try {
    $drive = Get-PSDrive -Name 'E' -ErrorAction SilentlyContinue
    if ($drive) {
      $freeGB = [math]::Round($drive.Free/1GB,0)
      Write-Ok ("E:\ vorhanden ({0} GB frei)" -f $freeGB)
      if ($freeGB -lt $MinFreeGB) {
        Write-Warn ("Wenig freier Speicher auf E:\ (nur {0} GB, empfohlen >= {1} GB)" -f $freeGB,$MinFreeGB)
      }
    } else {
      Write-Ok "E:\ vorhanden."
    }
  } catch {
    Write-Warn "E:\ Prüfung konnte nicht abgeschlossen werden: $($_.Exception.Message)"
  }
}

# -------------------- MAIN --------------------
try {
  Write-Host ""
  Write-Host "================= Prerequisites (SOC-9000) =================" -ForegroundColor Cyan

  # PATH fix for winget links (helps immediate availability)
  Add-PathOnce (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')

  Ensure-Pwsh
  Ensure-Packer
  Ensure-Kubectl
  Ensure-Git
  Ensure-TigerVNC
  Check-VMware
  Ensure-WSL-VMP
  Check-EDrive -MinFreeGB 50

  if (Test-PendingReboot) {
    Write-Warn "Ein Neustart ist empfohlen/erforderlich (PendingReboot erkannt)."
  } else {
    Write-Ok "Keine ausstehenden Neustarts erkannt."
  }

  Write-Ok "Prereqs abgeschlossen."
  exit 0
}
catch {
  Write-Err $_.Exception.Message
  exit 1
}
