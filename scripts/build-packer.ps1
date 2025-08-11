# Build Ubuntu ContainerHost and Windows victim
$ErrorActionPreference = "Stop"
pushd packer\ubuntu-container
packer init .
packer build -force .
popd

pushd packer\windows-victim
packer init .
packer build -force .
popd

Write-Host "Packer builds complete. Check E:\SOC-9000\artifacts\* for VMX files."
