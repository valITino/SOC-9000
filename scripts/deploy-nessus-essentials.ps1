# Deploy Nessus Essentials on k3s and add a hosts entry.
param(
  [string]$Ns = "soc",
  [string]$LbIp = "172.22.10.61",
  [string]$Host = "nessus.lab.local"
)
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$args) kubectl @args }

# Ensure namespace exists
K get ns $Ns 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { K create ns $Ns | Out-Null }

# Apply manifests
K apply -f k8s\apps\nessus\deployment.yaml
# Inject the LB IP annotation/value (in case you change it later)
$svc = (Get-Content "k8s\apps\nessus\service.yaml" -Raw) -replace '172\.22\.10\.61', $LbIp
$svc | K apply -f -

# Wait for external IP
Write-Host "Waiting for LoadBalancer IP..."
$ip = ""
for ($i=0; $i -lt 60; $i++) {
  $ip = K -n $Ns get svc nessus -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
  if ($ip) { break }
  Start-Sleep -Seconds 2
}
if (-not $ip) { $ip = $LbIp }

# Update hosts
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hosts
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN", "$ip $Host", "# SOC-9000 END")
Set-Content -Path $hosts -Value ($filtered + $block) -Force

Write-Host "`nOpen: https://$Host:8834"
Write-Host "Setup steps:"
Write-Host "  1) Choose 'Nessus Essentials', request/enter activation code."
Write-Host "  2) Create the admin account."
Write-Host "  3) Start a basic scan against the VICTIM segment (172.22.30.0/24)."
Write-Host "`nNote: Container is ephemeral—if the pod is recreated, you'll re-enter activation/admin."
