# SOC-9000 — Chunk 0: Host prerequisites

Goal: Prepare Windows 11 + VMware Workstation for a pfSense-routed, k3s-managed, Portainer-controlled SOC lab.

## Requirements

- Windows 11 (Administrator)
- VMware Workstation 17 Pro (`vmrun`)
- Git, PowerShell 7+, HashiCorp Packer
- WSL with Ubuntu 22.04 + Ansible

## Host folders

- `E:\\SOC-9000`
- `isos\\` — pfSense/Ubuntu/Windows ISOs + Nessus .deb
- `artifacts\\` — Packer VM templates (output)
- `temp\\` — transient files

## Networks (Virtual Network Editor)

- `VMnet8` — NAT (DHCP ON)
- `VMnet20` — MGMT `172.22.10.0/24` (DHCP OFF)
- `VMnet21` — SOC  `172.22.20.0/24` (DHCP OFF)
- `VMnet22` — VICTIM `172.22.30.0/24` (DHCP OFF)
- `VMnet23` — RED `172.22.40.0/24` (DHCP OFF)

> We emulate VLANs using multiple VMnets; pfSense has one NIC per segment.

## Downloads (place into `E:\\SOC-9000\\isos`)

- pfSense CE ISO (AMD64)  → `pfsense.iso`
- Ubuntu Server 22.04 ISO (AMD64) → `ubuntu-22.04.iso`
- Windows 11 Evaluation ISO (EN-Intl) → `win11-eval.iso`
- Nessus Essentials `.deb` (Ubuntu AMD64)

## SSH key

Generate or reuse:

```powershell
ssh-keygen -t ed25519 -C "soc-9000" -f $env:USERPROFILE\.ssh\id_ed25519

Copy into WSL (recommended):

pwsh -File .\scripts\copy-ssh-key-to-wsl.ps1
```

## Quick start

```powershell
# (after cloning the repo)
pwsh -ExecutionPolicy Bypass -File .\scripts\host-prepare.ps1
```

## Notes

k3s uses containerd by default; Docker images run fine.
We'll add Portainer, Traefik (TLS for *.lab.local), and MetalLB IP pools per segment in later chunks.
