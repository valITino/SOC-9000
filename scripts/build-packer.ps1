# Build Ubuntu ContainerHost and Windows victim with dynamic ISO paths.
# Uses Packer's headless vmware-iso builder; a temporary VNC endpoint is printed but no viewer is required.
# Expect roughly 10–20 minutes for the Ubuntu build and 30–60 minutes for the Windows build on typical hardware.
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest

# Read .env for ISO_DIR and filenames
$envPath  = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
$envLines = Get-Content $envPath | Where-Object { $_ -and $_ -notmatch '^\s*#' }
$isoDir      = ($envLines | Where-Object { $_ -match '^ISO_DIR=' })      -replace '^ISO_DIR=', ''
$isoUbuntu   = ($envLines | Where-Object { $_ -match '^ISO_UBUNTU=' })   -replace '^ISO_UBUNTU=', ''
$isoWindows  = ($envLines | Where-Object { $_ -match '^ISO_WINDOWS=' })  -replace '^ISO_WINDOWS=', ''

$ubuntuPath  = Join-Path $isoDir $isoUbuntu
$windowsPath = Join-Path $isoDir $isoWindows

pushd packer\ubuntu-container
packer init .
packer build -force -var "iso_path=$ubuntuPath" .
popd

pushd packer\windows-victim
packer init .
packer build -force -var "iso_path=$windowsPath" .
popd

Write-Host "Packer builds complete. Check $isoDir\..\artifacts\* for VMX files."
