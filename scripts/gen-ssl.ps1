# Generates a local CA and wildcard cert for *.lab.local
param(
  [string]$OutDir = "E:\\SOC-9000\\artifacts\\tls",
  [string]$Domain = "lab.local"
)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
pushd $OutDir

# CA
if(!(Test-Path "./lab-local-ca.key")){
  & openssl genrsa -out lab-local-ca.key 4096
  & openssl req -x509 -new -nodes -key lab-local-ca.key -sha256 -days 3650 -subj "/CN=SOC-9000 Lab CA" -out lab-local-ca.crt
}

# Wildcard
$SAN = @"
subjectAltName = DNS:*.$Domain, DNS:$Domain
basicConstraints = CA:false
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
"@
$SAN | Set-Content -Path san.cnf -Encoding ascii
& openssl genrsa -out wildcard.$($Domain).key 2048
& openssl req -new -key wildcard.$($Domain).key -subj "/CN=*.$Domain" -out wildcard.$($Domain).csr
& openssl x509 -req -in wildcard.$($Domain).csr -CA lab-local-ca.crt -CAkey lab-local-ca.key -CAcreateserial -out wildcard.$($Domain).crt -days 825 -sha256 -extfile san.cnf

popd
Write-Host "Certs ready in $OutDir:"
Get-ChildItem $OutDir | Select Name,Length | Format-Table
Write-Host "Import CA into Windows Trusted Root:"
Write-Host "  certutil -addstore -f -enterprise -user Root `"$OutDir\lab-local-ca.crt`""
