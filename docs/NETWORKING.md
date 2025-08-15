# Networking

Use the PowerShell scripts in `scripts/` to configure and validate VMware Workstation virtual networks.

```powershell
pwsh -File .\scripts\configure-vmnet.ps1 -Verbose
pwsh -File .\scripts\verify-networking.ps1
```

`configure-vmnet.ps1` backs up the existing VMnet layout, applies a declarative profile, restarts NAT and DHCP services, disables DHCP on VMnet20–23, and logs to `./logs`. `verify-networking.ps1` performs explicit checks on adapters, service startup types, and DHCP pools, exiting non‑zero on failure.

Re-run `configure-vmnet.ps1` if verification reports issues.
