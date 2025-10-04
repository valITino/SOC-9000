# Make 'local-path' default again and keep 'rwx' available.
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>$null | Out-Null
kubectl patch storageclass rwx -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>$null | Out-Null
Write-Host "Default StorageClass reset to 'local-path'."
