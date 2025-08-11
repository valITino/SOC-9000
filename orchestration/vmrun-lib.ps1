#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Vmrun {
  $c = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
  )
  foreach ($p in $c) { if (Test-Path $p) { return $p } }
  throw "vmrun.exe not found."
}

function Import-DotEnv([string]$Path = ".env") {
  if (!(Test-Path $Path)) { throw ".env not found at $Path. Run 'make init' first." }
  $lines = Get-Content $Path | Where-Object { $_ -and $_ -notmatch '^\s*#' }
  foreach ($l in $lines) { if ($l -match '^\s*([^=]+)=(.*)$') { $env:$($matches[1].Trim()) = $matches[2].Trim() } }
}

function Assert-Path([string]$p, [string]$why) {
  if (!(Test-Path $p)) { throw "Missing: $p ($why)" }
}

function Test-VMwareNetworks {
  $need = @($env:VMNET_WAN,$env:VMNET_MGMT,$env:VMNET_SOC,$env:VMNET_VICTIM,$env:VMNET_RED)
  $have = (Get-NetAdapter -Physical:$false -ErrorAction SilentlyContinue | % Name)
  $miss = $need | ? { $_ -notin $have }
  if ($miss) { throw "Missing VMware networks: $($miss -join ', ')" }
}

function Vmrun { param([Parameter(ValueFromRemainingArguments)] $Args) & (Resolve-Vmrun) @Args }
function Start-VM([string]$Vmx) { Vmrun -T ws start $Vmx nogui | Out-Null }
function Stop-VM([string]$Vmx)  { Vmrun -T ws stop  $Vmx soft   | Out-Null }
function Get-VmxPath([string]$ArtifactsDir,[string]$VmName){ $p = Join-Path $ArtifactsDir "$VmName\$VmName.vmx"; if(Test-Path $p){$p}else{throw "VMX not found: $p"} }

Export-ModuleMember -Function * -ErrorAction SilentlyContinue
