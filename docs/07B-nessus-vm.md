# Chunk 7B — Nessus VM (persistent)

Builds an Ubuntu 22.04 VM, installs Nessus from the `.deb`, and keeps data across reboots.

## Prereqs
- `E:\SOC-9000\isos\ubuntu-22.04.iso`
- `E:\SOC-9000\isos\nessus_latest_amd64.deb`  (or adjust `NESSUS_DEB` in `.env`)

## Config
Update `.env` (defaults shown):

NESSUS_VM_IP=172.22.20.60
NESSUS_VM_CPUS=2
NESSUS_VM_RAM_MB=4096
NESSUS_DEB=nessus_latest_amd64.deb
NESSUS_ACTIVATION_CODE= # optional; leave blank to activate in UI
NESSUS_ADMIN_USER=nessusadmin
NESSUS_ADMIN_PASS=ChangeMe_S0C!

## Build & configure
```powershell
pwsh -File .\scripts\nessus-vm-build-and-config.ps1
```

### Access

- `https://nessus.lab.local:8834`

If `NESSUS_ACTIVATION_CODE` is set in `.env`, the Ansible role will attempt to register Nessus automatically; otherwise, finish the activation in the UI and create the admin user.
