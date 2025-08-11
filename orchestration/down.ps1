#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. $PSScriptRoot/vmrun-lib.ps1

Import-DotEnv
$ART_DIR=$env:ARTIFACTS_DIR
$targets=@("pfsense","container-host","victim-win")

foreach ($t in $targets) {
  try { $vmx = Get-VmxPath -ArtifactsDir $ART_DIR -VmName $t; Write-Host "Stopping $t ..."; Stop-VM $vmx }
  catch { Write-Warning "Skip $t: $($_.Exception.Message)" }
}
Write-Host "Down complete."
