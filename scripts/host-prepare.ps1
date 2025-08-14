# SOC-9000 - host-prepare.ps1
[CmdletBinding()] param(
  [string]$LabRoot="E:\SOC-9000",
  [string]$IsoDir ="E:\SOC-9000\isos",
  [string]$ArtifactsDir="E:\SOC-9000\artifacts",
  [string]$TempDir="E:\SOC-9000\temp"
)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
function New-Dir($p){ if(!(Test-Path $p)){New-Item -Type Directory -Path $p -Force|Out-Null}}
Write-Host "== SOC-9000 :: Chunk 0 host preparation =="

# Folders
$null = ($LabRoot,$IsoDir,$ArtifactsDir,$TempDir | % { New-Dir $_ })

# Find vmrun / packer
function FindExe($name,$cands){ foreach($c in $cands){if(Test-Path $c){return $c}} (Get-Command $name -ErrorAction SilentlyContinue)?.Source }
$vmrun = FindExe "vmrun.exe" @(
 "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
 "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
)
$packer = FindExe "packer.exe" @("C:\Program Files\HashiCorp\Packer\packer.exe")

# Disk space
$drive = Get-PSDrive -Name E -ErrorAction SilentlyContinue
$freeGB = if($drive){ [math]::Round($drive.Free/1GB,2) } else { 0 }

# VMware network configuration
& (Join-Path $PSScriptRoot 'configure-vmnet.ps1')
$missing = @()
# WSL / Ansible (best effort)
$wsl = (wsl -l -v 2>$null) -join "`n"
if (-not $wsl) {
  try {
    Write-Host "Installing WSL Ubuntu-22.04..." -ForegroundColor Cyan
    wsl --install -d Ubuntu-22.04 2>$null | Out-Null
    $wsl = (wsl -l -v 2>$null) -join "`n"
  } catch {}
}
$ans = try { wsl -e bash -lc "ansible --version | head -n1" 2>$null } catch { "" }

# SSH key
$sshDir = Join-Path $env:USERPROFILE '.ssh'
$sshKey = Join-Path $sshDir 'id_ed25519'
if (-not (Test-Path $sshKey)) {
  try {
    New-Item -Type Directory -Path $sshDir -Force | Out-Null
    Write-Host "Generating SSH key at $sshKey" -ForegroundColor Cyan
    ssh-keygen -t ed25519 -N "" -f $sshKey | Out-Null
  } catch {
    Write-Warning "Failed to generate SSH key: $($_.Exception.Message)"
  }
} else {
  Write-Host "SSH key already present at $sshKey" -ForegroundColor DarkGray
}

# Output
$rows = @(
 @{Item="Folders"; Detail="$IsoDir, $ArtifactsDir, $TempDir"}
 @{Item="vmrun.exe"; Detail=($vmrun ?? "MISSING")}
 @{Item="Packer"; Detail=($packer ?? "MISSING")}
 @{Item="Disk E:"; Detail="$freeGB GB free (>= 300 GB rec.)"}
 @{Item="VMware nets"; Detail=($(if($missing){ "Missing: "+($missing -join ', ') } else { "OK: VMnet8,20,21,22,23" }))}
 @{Item="WSL"; Detail=($(if($wsl){$wsl.Trim()}else{"Install: wsl --install -d Ubuntu-22.04"}))}
 @{Item="Ansible (WSL)"; Detail=($(if($ans){$ans.Trim()}else{"In WSL: apt install python3-pip python3-venv openssh-client && pip install --user ansible==9.*"}))}
 @{Item="SSH key"; Detail=($(if(Test-Path $sshKey){$sshKey}else{"MISSING"}))}
)
$rows | % { "{0,-16} {1}" -f $_.Item, $_.Detail }

Write-Host "`nNext steps:"
$step = 1
if ($missing) {
  Write-Host "${step}) Virtual Network Editor (Admin):"
  Write-Host "   - VMnet8  : NAT (DHCP ON)"
  Write-Host "   - VMnet20 : Host-only 172.22.10.0/24, DHCP OFF"
  Write-Host "   - VMnet21 : Host-only 172.22.20.0/24, DHCP OFF"
  Write-Host "   - VMnet22 : Host-only 172.22.30.0/24, DHCP OFF"
  Write-Host "   - VMnet23 : Host-only 172.22.40.0/24, DHCP OFF"
  $step++
}
Write-Host "${step}) Place downloads in ${IsoDir}:"
Write-Host "   - pfSense CE ISO (Netgate account required)"
Write-Host "   - Ubuntu 22.04 (AMD64) -> $(Join-Path $IsoDir 'ubuntu-22.04.iso')"
Write-Host "   - Windows 11 ISO (any filename)"
Write-Host "   - Nessus Essentials .deb (Ubuntu AMD64)"
Write-Host "   (Tip: run scripts\download-isos.ps1 to fetch Ubuntu automatically and open vendor pages for the rest)"
$step++
Write-Host "${step}) (Optional) Copy SSH key into WSL: scripts\copy-ssh-key-to-wsl.ps1"
