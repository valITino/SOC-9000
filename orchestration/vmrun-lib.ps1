#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:VmrunPath = $null
$script:VmrunChecked = $false

function Resolve-Vmrun {
  if ($script:VmrunChecked) { return $script:VmrunPath }
  $script:VmrunChecked = $true
  $c = @(
    "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
    "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
  )
  foreach ($p in $c) {
    if (Test-Path $p) {
      $script:VmrunPath = $p
      break
    }
  }
  if (-not $script:VmrunPath) {
    Write-Warning "vmrun.exe not found; VMware operations will be skipped."
  }
  return $script:VmrunPath
}

function Import-DotEnv([string]$Path = ".env") {
  if (!(Test-Path $Path)) { throw ".env not found at $Path. Copy .env.example to .env first." }
  $lines = Get-Content $Path | Where-Object { $_ -and $_ -notmatch '^\s*#' }
  foreach ($l in $lines) {
    if ($l -match '^\s*([^=]+)=(.*)$') {
      Set-Item -Path "Env:$($matches[1].Trim())" -Value $matches[2].Trim()
    }
  }
}

function Assert-Path([string]$p, [string]$why) {
  if (!(Test-Path $p)) { throw "Missing: $p ($why)" }
}

function Test-VMwareNetworks {
  if (-not (Resolve-Vmrun)) { return }
  $getNetAdapter = Get-Command Get-NetAdapter -ErrorAction SilentlyContinue
  if (-not $getNetAdapter) {
    Write-Warning "Get-NetAdapter cmdlet missing; skipping network check."
    return
  }
  $need = @($env:VMNET_WAN,$env:VMNET_MGMT,$env:VMNET_SOC,$env:VMNET_VICTIM,$env:VMNET_RED)
  $have = (Get-NetAdapter -Physical:$false -ErrorAction SilentlyContinue | % Name)
  $miss = $need | ? { $_ -notin $have }
  if ($miss) { throw "Missing VMware networks: $($miss -join ', ')" }
}

function Vmrun { param([Parameter(ValueFromRemainingArguments)] $Args) & (Resolve-Vmrun) @Args }
function Start-VM([string]$Vmx) { Vmrun -T ws start $Vmx nogui | Out-Null }
function Stop-VM([string]$Vmx)  { Vmrun -T ws stop  $Vmx soft   | Out-Null }
function Get-VmxPath([string]$ArtifactsDir,[string]$VmName){ $p = Join-Path $ArtifactsDir "$VmName\$VmName.vmx"; if(Test-Path $p){$p}else{throw "VMX not found: $p"} }
