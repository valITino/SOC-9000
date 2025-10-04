# Deploy Nessus Essentials on k3s and add a hosts entry.
param(
  [string]$Ns      = "soc",
  [string]$LbIp,
  [string]$HostName = "nessus.lab.local"
)
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest

if (-not $IsWindows) {
  throw 'deploy-nessus-essentials.ps1 can only run on Windows.'
}

function K { kubectl $args }

function Get-DotEnv {
  param([string]$Path = '.env')
  $map=@{}
  if(Test-Path $Path){
    Get-Content $Path | Where-Object {$_ -and $_ -notmatch '^\s*#'} | ForEach-Object {
      if($_ -match '^([^=]+)=(.*)$'){ $map[$matches[1].Trim()]=$matches[2].Trim() }
    }
  }
  return $map
}
$envMap = Get-DotEnv '.env'
if(-not $LbIp){ $LbIp = $envMap.NESSUS_LB_IP; if(-not $LbIp){ $LbIp = '172.22.10.61' } }

# Ensure namespace exists
K get ns $Ns 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { K create ns $Ns | Out-Null }

# Apply manifests
K apply -f k8s\apps\nessus\deployment.yaml
# Inject the LB IP annotation/value (in case you change it later)
$svc = (Get-Content "k8s\apps\nessus\service.yaml" -Raw) -replace '172\.22\.10\.61', $LbIp
$svc | K apply -f -

# Wait for external IP
  Write-Output "Waiting for LoadBalancer IP..."
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
$block = @("# SOC-9000 BEGIN", "$ip $HostName", "# SOC-9000 END")
Set-Content -Path $hosts -Value ($filtered + $block) -Force

Write-Output "`nOpen: https://$HostName:8834"
Write-Output "Setup steps:"
Write-Output "  1) Choose 'Nessus Essentials', request/enter activation code."
Write-Output "  2) Create the admin account."
Write-Output "  3) Start a basic scan against the VICTIM segment (172.22.30.0/24)."
Write-Output "`nNote: Container is ephemeral—if the pod is recreated, you'll re-enter activation/admin."
