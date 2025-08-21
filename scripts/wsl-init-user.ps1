[CmdletBinding()]
param(
  [string]$Distro = "Ubuntu",
  [string]$User   = ($env:USERNAME.ToLower()),
  [string]$WindowsPubKey = (Join-Path $HOME ".ssh\id_ed25519.pub")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure the distro exists
$distros = (& wsl -l -q | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $distros) { throw "No WSL distributions registered." }
if ($distros -notcontains $Distro) { throw "WSL distro '$Distro' not found. Registered: $($distros -join ', ')" }

# 1) Create user inside WSL if missing (run as root)
& wsl -d $Distro -u root -- bash -lc "id -u '$User' >/dev/null 2>&1 || (adduser --disabled-password --gecos '' '$User' && usermod -aG sudo '$User')"

# 2) Make the user the default via /etc/wsl.conf (works across launchers)
& wsl -d $Distro -u root -- bash -lc "printf '[user]\ndefault=%s\n' '$User' > /etc/wsl.conf"

# 3) Also try the launcher-specific default-user command if present
$launchers = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps" -Filter "ubuntu*.exe" -ErrorAction SilentlyContinue
$launcher = $launchers | Where-Object { $_.Name -match 'ubuntu(\d{4})?\.exe' } | Select-Object -First 1
if ($launcher) {
  & $launcher.FullName config --default-user $User 2>$null | Out-Null
}

# 4) Authorize the Windows SSH public key for the new user (idempotent)
if (Test-Path $WindowsPubKey) {
  $pub   = Get-Content $WindowsPubKey -Raw
  $token = ($pub -split '\s+')[1]  # base64 field uniquely identifies the key

  # IMPORTANT: use a single-quoted here-string + -f to inject values safely.
  # Let bash expand $u, not PowerShell. Use grep -F (fixed string) for the token.
  $cmd = @'
bash -lc "set -e; u='{0}'; umask 077; \
mkdir -p /home/$u/.ssh; touch /home/$u/.ssh/authorized_keys; \
grep -Fq '{1}' /home/$u/.ssh/authorized_keys || cat >> /home/$u/.ssh/authorized_keys; \
chown -R $u:$u /home/$u/.ssh; chmod 600 /home/$u/.ssh/authorized_keys"
'@ -f $User, $token

$cmd = $cmd -replace "`r",""

  $null = $pub | & wsl -d $Distro -u root -- /bin/sh -c $cmd
  Write-Host "Authorized Windows pubkey for $User in $Distro." -ForegroundColor Green
} else {
  Write-Warning "Windows public key not found at $WindowsPubKey. Run copy-ssh-key-to-wsl.ps1 to generate one."
}

# 5) Restart the distro so the default user takes effect on next launch
& wsl -t $Distro 2>$null | Out-Null
Write-Host "Default user set to '$User'. Re-open the Ubuntu terminal and it should land on that user." -ForegroundColor Green