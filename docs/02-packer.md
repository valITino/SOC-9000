# Chunk 2 — Packer images

Builds base VMs for:
- **ContainerHost (Ubuntu 22.04)** — later: k3s, Portainer, Traefik, MetalLB, SOC apps
- **Windows 11 victim** — WinRM-enabled
- **pfSense** — created next chunk, then auto-configured

## Prereqs
ISOs in `E:\SOC-9000\isos`:
- `ubuntu-22.04.iso`, `win11-eval.iso`, `pfsense.iso`

## Build
```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\build-packer.ps1
# or run each packer subdir manually
```
Artifacts are written to E:\SOC-9000\artifacts\<vm-name>\*.vmx.

> The build runs headless. Packer briefly exposes a VNC port for automation, but no viewer is required. On typical hardware, the Ubuntu build takes ~10–20 minutes and the Windows build ~30–60 minutes.
