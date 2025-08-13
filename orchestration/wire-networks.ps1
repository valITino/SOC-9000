#Requires -Version 7
<#[
Wires ContainerHost and Windows victim VMX to VMnets and assigns static MACs.
- ContainerHost: 4 NICs -> VMnet20(MGMT), VMnet21(SOC), VMnet22(VICTIM), VMnet23(RED)
- Windows victim: 1 NIC -> VMnet22(VICTIM)
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Load-Env($path=".env"){
  if(!(Test-Path $path)){ throw ".env not found. Copy .env.example to .env first." }
  Get-Content $path | ? {$_ -and $_ -notmatch '^\s*#'} | % {
      if ($_ -match '^\s*([^=]+)=(.*)$'){
        $name = $matches[1].Trim()
        Set-Item -Path "Env:$name" -Value ($matches[2].Trim())
      }
  }
}

function Edit-Vmx($vmxPath, [hashtable]$pairs){
  if(!(Test-Path $vmxPath)){ throw "VMX not found: $vmxPath" }
  $text = Get-Content $vmxPath -Raw
    foreach($k in $pairs.Keys){
      $v = $pairs[$k]
      $pattern = "(?m)^" + [regex]::Escape($k) + "\s*=\s*\".*?\""
      if($text -match $pattern){
        $text = [regex]::Replace($text, $pattern, "$k = \"$v\"")
      } else {
        $text += "`n$k = \"$v\""
      }
    }
  Set-Content -Path $vmxPath -Value $text -NoNewline
}

function Mac([string]$suffix){ "00:50:56:9a:$suffix" } # VMware OUI + lab
# Our lab MACs (unique per segment)
$MAC = @{
  MGMT   = Mac "10:10"
  SOC    = Mac "20:20"
  VICTIM = Mac "30:30"
  RED    = Mac "40:40"
  WIN    = Mac "30:99"
}

Load-Env

$ART = $env:ARTIFACTS_DIR
$CH_VMX = Join-Path $ART "container-host\container-host.vmx"
$WIN_VMX= Join-Path $ART "victim-win\victim-win.vmx"

Write-Host "== Wiring ContainerHost NICs =="
Edit-Vmx $CH_VMX @{
  'ethernet0.present'       = 'TRUE'
  'ethernet0.virtualDev'    = 'vmxnet3'
  'ethernet0.connectionType'= 'custom'
  'ethernet0.vnet'          = $env:VMNET_MGMT
  'ethernet0.addressType'   = 'static'
  'ethernet0.address'       = $MAC.MGMT

  'ethernet1.present'       = 'TRUE'
  'ethernet1.virtualDev'    = 'vmxnet3'
  'ethernet1.connectionType'= 'custom'
  'ethernet1.vnet'          = $env:VMNET_SOC
  'ethernet1.addressType'   = 'static'
  'ethernet1.address'       = $MAC.SOC

  'ethernet2.present'       = 'TRUE'
  'ethernet2.virtualDev'    = 'vmxnet3'
  'ethernet2.connectionType'= 'custom'
  'ethernet2.vnet'          = $env:VMNET_VICTIM
  'ethernet2.addressType'   = 'static'
  'ethernet2.address'       = $MAC.VICTIM

  'ethernet3.present'       = 'TRUE'
  'ethernet3.virtualDev'    = 'vmxnet3'
  'ethernet3.connectionType'= 'custom'
  'ethernet3.vnet'          = $env:VMNET_RED
  'ethernet3.addressType'   = 'static'
  'ethernet3.address'       = $MAC.RED
}

Write-Host "== Wiring Windows victim NIC =="
Edit-Vmx $WIN_VMX @{
  'ethernet0.present'       = 'TRUE'
  'ethernet0.virtualDev'    = 'vmxnet3'
  'ethernet0.connectionType'= 'custom'
  'ethernet0.vnet'          = $env:VMNET_VICTIM
  'ethernet0.addressType'   = 'static'
  'ethernet0.address'       = $MAC.WIN
}

Write-Host "Done. Next: apply netplan to ContainerHost with these MACs:"
$MAC.GetEnumerator() | % { "{0,-8} {1}" -f $_.Key,$_.Value } | Write-Host
