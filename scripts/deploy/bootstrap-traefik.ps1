# Sets Traefik to LoadBalancer with a fixed IP, installs wildcard TLS as default
param(
  [string]$TraefikIP = "172.22.10.60",
  [string]$TlsDir = "E:\SOC-9000\artifacts\tls",
  [string]$Domain = "lab.local"
)
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$args) kubectl @args }

# Detect Traefik namespace (k3s default = kube-system)
$ns = "kube-system"
try { K -n $ns get deploy traefik | Out-Null } catch { $ns = "traefik"; K -n $ns get deploy traefik | Out-Null }

# Create TLS secret from wildcard cert
$crt = Join-Path $TlsDir "wildcard.$Domain.crt"
$key = Join-Path $TlsDir "wildcard.$Domain.key"
if (!(Test-Path $crt) -or !(Test-Path $key)) { throw "Missing certs in $TlsDir. Run scripts\gen-ssl.ps1 first." }

K -n $ns delete secret wildcard-lab-local-tls --ignore-not-found
K -n $ns create secret tls wildcard-lab-local-tls --cert="$crt" --key="$key"

# Apply TLSStore pointing to the secret
K apply -f k8s\ingress\traefik-tlsstore.yaml

# Patch Traefik service to LoadBalancer with fixed IP + MetalLB hint
K -n $ns patch svc traefik -p @"
{ "spec": { "type":"LoadBalancer", "loadBalancerIP":"$TraefikIP" },
  "metadata": { "annotations": { "metallb.universe.tf/loadBalancerIPs":"$TraefikIP" } }
}
"@
Write-Host "Traefik -> LB $TraefikIP ; default TLS set."
