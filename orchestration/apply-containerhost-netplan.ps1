#Requires -Version 7
<#[
Uploads a netplan config that matches NICs by MAC and sets static IPs from .env.
Then applies netplan inside the guest via vmrun guest ops.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function Load-Env($p=".env"){
  if(!(Test-Path $p)){ throw ".env not found" }
  Get-Content $p | ? {$_ -and $_ -notmatch '^\s*#'} | % {
    if($_ -match '^\s*([^=]+)=(.*)$'){ $env:$($matches[1].Trim()) = $matches[2].Trim() }
  }
}

function Vmrun() {
  $candidates=@(
    "C:\\Program Files (x86)\\VMware\\VMware Workstation\\vmrun.exe",
    "C:\\Program Files\\VMware\\VMware Workstation\\vmrun.exe"
  )
  foreach($p in $candidates){ if(Test-Path $p){ return $p } }
  throw "vmrun not found"
}

Load-Env
$ART = $env:ARTIFACTS_DIR
$CH_VMX = Join-Path $ART "container-host\container-host.vmx"

# MACs must match wire-networks.ps1
$MAC_MGMT   = "00:50:56:9a:10:10"
$MAC_SOC    = "00:50:56:9a:20:20"
$MAC_VICTIM = "00:50:56:9a:30:30"
$MAC_RED    = "00:50:56:9a:40:40"

$NETPLAN = @"
network:
  version: 2
  renderer: networkd
  ethernets:
    mgmt:
      match: { macaddress: '$MAC_MGMT' }
      set-name: mgmt
      addresses: [${env:CH_IP_MGMT}/24]
      gateway4: ${env:PFSENSE_MGMT_IP}
      nameservers: { addresses: [${env:PFSENSE_MGMT_IP}] }
    soc:
      match: { macaddress: '$MAC_SOC' }
      set-name: soc
      addresses: [${env:CH_IP_SOC}/24]
    victim:
      match: { macaddress: '$MAC_VICTIM' }
      set-name: victim
      addresses: [${env:CH_IP_VICTIM}/24]
    red:
      match: { macaddress: '$MAC_RED' }
      set-name: red
      addresses: [${env:CH_IP_RED}/24]
"@

# Save temp and upload to guest
$local = Join-Path $env:TEMP "50-soc-9000.yaml"
$NETPLAN | Set-Content -Path $local -Encoding UTF8

$vmrun = Vmrun
# Ensure VM is running
& $vmrun -T ws start $CH_VMX nogui | Out-Null

# Credentials for guest ops
$gu = $env:ADMIN_USERNAME; if(!$gu){$gu="labadmin"}
$gp = $env:ADMIN_PASSWORD; if(!$gp){$gp="ChangeMe_S0C9000!"}

& $vmrun -T ws -gu $gu -gp $gp CopyFileFromHostToGuest $CH_VMX $local "/home/$gu/50-soc-9000.yaml"
& $vmrun -T ws -gu $gu -gp $gp runProgramInGuest $CH_VMX "/usr/bin/sudo" "mv /home/$gu/50-soc-9000.yaml /etc/netplan/50-soc-9000.yaml"
& $vmrun -T ws -gu $gu -gp $gp runProgramInGuest $CH_VMX "/usr/bin/sudo" "netplan apply"
Write-Host "Applied netplan. Try pinging $($env:CH_IP_MGMT) from host."
