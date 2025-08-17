[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:hadFail = $false

function Get-DotEnvMap([string]$Path) {
  if (-not (Test-Path $Path)) { return @{} }
  $m = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($null -ne $v) { $m[$k.Trim()] = $v.Trim() }
  }
  $m
}

function Fail($msg){ Write-Host "fail: $msg" -ForegroundColor Red; $script:hadFail = $true }

# Resolve repo + .env
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$EnvFile  = Join-Path $RepoRoot '.env'
$envMap   = Get-DotEnvMap $EnvFile

# Targets (with sane defaults)
$natId     = [int]($envMap['NAT_VMNET_ID']   ?? 8)
$natSubnet =        ($envMap['NAT_SUBNET']   ?? '192.168.37.0')
$ids       = @()
if ($envMap['HOSTONLY_VMNET_IDS']) { $ids = $envMap['HOSTONLY_VMNET_IDS'] -split ',' | ForEach-Object { [int]($_.Trim()) } }
if (-not $ids) { $ids = 9,10,11,12 }

# Optional subnets override (comma-separated), else use defaults
$subnets = @()
if ($envMap['HOSTONLY_SUBNETS']) { $subnets = $envMap['HOSTONLY_SUBNETS'] -split ',' | ForEach-Object { $_.Trim() } }
if (-not $subnets) { $subnets = @('172.22.10.0','172.22.20.0','172.22.30.0','172.22.40.0')[0..($ids.Count-1)] }

if ($ids.Count -ne $subnets.Count) {
  Fail "HOSTONLY_VMNET_IDS count ($($ids.Count)) != HOSTONLY_SUBNETS count ($($subnets.Count))."
}

Write-Host "Verifying: NAT vmnet$natId on $natSubnet/24; Host-only vmnets $($ids -join ', ')" -ForegroundColor Cyan

# --- NAT checks ---
$natAlias = "VMware Network Adapter VMnet$natId"
$natAd = Get-NetAdapter -Name $natAlias -ErrorAction SilentlyContinue
if (-not $natAd) { Fail "Adapter '$natAlias' missing." }
elseif ($natAd.Status -ne 'Up') { Fail "Adapter '$natAlias' is not Up (state=$($natAd.Status))." }

$natIp = Get-NetIPAddress -InterfaceAlias $natAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixLength -eq 24 } | Select-Object -First 1
$expectedNatIp = ($natSubnet -replace '\.0$','.1')
if (-not $natIp) { Fail "No IPv4 /24 configured on '$natAlias'." }
elseif ($natIp.IPAddress -ne $expectedNatIp) { Fail "Expected $expectedNatIp on '$natAlias', got $($natIp.IPAddress)." }

# NAT/DHCP services
foreach ($svcName in 'VMware NAT Service','VMnetDHCP') {
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if (-not $svc) { Fail "Service not found: $svcName" }
  elseif ($svc.Status -ne 'Running') { Fail "Service not running: $svcName (state=$($svc.Status))." }
}

# --- Host-only checks ---
for ($i=0; $i -lt $ids.Count; $i++) {
  $id = $ids[$i]; $subnet = $subnets[$i]
  $alias = "VMware Network Adapter VMnet$id"

  $ad = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
  if (-not $ad){ Fail "Adapter '$alias' missing."; continue }
  if ($ad.Status -ne 'Up'){ Fail "Adapter '$alias' is not Up (state=$($ad.Status))." }

  $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixLength -eq 24 } | Select-Object -First 1
  if (-not $ip) { Fail "No IPv4 /24 configured on '$alias'."; continue }

  $expected = ($subnet -replace '\.0$','.1')
  if ($ip.IPAddress -ne $expected) { Fail "Expected $expected on '$alias', got $($ip.IPAddress)." }
}

if ($script:hadFail) { Write-Error "Networking verification failed."; exit 1 }
Write-Host "Networking verification: OK" -ForegroundColor Green
exit 0