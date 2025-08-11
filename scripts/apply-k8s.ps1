# Applies namespaces, apps, bootstraps Traefik/TLS, and updates hosts file
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$args) kubectl @args }

K apply -f k8s\namespaces.yaml
K apply -f k8s\apps\kali\deployment.yaml
K apply -f k8s\apps\caldera\deployment.yaml
K apply -f k8s\apps\dvwa\deployment.yaml

# Bootstrap Traefik LB + TLS and add hosts entries
pwsh -File scripts\bootstrap-traefik.ps1 -TraefikIP "172.22.10.60"
Start-Sleep -Seconds 5
pwsh -File scripts\hosts-add.ps1 -TraefikIP "172.22.10.60"

Write-Host "`nTest URLs:"
Write-Host "  https://caldera.lab.local  (admin/admin)"
Write-Host "  https://dvwa.lab.local"
Write-Host "Portainer (LB): https://portainer.lab.local:9443  (when LB IP appears)"
