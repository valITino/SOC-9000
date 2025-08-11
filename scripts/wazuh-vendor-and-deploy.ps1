<#
Clones upstream Wazuh K8s manifests (v4.12.0) into third_party/,
generates required certificates via upstream scripts (using WSL),
creates kustomize secrets, applies the stack, and adds hosts entry.

Prereqs:
- WSL Ubuntu installed (from earlier chunks)
- kubectl context points to your k3s on ContainerHost
- OpenSSL available in WSL (default)
#>

param(
  [string]$Ref = "v4.12.0",
  [string]$VendorDir = "third_party\\wazuh-kubernetes",
  [string]$OverlayDir = "k8s\\apps\\wazuh",
  [string]$TraefikIP = "172.22.10.60"
)

$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest

# 1) Vendor upstream
if (!(Test-Path $VendorDir)) {
  git clone https://github.com/wazuh/wazuh-kubernetes.git -b $Ref --depth=1 $VendorDir
  Write-Host "Cloned wazuh-kubernetes@$Ref -> $VendorDir"
} else {
  Write-Host "Vendor dir exists, skipping clone."
}

# 2) Generate certs with upstream scripts in WSL
$repoWin = (Resolve-Path $VendorDir).Path
$repoWsl = "/mnt/" + $repoWin.Substring(0,1).ToLower() + $repoWin.Substring(2).Replace('\\','/')

wsl bash -lc "set -euo pipefail; cd '$repoWsl/wazuh/certs/indexer_cluster'; chmod +x generate_certs.sh; ./generate_certs.sh"
wsl bash -lc "set -euo pipefail; cd '$repoWsl/wazuh/certs/dashboard_http'; chmod +x generate_certs.sh; ./generate_certs.sh"

# 3) Copy certs into our overlay
$dst1 = Join-Path $OverlayDir "certs\\indexer_cluster"
$dst2 = Join-Path $OverlayDir "certs\\dashboard_http"
New-Item -ItemType Directory -Force -Path $dst1 | Out-Null
New-Item -ItemType Directory -Force -Path $dst2 | Out-Null
Copy-Item "$VendorDir\\wazuh\\certs\\indexer_cluster\\*.pem" $dst1 -Force
Copy-Item "$VendorDir\\wazuh\\certs\\dashboard_http\\*.pem" $dst2 -Force

# 4) Apply via kustomize
kubectl apply -k $OverlayDir

# 5) Add hosts line for wazuh.lab.local -> Traefik IP
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hosts
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN",
           "$TraefikIP wazuh.lab.local",
           "# SOC-9000 END")
Set-Content -Path $hosts -Value ($filtered + $block) -Force

Write-Host "`nApplied Wazuh. Watch progress:"
Write-Host "  kubectl get pods -n soc -w"
Write-Host "When ready: https://wazuh.lab.local  (default login: admin / SecretPassword)"
