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

# VMware networks required
$need = "VMnet8","VMnet20","VMnet21","VMnet22","VMnet23"
$have = Get-NetAdapter -Physical:$false -ErrorAction SilentlyContinue | % Name
$missing = $need | ? { $_ -notin $have }

# Attempt automatic network creation if VMware's network utilities are available
$vmnetcfgcli = FindExe "vmnetcfgcli.exe" @(
  "C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfgcli.exe",
  "C:\Program Files\VMware\VMware Workstation\vmnetcfgcli.exe",
  "C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfg.exe",
  "C:\Program Files\VMware\VMware Workstation\vmnetcfg.exe"
)
$vnetlib = FindExe "vnetlib.exe" @(
  "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib.exe",
  "C:\Program Files\VMware\VMware Workstation\vnetlib.exe"
)
$editor = FindExe "vmnetcfg.exe" @(
  "C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfg.exe",
  "C:\Program Files\VMware\VMware Workstation\vmnetcfg.exe"
)

if ($missing) {
  $nets = @(
    @{Name='VMnet8';  Type='nat';      Subnet='192.168.37.0'; Dhcp=$true},
    @{Name='VMnet20'; Type='hostonly'; Subnet='172.22.10.0';  Dhcp=$false},
    @{Name='VMnet21'; Type='hostonly'; Subnet='172.22.20.0';  Dhcp=$false},
    @{Name='VMnet22'; Type='hostonly'; Subnet='172.22.30.0';  Dhcp=$false},
    @{Name='VMnet23'; Type='hostonly'; Subnet='172.22.40.0';  Dhcp=$false}
  )
  if ($vnetlib) {
    foreach ($n in $nets) {
      if ($missing -contains $n.Name) {
        try {
          & $vnetlib -- addNetwork $n.Name 2>$null | Out-Null
          & $vnetlib -- setSubnet $n.Name $n.Subnet 255.255.255.0 2>$null | Out-Null
          & $vnetlib -- setDhcp $n.Name ($n.Dhcp ? 'on' : 'off') 2>$null | Out-Null
          & $vnetlib -- setNat $n.Name ($n.Type -eq 'nat' ? 'on' : 'off') 2>$null | Out-Null
          Write-Host "Configured $($n.Name) via vnetlib" -ForegroundColor Green
        } catch {
          Write-Warning "Failed to configure $($n.Name): $($_.Exception.Message)"
        }
      }
    }
  } elseif ($vmnetcfgcli) {
    foreach ($n in $nets) {
      if ($missing -contains $n.Name) {
        try {
          & $vmnetcfgcli --add $n.Name --type $n.Type --subnet $n.Subnet --netmask 255.255.255.0 --dhcp ($n.Dhcp ? 'yes' : 'no') 2>$null | Out-Null
          Write-Host "Configured $($n.Name) via vmnetcfgcli" -ForegroundColor Green
        } catch {
          Write-Warning "Failed to configure $($n.Name): $($_.Exception.Message)"
        }
      }
    }
  }
  $have = Get-NetAdapter -Physical:$false -ErrorAction SilentlyContinue | % Name
  $missing = $need | ? { $_ -notin $have }
}

if ($missing) {
  if ($editor) { Start-Process $editor -Verb runAs }
  Write-Host "Manual VMware network configuration required:" -ForegroundColor Yellow
  Write-Host "   - VMnet8  : NAT (DHCP ON)"
  Write-Host "   - VMnet20 : Host-only 172.22.10.0/24, DHCP OFF"
  Write-Host "   - VMnet21 : Host-only 172.22.20.0/24, DHCP OFF"
  Write-Host "   - VMnet22 : Host-only 172.22.30.0/24, DHCP OFF"
  Write-Host "   - VMnet23 : Host-only 172.22.40.0/24, DHCP OFF"
  do {
    $choice = Read-Host "[D]one, let's go / [N]ot working yet, restart later"
    if ($choice -match '^[Nn]') { Write-Host "Exiting. Re-run after configuring networks."; exit 1 }
    $have = Get-NetAdapter -Physical:$false -ErrorAction SilentlyContinue | % Name
    $missing = $need | ? { $_ -notin $have }
    if ($missing) { Write-Warning "Still missing: $($missing -join ', ')" }
  } while ($missing)
}

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
