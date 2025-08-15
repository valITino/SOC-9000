# Builds the Nessus VM with Packer, runs the Ansible role, and adds a hosts entry.
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest

function Read-DotEnv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @{} }
  $map = @{}
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $k,$v = $_ -split '=',2
    if ($v -ne $null) { $map[$k.Trim()] = $v.Trim() }
  }
  $map
}

function To-WSLPath([string]$win){ $win -replace '^([A-Za-z]):','/mnt/$1' -replace '\\','/' }

$repoRoot = Split-Path -Parent $PSCommandPath
$envMap = Read-DotEnv -Path (Join-Path $repoRoot "..\.env")

# Get activation code from .env or secure prompt
$act = $envMap.NESSUS_ACTIVATION_CODE
if (-not $act -or $act -eq "") {
  Write-Host "Enter your Nessus activation code (input hidden):"
  $act = Read-Host -AsSecureString | ForEach-Object { (New-Object System.Net.NetworkCredential("u",$_)).Password }
}

# Optional admin user/pass for nessuscli adduser
$adminUser = $envMap.NESSUS_ADMIN_USER
$adminPass = $envMap.NESSUS_ADMIN_PASS

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

# Run Ansible role from WSL with activation vars
$repo = Resolve-Path "$PSScriptRoot/.."
$wslRepo = To-WSLPath $repo
$inv = "$wslRepo/ansible/inventory.ini"
$play= "$wslRepo/ansible/site-nessus.yml"
$cmd = "NESSUS_ACTIVATION_CODE='$act' NESSUS_ADMIN_USER='$adminUser' NESSUS_ADMIN_PASS='$adminPass' ansible-playbook -i '$inv' '$play'"
Write-Host "Running Nessus VM Ansible playbook..." -ForegroundColor Cyan
wsl bash -lc "$cmd"
if ($LASTEXITCODE -ne 0) { throw "Nessus VM configuration failed." }

# Clear sensitive env
$env:NESSUS_ACTIVATION_CODE = $null
$env:NESSUS_ADMIN_PASS = $null

# Add hosts mapping for convenience
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hosts
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN", "$($envMap.NESSUS_VM_IP) nessus.lab.local", "# SOC-9000 END")
Set-Content -Path $hosts -Value ($filtered + $block) -Force

Write-Host "`nDone. Open: https://nessus.lab.local:8834"
