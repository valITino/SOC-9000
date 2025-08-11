<##
Soft reset: delete app namespaces and PVCs, then re-apply core apps.
Hard reset (-Hard): also wipes PV data on ContainerHost (local-path & NFS).
#>
param([switch]$Hard = $false)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$a) kubectl @a }

$ns = @("soc","victim","red","portainer")
Write-Host "Deleting namespaces (this may take a minute)..." -ForegroundColor Yellow
foreach($n in $ns){ try { K delete ns $n --ignore-not-found --wait=true } catch{} }

# Recreate namespaces (empty)
K apply -f k8s\namespaces.yaml

if ($Hard) {
  Write-Host "Wiping PV data on ContainerHost (HARD)..." -ForegroundColor Red
  # SSH via WSL to ContainerHost and wipe storage paths
  # Load .env for CH_IP_MGMT
  if (Test-Path ".env") {
    (Get-Content ".env" | ? {$_ -and $_ -notmatch '^\s*#'}) | % {
      if ($_ -match '^\s*([^=]+)=(.*)$'){ $env:$($matches[1].Trim())=$matches[2].Trim() }
    }
  }
  $host = $env:CH_IP_MGMT; if(-not $host){ $host="172.22.10.10" }
  wsl bash -lc "ssh -o StrictHostKeyChecking=no labadmin@$host 'sudo rm -rf /var/lib/rancher/k3s/storage/* /srv/nfs/* 2>/dev/null || true'"
}

Write-Host "Re-applying platform & apps..."
pwsh -File scripts\apply-k8s.ps1
pwsh -File scripts\wazuh-vendor-and-deploy.ps1
pwsh -File scripts\install-rwx-storage.ps1
pwsh -File scripts\install-thehive-cortex.ps1
pwsh -File scripts\storage-defaults-reset.ps1

# Nessus (respect your mode)
$envBlock = Get-Content .env | ? {$_ -and $_ -notmatch '^\s*#'}
$mode = ($envBlock | ? { $_ -match '^NESSUS_MODE=' }) -replace '^NESSUS_MODE=',''
if (!$mode) { $mode = "docker-first" }
if ($mode -eq "docker-first") {
  pwsh -File scripts\deploy-nessus-essentials.ps1
} else {
  pwsh -File scripts\nessus-vm-build-and-config.ps1
}

pwsh -File scripts\expose-wazuh-manager.ps1
pwsh -File scripts\telemetry-bootstrap.ps1
pwsh -File scripts\hosts-refresh.ps1

Write-Host "Reset complete."

