# Summarize VM + k8s service status and URLs
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$a) kubectl @a }

Write-Host "== Kubernetes Services (External IPs) ==" -ForegroundColor Cyan
try { K get svc -A | Out-String | Write-Host } catch { Write-Warning "kubectl not ready?" }

Write-Host "`n== URLs ==" -ForegroundColor Cyan
$urls = @(
  "https://portainer.lab.local:9443",
  "https://wazuh.lab.local",
  "https://thehive.lab.local",
  "https://cortex.lab.local",
  "https://caldera.lab.local",
  "https://dvwa.lab.local",
  "https://nessus.lab.local:8834"
)
$urls | % { "  $_" | Write-Host }

Write-Host "`n== Tip ==" -ForegroundColor Yellow
Write-Host "If a name doesn't resolve, run: pwsh -File scripts/hosts-refresh.ps1"
