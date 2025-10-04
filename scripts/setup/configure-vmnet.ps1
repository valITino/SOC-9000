<#
.SYNOPSIS
  Configure VMware Workstation host-only VMnets deterministically with approved verbs.
  - Host-only on VMnet9..12 (default 172.22.10/20/30/40.0/24)
  - Optional pruning of extra host-only vmnets

.NOTES
  Requires VMware Workstation Pro (vnetlib64.exe).
#>

[CmdletBinding()]
param(
    [switch]$Preview,
    [bool]$PruneExtras = $true,
    [int[]]$HostOnlyIds = @(9,10,11,12),
    [string[]]$HostOnlySubnets = @("172.22.10.0","172.22.20.0","172.22.30.0","172.22.40.0")
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
    $paths = @(
        "C:\Program Files\VMware\VMware Workstation\vnetlib64.exe",
        "C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    throw "vnetlib64.exe not found. Install VMware Workstation Pro 17+."
}

$VNET = Get-VNetLibPath

function Invoke-VMnet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$CliArgs,
        [int[]]$AllowedExitCodes = @(0,1,12),
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
            if ($stdout) { Write-Verbose "STDOUT: $stdout" }
            if ($stderr) { Write-Verbose "STDERR: $stderr" }
        }
        return @{ ExitCode = $code; Ok = $false }
    }
    return @{ ExitCode = $code; Ok = $true }
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

function Set-VMnetHostOnly {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [int]$Id,
        [Parameter(Mandatory)]
        [string]$Subnet,
        [string]$Mask = "255.255.255.0"
    )
    $alias = "VMware Network Adapter VMnet$Id"
    if ($PSCmdlet.ShouldProcess("vmnet$Id", "Configure Host-only $Subnet/$Mask")) {
        Invoke-VMnet -CliArgs @('add','vnet',"vmnet$Id") | Out-Null
        Invoke-VMnet -CliArgs @('add','adapter',"vmnet$Id") | Out-Null
        Invoke-VMnet -CliArgs @('set','vnet',"vmnet$Id",'addr',$Subnet) | Out-Null
        Invoke-VMnet -CliArgs @('set','vnet',"vmnet$Id",'mask',$Mask) | Out-Null
        
        $hostIp = ([IPAddress]$Subnet).GetAddressBytes()
        $hostIp[3] = 1
        $ipStr = $hostIp -join '.'
        Invoke-VMnet -CliArgs @('set','adapter',"vmnet$Id",'addr',$ipStr) | Out-Null
        Invoke-VMnet -CliArgs @('update','adapter',"vmnet$Id") | Out-Null
        Wait-VMnetAdapterUp -Alias $alias
    }
}

function Remove-VMnetHostOnly {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Id)
    if ($PSCmdlet.ShouldProcess("vmnet$Id", "Remove host-only vnet+adapter")) {
        Invoke-VMnet -CliArgs @('remove','adapter',"vmnet$Id") -Silent | Out-Null
        Invoke-VMnet -CliArgs @('remove','vnet',"vmnet$Id") -Silent | Out-Null
    }
}

function Ensure-VMwareServices {
    $services = 'VMware NAT Service', 'VMnetDHCP'
    foreach ($svc in $services) {
        try {
            $service = Get-Service -Name $svc -ErrorAction Stop
            if ($service.Status -ne 'Running') {
                Start-Service -Name $svc -ErrorAction Stop
                Write-Host "Started service: $svc"
            }
            if ($service.StartType -ne 'Automatic') {
                Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop
            }
        }
        catch {
            Write-Warning "Could not manage service $svc : $_"
        }
    }
}

# Validate input
if ($HostOnlyIds.Count -ne $HostOnlySubnets.Count) {
    throw "HostOnlyIds count ($($HostOnlyIds.Count)) must equal HostOnlySubnets count ($($HostOnlySubnets.Count))."
}

Write-Host "=== Plan ===" -ForegroundColor Cyan
for ($i=0; $i -lt $HostOnlyIds.Count; $i++) {
    Write-Host ("Host-only (vmnet{0}): {1}/24" -f $HostOnlyIds[$i], $HostOnlySubnets[$i])
}
Write-Host "Prune extras: $(if ($PruneExtras) {'ENABLED'} else {'DISABLED'})"
Write-Host ""

if ($Preview) {
    Write-Host "Preview only. No changes made." -ForegroundColor Yellow
    exit 0
}

# Remove extra host-only networks
if ($PruneExtras) {
    Write-Host "Removing extra host-only networks..."
    $existingAdapters = Get-NetAdapter -Name "VMware Network Adapter VMnet*" -ErrorAction SilentlyContinue
    $keepIds = 0,1,8 + $HostOnlyIds  # Always keep VMnet0 (Bridged), VMnet1 (Host-only), and VMnet8 (NAT)
    foreach ($adapter in $existingAdapters) {
        if ($adapter.Name -match 'VMnet(\d+)') {
            $id = [int]$Matches[1]
            if ($id -notin $keepIds) {
                Remove-VMnetHostOnly -Id $id
            }
        }
    }
}

# Configure host-only networks
for ($i=0; $i -lt $HostOnlyIds.Count; $i++) {
    Write-Host "Configuring host-only on VMnet$($HostOnlyIds[$i]) to $($HostOnlySubnets[$i])/24"
    Set-VMnetHostOnly -Id $HostOnlyIds[$i] -Subnet $HostOnlySubnets[$i]
}

# Ensure services are running
Ensure-VMwareServices

# Display results
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Get-NetAdapter -Name "VMware Network Adapter VMnet*" -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object Name, Status, LinkSpeed | Format-Table

Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet*" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table