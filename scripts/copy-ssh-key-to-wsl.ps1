# SOC-9000 - copy-ssh-key-to-wsl.ps1
param(
  [string]$WinSshDir = "$env:USERPROFILE\.ssh"
)
$priv = Join-Path $WinSshDir "id_ed25519"
$pub  = Join-Path $WinSshDir "id_ed25519.pub"
if (!(Test-Path $priv) -or !(Test-Path $pub)) { throw "SSH key not found in $WinSshDir. Generate it first." }
wsl mkdir -p ~/.ssh
wsl cp /mnt/c/Users/$env:USERNAME/.ssh/id_ed25519 ~/.ssh/
wsl cp /mnt/c/Users/$env:USERNAME/.ssh/id_ed25519.pub ~/.ssh/
wsl bash -lc "chmod 600 ~/.ssh/id_ed25519 && chmod 644 ~/.ssh/id_ed25519.pub && echo 'OK: SSH key copied & perms fixed.'"
