# Installs an in-cluster NFS server + provisioner and makes its StorageClass 'rwx' the default.
param(
  [string]$Ns = "storage",
  [string]$Release = "nfs-provisioner",
  [string]$ScName = "rwx"
)
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest

helm repo add nfs-ganesha https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ | Out-Null
helm repo update | Out-Null

kubectl get ns $Ns 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { kubectl create ns $Ns | Out-Null }

helm upgrade --install $Release nfs-ganesha/nfs-server-provisioner `
  --namespace $Ns `
  --set persistence.enabled=true `
  --set persistence.size=20Gi `
  --set persistence.storageClass=local-path `
  --set storageClass.name=$ScName `
  --set storageClass.defaultClass=true

Write-Host "RWX StorageClass '$ScName' installed and set as default."
