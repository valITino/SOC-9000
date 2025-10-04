# End-to-end bring-up for SOC-9000 (restored full flow + hardened paths)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest

# Always operate from repo root
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RepoRoot

function Get-DotEnv {
  param([string]$Path = (Join-Path $RepoRoot '.env'))
  if(!(Test-Path $Path)){
    if (Test-Path (Join-Path $RepoRoot '.env.example')) {
      Copy-Item (Join-Path $RepoRoot '.env.example') $Path -Force
      throw "Created .env from .env.example. Review it, then re-run."
    } else {
      throw ".env not found at $RepoRoot"
    }
  }
  $map=@{}
  Get-Content $Path | Where-Object {$_ -and $_ -notmatch '^\s*#'} | ForEach-Object {
    if($_ -match '^([^=]+)=(.*)$'){ $map[$matches[1].Trim()] = $matches[2].Trim() }
  }
  return $map
}

function Run($p){
  $full = (Resolve-Path (Join-Path $RepoRoot $p)).Path
  Write-Host "`n== $p" -ForegroundColor Cyan
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $full
  if ($LASTEXITCODE -ne 0) { throw "Script $p exited with code $LASTEXITCODE" }
}

function RunIfExists($p,[switch]$Required){
  $full = Join-Path $RepoRoot $p
  if (Test-Path $full) { Run $p }
  elseif ($Required) { throw "Missing required script: $p" }
  else { Write-Warning "Skipping missing script: $p" }
}

function Assert-Tool {
  param([string]$Exe,[string]$Hint)
  try { Get-Command $Exe -ErrorAction Stop | Out-Null }
  catch { throw "$Exe not found. $Hint" }
}

function To-WslPath([string]$winPath){
  $winPath = (Resolve-Path $winPath).Path
  $drive = $winPath.Substring(0,1).ToLower()
  $rest  = $winPath.Substring(2).Replace('\','/')
  return "/mnt/$drive/$rest"
}

# 0) Env + preflight
$envMap = Get-DotEnv
foreach($k in 'ISO_DIR'){ if(-not $envMap[$k]){ throw ".env missing $k" } }

Assert-Tool 'packer'  'Install: winget install HashiCorp.Packer'
Assert-Tool 'kubectl' 'Install: winget install --id Kubernetes.kubectl'
try { wsl -l -v 2>$null | Out-Null } catch { throw 'WSL not available. Run: wsl --install -d Ubuntu' }

Write-Host "Preflight checks passed." -ForegroundColor Green

# 1) Host prep (folders, profile to INSTALL_ROOT\config\network)

Write-Host "`nPlanned actions:" -ForegroundColor Cyan
$check = @(
  '1) Build base images',
  '2) Wire VMX networks + static MACs',
  '3) Apply netplan on ContainerHost',
  '4) pfSense manual install',
  '5) pfSense config + k3s + MetalLB + Portainer',
  '6) TLS + platform apps',
  '7) Wazuh',
  '8) TheHive + Cortex',
  '9) Nessus',
  '10) Expose Wazuh + telemetry',
  '11) Hosts refresh + status'
)
$check | ForEach-Object { Write-Host "  $_" }

# 2) Build base images (container-host, windows victim)
RunIfExists "scripts/build-packer.ps1" -Required

# 3) Wire VMX networks + static MACs
RunIfExists "orchestration/wire-networks.ps1" -Required

# 4) Apply netplan on ContainerHost (static IPs)
RunIfExists "orchestration/apply-containerhost-netplan.ps1" -Required

Write-Host "`n== pfSense manual install reminder ==" -ForegroundColor Yellow
Write-Host "Create pfSense VM (5 NICs in order), install from ISO, set admin password, enable SSH."
Write-Host "Then press Enter to continue ..."
[void][System.Console]::ReadLine()

# 5) pfSense config + k3s + MetalLB + Portainer (Ansible from repo)
$inv = To-WslPath (Join-Path $RepoRoot 'ansible\inventory.ini')
$ply = To-WslPath (Join-Path $RepoRoot 'ansible\site.yml')
# Ensure ansible present in WSL
$ansibleOk = $false
try { wsl -e bash -lc "command -v ansible-playbook >/dev/null" | Out-Null; $ansibleOk = $true } catch {}
if (-not $ansibleOk) { throw "ansible-playbook not found in WSL. Run scripts\wsl-bootstrap.ps1 first." }
wsl -e bash -lc "ansible-playbook -i '$inv' '$ply'"

# 6) TLS (wildcard) + platform apps
RunIfExists "scripts/gen-ssl.ps1" -Required
RunIfExists "scripts/apply-k8s.ps1" -Required

# 7) Wazuh
RunIfExists "scripts/wazuh-vendor-and-deploy.ps1" -Required

# 8) TheHive + Cortex (RWX storage then apps)
RunIfExists "scripts/install-rwx-storage.ps1" -Required
RunIfExists "scripts/install-thehive-cortex.ps1" -Required
RunIfExists "scripts/storage-defaults-reset.ps1" -Required

# 9) Nessus (choose container or VM based on .env)
$envBlock = Get-Content (Join-Path $RepoRoot '.env') | ? {$_ -and $_ -notmatch '^\s*#'}
$mode = ($envBlock | ? { $_ -match '^NESSUS_MODE=' }) -replace '^NESSUS_MODE=',''
if (!$mode) { $mode = "docker-first" }
if ($mode -eq "docker-first") {
  RunIfExists "scripts/deploy-nessus-essentials.ps1" -Required
} else {
  RunIfExists "scripts/nessus-vm-build-and-config.ps1" -Required
}

# 10) Expose Wazuh for agents + telemetry bootstrap (pfSense syslog, agents, Atomic, CALDERA)
RunIfExists "scripts/expose-wazuh-manager.ps1" -Required
RunIfExists "scripts/telemetry-bootstrap.ps1" -Required

# 11) Final hosts refresh + status
RunIfExists "scripts/hosts-refresh.ps1" -Required
RunIfExists "scripts/lab-status.ps1" -Required

# Mark readiness for the top-level wrapper (respect INSTALL_ROOT from .env)
if (-not $envMap -or -not $envMap['INSTALL_ROOT']) {
  throw ".env missing INSTALL_ROOT (lab-up.ps1)"
}
$StateDir = Join-Path $envMap['INSTALL_ROOT'] 'state'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Set-Content -Path (Join-Path $StateDir 'lab-ready.txt') -Value (Get-Date).ToString('s')

Write-Host "`nAll done. Open README URLs." -ForegroundColor Green