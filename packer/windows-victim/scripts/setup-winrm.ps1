Write-Host "Configuring WinRM for Packer..."
winrm quickconfig -q
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value true
Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value true
netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes
Enable-PSRemoting -Force
