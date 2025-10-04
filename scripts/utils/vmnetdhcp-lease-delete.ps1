Stop-Service "VMware DHCP Service" -ErrorAction SilentlyContinue
Stop-Service "VMware NAT Service"  -ErrorAction SilentlyContinue
Remove-Item "C:\ProgramData\VMware\vmnetdhcp.leases" -Force -ErrorAction SilentlyContinue
Start-Service 'VMware DHCP Service'
Start-Service 'VMware NAT Service'
Get-Content 'C:\ProgramData\VMware\vmnetdhcp.leases' -Tail 10 -Wait