# Builds the Nessus VM with Packer, runs the Ansible role, and adds a hosts entry.
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest

function Get-DotEnv {
  param([string]$Path = '.env')
  if(!(Test-Path $Path)){ throw ".env not found. Copy .env.example to .env first." }
  $map=@{}
  Get-Content $Path | Where-Object {$_ -and $_ -notmatch '^\s*#'} | ForEach-Object {
    if($_ -match '^([^=]+)=(.*)$'){ $map[$matches[1].Trim()] = $matches[2].Trim() }
  }
  return $map
}

function Convert-ToWSLPath {
  param([string]$WinPath)
  if($WinPath -match '^([A-Za-z]):\\(.*)'){
    $drive = $matches[1].ToLower()
    $rest = $matches[2].Replace('\\','/')
    return "/mnt/$drive/$rest"
  }
  return $WinPath.Replace('\\','/')
}

$envMap = Get-DotEnv '.env'
$required = 'ARTIFACTS_DIR','VMNET_SOC','PFSENSE_SOC_IP','NESSUS_VM_IP','NESSUS_VM_CPUS','NESSUS_VM_RAM_MB'
foreach($r in $required){ if(-not $envMap[$r]){ throw ".env missing $r" } }

function K { param([Parameter(ValueFromRemainingArguments)]$args) kubectl @args }

# Build with Packer
pushd packer\nessus-vm
packer init .
packer build -force -var "vmnet=$($envMap.VMNET_SOC)" -var "ip_addr=$($envMap.NESSUS_VM_IP)" -var "ip_gw=$($envMap.PFSENSE_SOC_IP)" -var "ip_dns=$($envMap.PFSENSE_SOC_IP)" `
  -var "cpus=$($envMap.NESSUS_VM_CPUS)" -var "memory_mb=$($envMap.NESSUS_VM_RAM_MB)" .
popd

# Start VM
$vmx = Join-Path $envMap.ARTIFACTS_DIR "nessus-vm\nessus-vm.vmx"
$vmrun = @("C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe","C:\Program Files\VMware\VMware Workstation\vmrun.exe") | ? { Test-Path $_ } | Select-Object -First 1
if (-not $vmrun) { throw "vmrun not found" }
& $vmrun -T ws start $vmx nogui | Out-Null

# Run Ansible role from WSL
$repo = Resolve-Path "$PSScriptRoot/.."
$wslRepo = Convert-ToWSLPath $repo
$inv = "$wslRepo/ansible/inventory.ini"
$play= "$wslRepo/ansible/site-nessus.yml"
wsl bash -lc "ansible-playbook -i '$inv' '$play'"

# Add hosts mapping for convenience
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hosts
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN", "$($envMap.NESSUS_VM_IP) nessus.lab.local", "# SOC-9000 END")
Set-Content -Path $hosts -Value ($filtered + $block) -Force

Write-Host "`nDone. Open: https://nessus.lab.local:8834"
Write-Host "If you didn't pre-set NESSUS_ACTIVATION_CODE, complete activation in the UI."
