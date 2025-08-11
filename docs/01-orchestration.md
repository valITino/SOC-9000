# Chunk 1 — Scaffold & Orchestration

This chunk sets up:
- `.env.example` for lab config
- PowerShell orchestration skeleton (`orchestration/*.ps1`)
- Host prep + SSH helper scripts (`scripts/*.ps1`)
- Base docs (`docs/00-prereqs.md`, `docs/overview.md`)

## Next
- **Chunk 2**: Packer templates for pfSense, ContainerHost (Ubuntu 22.04), Windows 11 victim.
- **Chunk 3**: Ansible to configure k3s, Portainer, Traefik, MetalLB.
- **Chunk 4**: Deploy SOC apps (Wazuh, TheHive, Cortex, CALDERA, Nessus, Kali container, vuln apps).
