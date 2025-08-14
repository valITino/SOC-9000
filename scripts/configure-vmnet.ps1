# Configure VMware VMnet adapters for SOC-9000
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'configure-vmnet.ps1 can only run on Windows.'
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Find-Exe {
    param(
        [string]$Name,
        [string[]]$Candidates
    )
    foreach ($c in $Candidates) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-External {
    param(
        [string]$File,
        [string[]]$Arguments
    )
    Write-Verbose "Running: $File $Arguments"
    & $File @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$File $Arguments' failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Admin)) {
    Write-Error 'Run as administrator. Hint: Start-Process pwsh -Verb RunAs scripts\configure-vmnet.ps1'
    exit 1
}

$cli = Find-Exe 'vnetlib64.exe' @(
    'C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe',
    'C:\Program Files\VMware\VMware Workstation\vnetlib64.exe'
)
$useVmnetcfg = $false
if (-not $cli) {
    $cli = Find-Exe 'vmnetcfgcli.exe' @(
        'C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfgcli.exe',
        'C:\Program Files\VMware\VMware Workstation\vmnetcfgcli.exe'
    )
    if ($cli) { $useVmnetcfg = $true }
}
if (-not $cli) {
    throw 'VMware network CLI not found. Open Workstation → Edit → Virtual Network Editor → Install'
}

$nets = @(
    @{Name='vmnet8';  Type='nat';      Subnet='192.168.37.0'; Dhcp=$true},
    @{Name='vmnet20'; Type='hostonly'; Subnet='172.22.10.0'; Dhcp=$false},
    @{Name='vmnet21'; Type='hostonly'; Subnet='172.22.20.0'; Dhcp=$false},
    @{Name='vmnet22'; Type='hostonly'; Subnet='172.22.30.0'; Dhcp=$false},
    @{Name='vmnet23'; Type='hostonly'; Subnet='172.22.40.0'; Dhcp=$false}
)

function Get-NetworkInfo {
    param([string]$Name)
    try {
        & $cli -- getvnet $Name 2>$null
    } catch { return '' }
}

foreach ($n in $nets) {
    if ($PSCmdlet.ShouldProcess($n.Name, 'configure')) {
        if (-not (Get-NetworkInfo $n.Name)) {
            # create network
            if ($useVmnetcfg) {
                Invoke-External $cli @('--add',$n.Name,'--type',$n.Type,'--subnet',$n.Subnet,'--netmask','255.255.255.0','--dhcp',($n.Dhcp?'yes':'no'))
            } else {
                Invoke-External $cli @('--','addNetwork', $n.Name)
            }
        }
        if (-not $useVmnetcfg) {
            Invoke-External $cli @('--','setSubnet',$n.Name,$n.Subnet,'255.255.255.0')
            Invoke-External $cli @('--','setDhcp',$n.Name,($n.Dhcp?'on':'off'))
            if ($n.Type -eq 'nat') {
                Invoke-External $cli @('--','setNat',$n.Name,'on')
            } else {
                Invoke-External $cli @('--','setNat',$n.Name,'off')
            }
            Invoke-External $cli @('--','updateAdapter',$n.Name)
        }
        if ($useVmnetcfg) {
            # vmnetcfgcli already applied full config above, but ensure idempotent subnet
            Invoke-External $cli @('--update',$n.Name,'--subnet',$n.Subnet,'--netmask','255.255.255.0','--dhcp',($n.Dhcp?'yes':'no'))
            if ($n.Type -eq 'nat') { Invoke-External $cli @('--nat',$n.Name,'on') }
            else { Invoke-External $cli @('--nat',$n.Name,'off') }
        }
    }
}

# Restart services for NAT/DHCP where applicable
$services = 'VMnetDHCP','VMware NAT Service'
foreach($s in $services){
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if($svc){
        if($PSCmdlet.ShouldProcess($s,'restart')){
            Stop-Service $svc -ErrorAction SilentlyContinue
            Start-Service $svc -ErrorAction SilentlyContinue
        }
    }
}

$rows = @()
foreach($n in $nets){
    $ip = (Get-NetIPConfiguration -InterfaceAlias $n.Name -ErrorAction SilentlyContinue).IPv4Address.IPAddress
    $rows += [pscustomobject]@{VMnet=$n.Name;Type=$n.Type;Subnet=$n.Subnet;Dhcp=($n.Dhcp?'ON':'OFF');HostIP=$ip}
}
$rows | Format-Table -AutoSize
