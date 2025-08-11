# End-to-end bring-up for SOC-9000
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
function Run($p){ Write-Host "`n== $p" -ForegroundColor Cyan; & pwsh -NoProfile -ExecutionPolicy Bypass -File $p }

# 0) Env + preflight
if (!(Test-Path ".env")) { Copy-Item .env.example .env -Force; throw "Edit .env then re-run." }
# Minimal ISO checks (skip pfSense since it's manual install step)
$isoU = (Get-Content .env) -match '^ISO_UBUNTU=' | % { $_.Split('=')[1].Trim() }
$isoW = (Get-Content .env) -match '^ISO_WINDOWS=' | % { $_.Split('=')[1].Trim() }
$isoDir = (Get-Content .env) -match '^ISO_DIR=' | % { $_.Split('=')[1].Trim() }
foreach($f in @($isoU,$isoW)){ if (!(Test-Path (Join-Path $isoDir $f))) { Write-Warning "Missing ISO: $f in $isoDir" } }

# 1) Host prep (folders, hints)
Run "scripts/host-prepare.ps1"

# 2) Build base images (container-host, windows victim)
Run "scripts/build-packer.ps1"

# 3) Wire VMX networks + static MACs
Run "orchestration/wire-networks.ps1"

# 4) Apply netplan on ContainerHost (static IPs)
Run "orchestration/apply-containerhost-netplan.ps1"

Write-Host "`n== pfSense manual install reminder ==" -ForegroundColor Yellow
Write-Host "Create pfSense VM (5 NICs in order), install from ISO, set admin password, enable SSH."
Write-Host "Then press Enter to continue ..."
[void][System.Console]::ReadLine()

# 5) pfSense config + k3s + MetalLB + Portainer
wsl bash -lc "ansible-playbook -i '/mnt/e/SOC-9000/SOC-9000/ansible/inventory.ini' '/mnt/e/SOC-9000/SOC-9000/ansible/site.yml'"

# 6) TLS (wildcard) + platform apps
Run "scripts/gen-ssl.ps1"
Run "scripts/apply-k8s.ps1"

# 7) Wazuh
Run "scripts/wazuh-vendor-and-deploy.ps1"

# 8) TheHive + Cortex (RWX storage then apps)
Run "scripts/install-rwx-storage.ps1"
Run "scripts/install-thehive-cortex.ps1"
Run "scripts/storage-defaults-reset.ps1"

# 9) Nessus (choose container or VM based on .env)
$envBlock = Get-Content .env | ? {$_ -and $_ -notmatch '^\s*#'}
$mode = ($envBlock | ? { $_ -match '^NESSUS_MODE=' }) -replace '^NESSUS_MODE=',''
if (!$mode) { $mode = "docker-first" }
if ($mode -eq "docker-first") {
  Run "scripts/deploy-nessus-essentials.ps1"
} else {
  Run "scripts/nessus-vm-build-and-config.ps1"
}

# 10) Expose Wazuh for agents + telemetry bootstrap (pfSense syslog, agents, Atomic, CALDERA)
Run "scripts/expose-wazuh-manager.ps1"
Run "scripts/telemetry-bootstrap.ps1"

# 11) Final hosts refresh + status
Run "scripts/hosts-refresh.ps1"
Run "scripts/lab-status.ps1"

Write-Host "`nAll done. Open README URLs." -ForegroundColor Green
