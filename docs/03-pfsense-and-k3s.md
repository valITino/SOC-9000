# Chunk 3 — pfSense + k3s + Portainer + MetalLB

This chunk:
- Wires ContainerHost/Windows VM NICs (VMnets) and sets static MACs
- Applies a netplan to ContainerHost with static IPs
- Installs pfSense (manual, once), then auto-imports config.xml via Ansible
- Installs k3s, MetalLB, Portainer on ContainerHost

## 1) Wire NICs
```powershell
pwsh -File .\orchestration\wire-networks.ps1
```

## 2) Apply netplan (ContainerHost)
```powershell
pwsh -File .\orchestration\apply-containerhost-netplan.ps1
# verify: ping CH_IP_MGMT (default 172.22.10.10)
```

## 3) pfSense (one-time manual install)

- Create VM with 5 NICs:
    - WAN: VMnet8
    - LAN/MGMT: VMnet20
    - SOC: VMnet21
    - VICTIM: VMnet22
    - RED: VMnet23
- Install pfSense from ISO. Set admin password (see .env).
- Enable SSH in pfSense console (Option 14).
- Verify: `ssh admin@172.22.10.1`

## 4) Run Ansible
```bash
cd ansible
ansible-playbook -i inventory.ini site.yml
```
This will:
- Upload and restore a templated config.xml to pfSense and reboot it.
- Install k3s, deploy MetalLB, and Portainer on ContainerHost.

## 5) TLS (optional for now)
```powershell
pwsh -File .\scripts\gen-ssl.ps1
```

After success:
- `kubectl get svc -A` should show Portainer as LoadBalancer with an IP from the MGMT pool (172.22.10.50+).
- Browse to `https://<that-ip>:9443` for Portainer initial setup.
