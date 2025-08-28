Write-Host "Checking for VMware Tools..."

# Check if VMware Tools are already installed
if (Get-Service -Name VMTools -ErrorAction SilentlyContinue) {
    Write-Host "VMware Tools are already installed"
    exit 0
}

# Try to install from CD-ROM
$cdDrive = Get-WmiObject -Class Win32_CDROMDrive | Select-Object -First 1
if ($cdDrive) {
    $driveLetter = $cdDrive.Drive
    $setupPath = Join-Path $driveLetter "setup64.exe"
    
    if (Test-Path $setupPath) {
        Write-Host "Installing VMware Tools from $setupPath"
        Start-Process -FilePath $setupPath -ArgumentList "/S /v `/qn" -Wait
        Write-Host "VMware Tools installation completed"
    } else {
        Write-Host "VMware Tools setup not found on CD-ROM"
    }
} else {
    Write-Host "No CD-ROM drive found"
}