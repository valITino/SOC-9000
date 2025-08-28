# FirstLogon.ps1 — enable WinRM (HTTP/5985) for Packer
$log = 'C:\Windows\Setup\Scripts\FirstLogon.log'
Start-Transcript -Path $log -Append

# Make the network profile Private (firewall rules open on Private/Domain)
try {
  Get-NetConnectionProfile | ForEach-Object {
    if ($_.NetworkCategory -ne 'Private') {
      Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
  }
} catch {}

# Enable WinRM + PSRemoting and ensure service/listener exist
& winrm quickconfig -q 2>$null
sc.exe config WinRM start= auto | Out-Null
Start-Service WinRM
Enable-PSRemoting -Force

# Allow Basic + unencrypted auth (Packer defaults)
Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true -Force
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force

# Ensure HTTP listener on all addresses exists
$http = Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -match 'Transport=HTTP' }
if (-not $http) { New-Item -Path WSMan:\localhost\Listener -Transport HTTP -Address * -Force | Out-Null }

# Open firewall for WinRM
netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes | Out-Null

# (Optional) avoid remote UAC filtering for local admin over some channels
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f | Out-Null

# Wait until we have a real IPv4 and 5985 is listening
$deadline = (Get-Date).AddMinutes(5)
do {
  $ipReady   = @(Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual |
                Where-Object { $_.IPAddress -notlike '169.254*' }).Count -gt 0
  $portReady = (Get-NetTCPConnection -LocalPort 5985 -State Listen -ErrorAction SilentlyContinue) -ne $null
  if ($ipReady -and $portReady) { break }
  Start-Sleep -Seconds 3
} while (Get-Date) -lt $deadline

# Stop autologon after this run (you already log in once via unattend)
Set-ItemProperty -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
  -Name 'AutoLogonCount' -Type DWord -Value 0 -Force

Stop-Transcript
