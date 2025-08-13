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

# WSL / Ansible (best effort)
$wsl = (wsl -l -v 2>$null) -join "`n"
$ans = try { wsl -e bash -lc "ansible --version | head -n1" 2>$null } catch { "" }

# Output
$rows = @(
 @{Item="Folders"; Detail="$IsoDir, $ArtifactsDir, $TempDir"}
 @{Item="vmrun.exe"; Detail=($vmrun ?? "MISSING")}
 @{Item="Packer"; Detail=($packer ?? "MISSING")}
 @{Item="Disk E:"; Detail="$freeGB GB free (>= 300 GB rec.)"}
 @{Item="VMware nets"; Detail=($(if($missing){ "Missing: "+($missing -join ', ') } else { "OK: VMnet8,20,21,22,23" }))}
 @{Item="WSL"; Detail=($(if($wsl){$wsl.Trim()}else{"Install: wsl --install -d Ubuntu-22.04"}))}
 @{Item="Ansible (WSL)"; Detail=($(if($ans){$ans.Trim()}else{"In WSL: apt install python3-pip python3-venv openssh-client && pip install --user ansible==9.*"}))}
)
$rows | % { "{0,-16} {1}" -f $_.Item, $_.Detail }

Write-Host "`nNext steps:"
"1) Virtual Network Editor (Admin):
   - VMnet8  : NAT (DHCP ON)
   - VMnet20 : Host-only 172.22.10.0/24, DHCP OFF
   - VMnet21 : Host-only 172.22.20.0/24, DHCP OFF
   - VMnet22 : Host-only 172.22.30.0/24, DHCP OFF
   - VMnet23 : Host-only 172.22.40.0/24, DHCP OFF"
"2) Download to $IsoDir:
   - pfSense CE (AMD64)  -> $(Join-Path $IsoDir 'pfsense.iso')
   - Ubuntu 22.04 (AMD64)-> $(Join-Path $IsoDir 'ubuntu-22.04.iso')
   - Windows 11 Eval     -> $(Join-Path $IsoDir 'win11-eval.iso')
   - Nessus Essentials .deb (Ubuntu AMD64)"
"   (Tip: run scripts\download-isos.ps1 to fetch Ubuntu automatically and open vendor pages for the rest)"
"3) Ensure SSH key at %USERPROFILE%\.ssh\id_ed25519 (or create it)."
"4) (Optional) Copy SSH key into WSL: scripts\copy-ssh-key-to-wsl.ps1"
