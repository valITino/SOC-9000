[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu",
    [string]$User = ($env:USERNAME.ToLower()),
    [string]$WindowsPubKey = (Join-Path $HOME ".ssh\id_ed25519.pub")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-WSLDistro {
    param([string]$DistroName)
    
    try {
        $distros = (wsl -l -q) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        return $distros -contains $DistroName
    }
    catch {
        throw "Failed to retrieve WSL distributions: $($_.Exception.Message)"
    }
}

function Add-WSLUser {
    param([string]$DistroName, [string]$UserName)
    
    $createUserCmd = @"
if id -u '$UserName' >/dev/null 2>&1; then
    echo "User '$UserName' already exists."
else
    adduser --disabled-password --gecos '' '$UserName' && \
    usermod -aG sudo '$UserName' && \
    echo "Created user '$UserName' and added to sudo group."
fi
"@
    
    try {
        $output = wsl -d $DistroName -u root -- bash -c $createUserCmd
        Write-Host $output -ForegroundColor Green
    }
    catch {
        throw "Failed to create user '$UserName' in distro '$DistroName': $($_.Exception.Message)"
    }
}

function Set-WSLDefaultUser {
    param([string]$DistroName, [string]$UserName)
    
    try {
        # Set default user in wsl.conf
        $setDefaultCmd = "printf '[user]\ndefault=%s\n' '$UserName' > /etc/wsl.conf"
        wsl -d $DistroName -u root -- bash -c $setDefaultCmd
        
        # Also try to set via Ubuntu launcher if available
        $launchers = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps" -Filter "ubuntu*.exe" -ErrorAction SilentlyContinue
        $launcher = $launchers | Where-Object { $_.Name -match 'ubuntu(\d{4})?\.exe' } | Select-Object -First 1
        
        if ($launcher) {
            & $launcher.FullName config --default-user $User 2>$null
        }
        
        Write-Host "Set default user to '$UserName' for distro '$DistroName'" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not set default user via all methods: $($_.Exception.Message)"
    }
}

function Add-SSHKeyToWSL {
    param([string]$DistroName, [string]$UserName, [string]$PubKeyPath)
    
    if (-not (Test-Path $PubKeyPath)) {
        Write-Warning "Windows public key not found at $PubKeyPath. SSH key authorization skipped."
        return
    }
    
    try {
        $pubKeyContent = Get-Content $PubKeyPath -Raw
        $pubKeyContent = $pubKeyContent.Trim()
        
        # Use single quotes and proper escaping for the bash command
        $sshSetupCmd = @'
set -e
user='{0}'
umask 077
mkdir -p "/home/$user/.ssh"
touch "/home/$user/.ssh/authorized_keys"

# Check if key already exists
if ! grep -Fq "{1}" "/home/$user/.ssh/authorized_keys"; then
    echo "{1}" >> "/home/$user/.ssh/authorized_keys"
    echo "Added SSH public key for user $user"
else
    echo "SSH public key already exists for user $user"
fi

chown -R "$user:$user" "/home/$user/.ssh"
chmod 600 "/home/$user/.ssh/authorized_keys"
'@ -f $UserName, $pubKeyContent
        
        # Remove carriage returns to prevent bash syntax errors
        $sshSetupCmd = $sshSetupCmd -replace "`r", ""
        
        wsl -d $DistroName -u root -- bash -c $sshSetupCmd
        Write-Host "Authorized Windows SSH key for user '$UserName' in distro '$DistroName'" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to authorize SSH key: $($_.Exception.Message)"
    }
}

function Restart-WSLDistro {
    param([string]$DistroName)
    
    try {
        wsl -t $DistroName 2>$null
        Write-Host "Restarted WSL distro '$DistroName'" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not restart WSL distro: $($_.Exception.Message)"
    }
}

# Main execution
try {
    Write-Host "=== WSL User Initialization ===" -ForegroundColor Cyan
    Write-Host "Distro: $Distro" -ForegroundColor Cyan
    Write-Host "User: $User" -ForegroundColor Cyan
    Write-Host ""

    # Verify distro exists
    if (-not (Test-WSLDistro -DistroName $Distro)) {
        throw "WSL distro '$Distro' not found. Available distros: $((wsl -l -q) -join ', ')"
    }

    # Create user if needed
    Add-WSLUser -DistroName $Distro -UserName $User

    # Set as default user
    Set-WSLDefaultUser -DistroName $Distro -UserName $User

    # Add SSH key authorization
    Add-SSHKeyToWSL -DistroName $Distro -UserName $User -PubKeyPath $WindowsPubKey

    # Restart distro
    Restart-WSLDistro -DistroName $Distro

    Write-Host "`n=== Setup Complete ===" -ForegroundColor Green
    Write-Host "Default user set to '$User'. Re-open your WSL terminal to see the changes." -ForegroundColor Green
}
catch {
    Write-Error "WSL user initialization failed: $($_.Exception.Message)"
    exit 1
}