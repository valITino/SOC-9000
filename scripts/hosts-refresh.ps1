# Rebuild a single SOC-9000 hosts block based on current cluster state
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
function K { kubectl $args }

$entries = @()
# Traefik (k3s default namespace)
$ns = "kube-system"
try { K -n $ns get svc traefik | Out-Null } catch { $ns = "traefik" }
$traefikIP = K -n $ns get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
if (!$traefikIP) { $traefikIP = "172.22.10.60" }
$entries += @(
  "$traefikIP wazuh.lab.local",
  "$traefikIP thehive.lab.local",
  "$traefikIP cortex.lab.local",
  "$traefikIP caldera.lab.local",
  "$traefikIP dvwa.lab.local"
)

# Portainer
$portIP = K -n portainer get svc portainer -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
if ($portIP) { $entries += "$portIP portainer.lab.local" }

# Nessus container
$nessusSVCIP = K -n soc get svc nessus -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
if ($nessusSVCIP) { $entries += "$nessusSVCIP nessus.lab.local" }

# Nessus VM (fallback)
$envPath = ".env"
if (Test-Path $envPath) {
  (Get-Content $envPath | ? {$_ -and $_ -notmatch '^\s*#'}) | % {
    if ($_ -match '^NESSUS_VM_IP=(.*)$'){ $entries += "$( $matches[1] ) nessus.lab.local" }
  }
}

# Write hosts block
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hosts
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN") + ($entries | Sort-Object -Unique) + @("# SOC-9000 END")
Set-Content -Path $hosts -Value ($filtered + $block) -Force
Write-Host "Hosts updated:"
$block | % { "  $_" | Write-Host }
