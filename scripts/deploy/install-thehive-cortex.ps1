<##
Installs TheHive and Cortex (Helm), creates Ingresses, and updates hosts.
Requires: RWX StorageClass available (run scripts\install-rwx-storage.ps1 first).
##>
param(
  [string]$Ns = "soc",
  [string]$TheHiveRel = "thehive",
  [string]$CortexRel = "cortex",
  [string]$TraefikIP = "172.22.10.60"
)
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$args) kubectl @args }

# Try both known chart URLs for resilience
$added = $false
try { helm repo add strangebee https://strangebee.github.io/helm-charts | Out-Null; $added = $true } catch {}
if (-not $added) { try { helm repo add strangebee https://strangebeecorp.github.io/helm-charts | Out-Null; $added = $true } catch {} }
if (-not $added) { throw "Unable to add StrangeBee Helm repo." }
helm repo update | Out-Null

kubectl get ns $Ns 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { kubectl create ns $Ns | Out-Null }

# TheHive (chart includes Cassandra, ES, MinIO)
helm upgrade --install $TheHiveRel strangebee/thehive `
  --namespace $Ns `
  --set fullnameOverride=thehive

# Cortex (chart includes its own ES 7.x; needs RWX PVC)
helm upgrade --install $CortexRel strangebee/cortex `
  --namespace $Ns `
  --set fullnameOverride=cortex

Start-Sleep -Seconds 5

# Fallback: find service names by label if they differ
$thehiveSvc = (K -n $Ns get svc -l "app.kubernetes.io/instance=$TheHiveRel" -o jsonpath="{.items[0].metadata.name}" 2>$null)
if (-not $thehiveSvc) { $thehiveSvc = "thehive" }
$cortexSvc  = (K -n $Ns get svc -l "app.kubernetes.io/instance=$CortexRel" -o jsonpath="{.items[0].metadata.name}" 2>$null)
if (-not $cortexSvc) { $cortexSvc = "cortex" }

# Apply ingresses (patch service names if needed)
$thIngress = (Get-Content "k8s\apps\thehive\ingress.yaml" -Raw) -replace "name: thehive", "name: $thehiveSvc"
$cxIngress = (Get-Content "k8s\apps\cortex\ingress.yaml" -Raw) -replace "name: cortex", "name: $cortexSvc"
$thIngress | K apply -f -
$cxIngress | K apply -f -

# Hosts entries
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hostsFile
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN",
           "$TraefikIP thehive.lab.local",
           "$TraefikIP cortex.lab.local",
           "# SOC-9000 END")
Set-Content -Path $hostsFile -Value ($filtered + $block) -Force

Write-Host "`nDeployed TheHive + Cortex."
Write-Host "Watch pods:"
Write-Host "  kubectl get pods -n $Ns -w"
Write-Host "Open: https://thehive.lab.local , https://cortex.lab.local"
Write-Host "(When both are running, add Cortex in TheHive under Admin > Cortex.)"
