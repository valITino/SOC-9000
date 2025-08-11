#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. $PSScriptRoot/vmrun-lib.ps1
param([switch]$CheckOnly)

Import-DotEnv

$LAB_ROOT=$env:LAB_ROOT; $ISO_DIR=$env:ISO_DIR; $ART_DIR=$env:ARTIFACTS_DIR
Resolve-Vmrun | Out-Null
Test-VMwareNetworks
Assert-Path $LAB_ROOT "LAB_ROOT"; Assert-Path $ISO_DIR "ISO_DIR"; Assert-Path $ART_DIR "ARTIFACTS_DIR"

$planned = @("pfsense","container-host","victim-win")
Write-Host "Planned VMs:"; $planned | % { " - $_" }

if ($CheckOnly) { Write-Host "`nCheck complete. Next: Packer (Chunk 2)."; exit 0 }

Write-Host "`nChunk 1 does not start VMs. Proceed to Chunk 2 to build templates."
