[CmdletBinding()]
param(
  [string]$Distro,                                 # optional; auto-pick Ubuntu*
  [ValidateSet('ed25519','rsa')] [string]$KeyType = 'ed25519',
  [string]$Comment = "$env:USERNAME@$(hostname)"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure OpenSSH client
$sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $sshKeygen) {
  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 | Out-Null
  $sshKeygen = Get-Command ssh-keygen -ErrorAction Stop
}

# Ensure a Windows keypair (id_ed25519 by default)
$winSsh = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Path $winSsh -Force | Out-Null
$keyBase = Join-Path $winSsh ("id_{0}" -f $KeyType)
$pub  = "$keyBase.pub"
if (-not (Test-Path $pub)) {
  & $sshKeygen.Source -t $KeyType -f $keyBase -N "" -C $Comment | Out-Null
}

# Pick/validate a distro
$dlist = & wsl -l -q | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not $dlist) {
  Write-Warning "No WSL distributions registered. I’ll run 'wsl-prepare.ps1' for you."
  & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'wsl-prepare.ps1')
  $dlist = & wsl -l -q | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
if (-not $dlist) { throw "WSL still not present after prepare step." }

if (-not $Distro) {
  $Distro = ($dlist | Where-Object { $_ -match '^Ubuntu' } | Select-Object -First 1)
  if (-not $Distro) { $Distro = $dlist[0] }
}

# If the distro is not initialized yet, this test command will fail fast.
$initialized = $true
try { & wsl -d $Distro -- echo ok | Out-Null } catch { $initialized = $false }

if (-not $initialized) {
  Write-Warning @"
The '$Distro' distro is installed but not initialized.
Please open the "Ubuntu" app once to create the Linux user,
then rerun setup. (This is a one-time action.)
"@
  exit 2
}

# Append pubkey to ~/.ssh/authorized_keys (idempotent)
$pubKey = Get-Content $pub -Raw
$token = ($pubKey -split '\s+')[1]  # unique base64 field
$cmd = "bash -lc ""set -e; umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; \
grep -q '$token' ~/.ssh/authorized_keys || cat >> ~/.ssh/authorized_keys; \
chmod 600 ~/.ssh/authorized_keys"""
$null = $pubKey | & wsl.exe -d $Distro -- /bin/sh -c $cmd

Write-Host "SSH key authorized in WSL ($Distro): ~/.ssh/authorized_keys" -ForegroundColor Green
