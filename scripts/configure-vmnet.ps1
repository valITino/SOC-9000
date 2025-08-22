<#
.SYNOPSIS
  Configure VMware Workstation VMnets deterministically with approved verbs.
  - NAT on VMnet8 (default 192.168.37.0/24)
  - Host-only on VMnet9..12 (default 172.22.10/20/30/40.0/24)
  - Optional pruning of extra host-only vmnets

.NOTES
  Requires VMware Workstation Pro (vnetlib64.exe).
#>

[CmdletBinding()]
param(
    [switch]$Preview,
    [bool]$PruneExtras = $true,
    [string]$NatSubnet,
    [int[]]$HostOnlyIds,
    [string[]]$HostOnlySubnets
)

function Test-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Error "Run elevated (Administrator)."
    exit 1
}

$ErrorActionPreference = 'Stop'

function Get-VNetLibPath {
    foreach ($p in @(
        "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe",
        "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe"
    )) {
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command vnetlib64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+."
}

$VNET = Get-VNetLibPath

function Invoke-VMnet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$CliArgs,
        [int[]]$AllowedExitCodes = @(0,1,12), # 1 ~ benign no-op on some hosts; 12 ~ already exists
        [switch]$Silent
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $VNET
    $psi.ArgumentList.Add("--")
    foreach ($a in $CliArgs) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $code = $p.ExitCode

    if (-not $AllowedExitCodes.Contains($code)) {
        if (-not $Silent) {
            Write-Warning "vnetlib64 -- $($CliArgs -join ' ') exited $code"
            if ($stdout) { Write-Verbose $stdout }
            if ($stderr) { Write-Verbose $stderr }
        }
        return @{ ExitCode = $code; Stdout = $stdout; Stderr = $stderr; Ok = $false }
    }
    return @{ ExitCode = $code; Stdout = $stdout; Stderr = $stderr; Ok = $true }
}

function Wait-VMnetAdapterUp {
    [CmdletBinding()]
    param([string]$Alias)
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $ad = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue
    } while (-not $ad -and (Get-Date) -lt $deadline)
    if (-not $ad) { throw "Adapter '$Alias' not found after create/update." }
    if ($ad.Status -ne 'Up') {
        Enable-NetAdapter -Name $Alias -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
}

function Set-VMnetNAT {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([string]$Subnet, [string]$Mask = "255.255.255.0")
    $id = 8
    $alias = "VMware Network Adapter VMnet$id"
    if ($PSCmdlet.ShouldProcess("vmnet$id", "Configure NAT $Subnet/$Mask")) {
        Invoke-VMnet -CliArgs @('add','vnet',"vmnet$id") | Out-Null
        Invoke-VMnet -CliArgs @('add','adapter',"vmnet$id") | Out-Null
        Invoke-VMnet -CliArgs @('set','vnet',"vmnet$id",'addr',$Subnet) | Out-Null
        Invoke-VMnet -CliArgs @('set','vnet',"vmnet$id",'mask',$Mask) | Out-Null
        Invoke-VMnet -CliArgs @('add','nat',"vmnet$id") | Out-Null
        # Host .1
        $hostIp = ([IPAddress]::Parse($Subnet)).GetAddressBytes()
        $hostIp[-1] = 1
        $ipStr = ($hostIp | ForEach-Object { $_ }) -join '.'
        Invoke-VMnet -CliArgs @('set','adapter',"vmnet$id",'addr',$ipStr) | Out-Null
        # NAT internal .2
        Invoke-VMnet -CliArgs @('set','nat',"vmnet$id",'internalipaddr',($Subnet -replace '\.0$','.2')) | Out-Null
        Invoke-VMnet -CliArgs @('add','dhcp',"vmnet$id") | Out-Null
        Invoke-VMnet -CliArgs @('update','adapter',"vmnet$id") | Out-Null
        Invoke-VMnet -CliArgs @('update','nat',"vmnet$id") | Out-Null
        Invoke-VMnet -CliArgs @('update','dhcp',"vmnet$id") | Out-Null
        Wait-VMnetAdapterUp -Alias $alias
    }
}

function Set-VMnetHostOnly {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([int]$Id, [string]$Subnet, [string]$Mask = "255.255.255.0")
    $alias = "VMware Network Adapter VMnet$Id"
    if ($PSCmdlet.ShouldProcess("vmnet$Id", "Configure Host-only $Subnet/$Mask")) {
        Invoke-VMnet -CliArgs @('add','vnet',"vmnet$Id") | Out-Null
        Invoke-VMnet -CliArgs @('add','adapter',"vmnet$Id") | Out-Null
        Invoke-VMnet -CliArgs @('set','vnet',"vmnet$Id",'addr',$Subnet) | Out-Null
        Invoke-VMnet -CliArgs @('set','vnet',"vmnet$Id",'mask',$Mask) | Out-Null
        # host .1
        $hostIp = ([IPAddress]::Parse($Subnet)).GetAddressBytes()
        $hostIp[-1] = 1
        $ipStr = ($hostIp | ForEach-Object { $_ }) -join '.'
        Invoke-VMnet -CliArgs @('set','adapter',"vmnet$Id",'addr',$ipStr) | Out-Null
        Invoke-VMnet -CliArgs @('update','adapter',"vmnet$Id") | Out-Null
        Wait-VMnetAdapterUp -Alias $alias
    }
}

function Remove-VMnetHostOnly {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
    param([int]$Id)
    if ($PSCmdlet.ShouldProcess("vmnet$Id", "Remove host-only vnet+adapter")) {
        Invoke-VMnet -CliArgs @('remove','adapter',"vmnet$Id") -AllowedExitCodes @(0,12,1) -Silent | Out-Null
        Invoke-VMnet -CliArgs @('remove','vnet',"vmnet$Id")    -AllowedExitCodes @(0,12,1) -Silent | Out-Null
    }
}

# Resolve target IDs / subnets
if (-not $HostOnlyIds -or $HostOnlyIds.Count -eq 0) {
    $envIds = $env:HOSTONLY_VMNET_IDS
    if ($envIds) {
        $HostOnlyIds = @($envIds -split ',' | ForEach-Object { [int]($_.Trim()) })
    } else {
        $HostOnlyIds = 9,10,11,12
    }
}
if (-not $HostOnlySubnets -or $HostOnlySubnets.Count -eq 0) {
    $HostOnlySubnets = @("172.22.10.0","172.22.20.0","172.22.30.0","172.22.40.0")
}

if ($HostOnlyIds.Count -ne $HostOnlySubnets.Count) {
    throw "HostOnlyIds count ($($HostOnlyIds.Count)) must equal HostOnlySubnets count ($($HostOnlySubnets.Count))."
}

Write-Host "=== Plan ===" -ForegroundColor Cyan
Write-Host ("NAT (vmnet8): {0}/24" -f $NatSubnet)
for ($i=0; $i -lt $HostOnlyIds.Count; $i++) {
    Write-Host ("Host-only (vmnet{0}): {1}/24" -f $HostOnlyIds[$i], $HostOnlySubnets[$i])
}
if ($PruneExtras) { Write-Host "Prune extras: ENABLED" } else { Write-Host "Prune extras: DISABLED" }
Write-Host ""

if ($Preview) {
    Write-Host "Preview only. No changes made."
    exit 0
}

function Ensure-VMwareServices {
  foreach ($svc in 'VMware NAT Service','VMnetDHCP') {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
      if ($s.StartType -ne 'Automatic') { Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue }
      if ($s.Status -ne 'Running')      { Start-Service -Name $svc -ErrorAction SilentlyContinue }
    }
  }
}

# 1) Ensure NAT on vmnet8
if ($NatSubnet) {
  Write-Host "Configuring NAT on VMnet$NatVmnetId to $NatSubnet/24"
  Set-VMnetNAT -Id $NatVmnetId -Subnet $NatSubnet
} else {
  Write-Host "NAT auto mode: leaving VMnet$NatVmnetId as-is (no forced subnet)."
}

# 2) Optionally remove other host-only vmnets to avoid pile-ups
if ($PruneExtras) {
    $existingHostOnlyIds = @()
    Get-NetAdapter -Name "VMware Network Adapter VMnet*" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match 'VMnet(\d+)$') {
            $id = [int]$Matches[1]
            if ($id -ne 0 -and $id -ne 8) { $existingHostOnlyIds += $id }
        }
    }
    $toKeep = $HostOnlyIds
    $toRemove = ($existingHostOnlyIds | Where-Object { $toKeep -notcontains $_ }) | Sort-Object -Unique
    foreach ($rid in $toRemove) {
        Remove-VMnetHostOnly -Id $rid
    }
}

# 3) Lay down host-only vmnets
for ($i=0; $i -lt $HostOnlyIds.Count; $i++) {
    Set-VMnetHostOnly -Id $HostOnlyIds[$i] -Subnet $HostOnlySubnets[$i]
}

Ensure-VMwareServices

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Get-NetAdapter -Name "VMware Network Adapter VMnet*" -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object Name, Status, MacAddress | Format-Table

Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet*" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table
























































