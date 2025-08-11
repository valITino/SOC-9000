# Adds lab hostnames to Windows hosts file.
param([string]$TraefikIP = "172.22.10.60")
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$args) kubectl @args }

# Try to get Portainer LB IP (may take a moment after Chunk 3)
$portainerIP = ""
try { $portainerIP = K -n portainer get svc portainer -o jsonpath='{.status.loadBalancer.ingress[0].ip}' } catch { }

$entries = @(
  "$TraefikIP caldera.lab.local",
  "$TraefikIP dvwa.lab.local"
)
if ($portainerIP) { $entries += "$portainerIP portainer.lab.local" }

$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hosts -ErrorAction Stop

# Remove old SOC-9000 block if present
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN") + $entries + @("# SOC-9000 END")

Set-Content -Path $hosts -Value ($filtered + $block) -Force
Write-Host "Hosts file updated:"
$block | ForEach-Object { "  $_" | Write-Host }
