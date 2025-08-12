# Builds the Nessus VM with Packer, runs the Ansible role, and adds a hosts entry.
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
function K { param([Parameter(ValueFromRemainingArguments)]$args) kubectl @args }

# Load .env
if (!(Test-Path ".env")) { throw ".env not found. Copy .env.example to .env first." }
(Get-Content ".env" | ? {$_ -and $_ -notmatch '^\s*#'}) | % {
  if ($_ -match '^\s*([^=]+)=(.*)$'){ $env:$($matches[1].Trim())=$matches[2].Trim() }
}

# Build with Packer
pushd packer\nessus-vm
packer init .
packer build -force -var "vmnet=$env:VMNET_SOC" -var "ip_addr=$env:NESSUS_VM_IP" -var "ip_gw=$env:PFSENSE_SOC_IP" -var "ip_dns=$env:PFSENSE_SOC_IP" `
  -var "cpus=$env:NESSUS_VM_CPUS" -var "memory_mb=$env:NESSUS_VM_RAM_MB" .
popd

# Start VM
$vmx = Join-Path $env:ARTIFACTS_DIR "nessus-vm\nessus-vm.vmx"
$vmrun = @("C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe","C:\Program Files\VMware\VMware Workstation\vmrun.exe") | ? { Test-Path $_ } | Select-Object -First 1
if (-not $vmrun) { throw "vmrun not found" }
& $vmrun -T ws start $vmx nogui | Out-Null

# Run Ansible role from WSL (uses /mnt/e path to copy .deb)
$inv = "/mnt/e/SOC-9000/SOC-9000/ansible/inventory.ini"
$play= "/mnt/e/SOC-9000/SOC-9000/ansible/site-nessus.yml"
wsl bash -lc "ansible-playbook -i '$inv' '$play'"

# Add hosts mapping for convenience
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$orig = Get-Content $hosts
$filtered = $orig | Where-Object { $_ -notmatch '^# SOC-9000 BEGIN' -and $_ -notmatch '^# SOC-9000 END' }
$block = @("# SOC-9000 BEGIN", "$($env:NESSUS_VM_IP) nessus.lab.local", "# SOC-9000 END")
Set-Content -Path $hosts -Value ($filtered + $block) -Force

Write-Host "`nDone. Open: https://nessus.lab.local:8834"
Write-Host "If you didn't pre-set NESSUS_ACTIVATION_CODE, complete activation in the UI."
