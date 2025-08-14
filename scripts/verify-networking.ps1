# Verify VMware networking and hosts configuration for SOC-9000
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Find-Exe {
    param([string]$Name,[string[]]$Candidates)
    foreach($c in $candidates){ if(Test-Path $c){return $c} }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return $cmd?.Source
}

$cli = Find-Exe 'vnetlib64.exe' @(
    'C:\Program Files (x86)\VMware\VMware Workstation\vnetlib64.exe',
    'C:\Program Files\VMware\VMware Workstation\vnetlib64.exe'
)
if(-not $cli){ $cli = Find-Exe 'vmnetcfgcli.exe' @('C:\Program Files (x86)\VMware\VMware Workstation\vmnetcfgcli.exe','C:\Program Files\VMware\VMware Workstation\vmnetcfgcli.exe') }

$nets = 'VMnet8','VMnet20','VMnet21','VMnet22','VMnet23'
$adapters = Get-NetAdapter | Where-Object {$_.Name -in $nets}
if($adapters.Count -ne $nets.Count){ throw 'Missing VMnet adapters' }
$adapters | Where-Object {$_.Status -ne 'Up'} | ForEach-Object { throw "Adapter $($_.Name) not Up" }

$subnets = @{VMnet20='172.22.10.0';VMnet21='172.22.20.0';VMnet22='172.22.30.0';VMnet23='172.22.40.0'}
foreach($kv in $subnets.GetEnumerator()){
    $cfg = Get-NetIPConfiguration -InterfaceAlias $kv.Key
    if($cfg.IPv4Address.IPAddress -notlike ($kv.Value.TrimEnd('0')+'1*') -and $cfg.IPv4Address.IPAddress -notlike ($kv.Value.TrimEnd('0')+'2*')){
        throw "Unexpected IP on $($kv.Key): $($cfg.IPv4Address.IPAddress)"
    }
    if($cli){
        $info = & $cli -- getvnet ($kv.Key.ToLower()) 2>$null
        if($info -notmatch [regex]::Escape($kv.Value)){ throw "vnetlib mismatch on $($kv.Key)" }
    }
}

# Services
foreach($s in 'VMware NAT Service','VMnetDHCP'){
    $svc = Get-Service $s -ErrorAction SilentlyContinue
    if($svc -and $svc.Status -ne 'Running'){ throw "$s not running" }
}

# Hosts file block
$hosts = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts"
$block = $hosts | Where-Object { $_ -match '^# SOC-9000 BEGIN' -or $_ -match '^# SOC-9000 END' -or $_ -match 'lab.local' }
if($block -notmatch '# SOC-9000 BEGIN'){ throw 'Hosts block missing' }
$names = 'wazuh.lab.local','thehive.lab.local','cortex.lab.local','caldera.lab.local','dvwa.lab.local','portainer.lab.local','nessus.lab.local'
foreach($n in $names){ if($block -notmatch $n){ throw "Hosts missing $n" } }
$names | ForEach-Object { Resolve-DnsName -Name $_ -ErrorAction Stop | Out-Null }

Write-Host 'Networking verification passed' -ForegroundColor Green
