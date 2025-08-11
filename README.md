# SOC-9000

A pfSense-routed, Kubernetes-managed SOC lab on VMware Workstation 17 Pro (Windows 11).

**VMs:** pfSense (edge), ContainerHost (k3s, Portainer, Traefik, MetalLB), Windows 11 victim.  
**Containers:** Wazuh, TheHive, Cortex, CALDERA, Nessus, Kali (CLI), vuln apps.

Start with `docs/00-prereqs.md`, then:

```powershell
git clone <repo-url> E:\SOC-9000\SOC-9000
cd E:\SOC-9000\SOC-9000
make init
# edit .env
make check
```
