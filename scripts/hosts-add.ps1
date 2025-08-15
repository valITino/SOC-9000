# Adds lab hostnames to Windows hosts file.
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest

if (-not $IsWindows) {
  throw 'hosts-add.ps1 can only run on Windows.'
}

function Get-DotEnv {
  param([string]$Path = '.env')
  $map=@{}
  if(Test-Path $Path){
    Get-Content $Path | Where-Object {$_ -and $_ -notmatch '^\s*#'} | ForEach-Object {
      if($_ -match '^([^=]+)=(.*)$'){ $map[$matches[1].Trim()]=$matches[2].Trim() }
    }
  }
  return $map
}

function K { param([Parameter(ValueFromRemainingArguments)]$KArgs) kubectl @KArgs }

$envMap = Get-DotEnv (Join-Path $PSScriptRoot '..\.env')

function Get-LBIP {
  param($Svc,$Ns,$EnvVar,$Default)
  $ip=""
    try { $ip = K -n $Ns get svc $Svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' } catch { Write-Verbose $_ }
  if(-not $ip -and $envMap[$EnvVar]){ $ip = $envMap[$EnvVar] }
  if(-not $ip){ $ip = $Default }
  return $ip
}

$traefikIP = Get-LBIP 'traefik' 'kube-system' 'TRAEFIK_LB_IP' '172.22.10.60'
$nessusIP  = Get-LBIP 'nessus'  'soc'         'NESSUS_LB_IP'  '172.22.10.61'

$entries = @(
  "$traefikIP wazuh.lab.local",
  "$traefikIP thehive.lab.local",
  "$traefikIP cortex.lab.local",
  "$traefikIP caldera.lab.local",
  "$traefikIP dvwa.lab.local",
  "$traefikIP portainer.lab.local",
  "$nessusIP nessus.lab.local"
)

  $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
  $orig = Get-Content $hosts -ErrorAction Stop
  $filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
  $block = @("# SOC-9000 BEGIN") + $entries + @("# SOC-9000 END")
  Set-Content -Path $hosts -Value ($filtered + $block) -Force
  Write-Output "Hosts file updated:"
  $block | ForEach-Object { "  $_" | Write-Output }
