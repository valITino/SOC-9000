# Stop VMs gracefully (does not delete data)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest

function Vmrun() {
  @("C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe") |
    ? { Test-Path $_ } | Select-Object -First 1
}
$vmrun = Vmrun; if(!$vmrun){ throw "vmrun not found" }

$envPath = ".env"
if (Test-Path $envPath) {
  (Get-Content $envPath | ? {$_ -and $_ -notmatch '^\s*#'}) | % {
    if ($_ -match '^ARTIFACTS_DIR=(.*)$'){ $art = $matches[1].Trim() }
  }
}
$vmx = @(
  "pfsense\pfsense.vmx",
  "container-host\container-host.vmx",
  "victim-win\victim-win.vmx",
  "nessus-vm\nessus-vm.vmx"
) | % { Join-Path $art $_ } | ? { Test-Path $_ }

foreach($v in $vmx){
  try { & $vmrun -T ws stop $v soft | Out-Null; Write-Host "Stopped: $v" } catch { Write-Warning "Skip: $v" }
}
Write-Host "Lab VMs stopped."
