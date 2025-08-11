# pfSense Install Cheatsheet (SOC-9000)

**VM hardware (VMware Workstation 17 Pro):**
- 2 vCPU, 2 GB RAM, 20–40 GB disk, ISO = `pfsense.iso`
- 5 NICs (vmxnet3), in this order:
  1) VMnet8 (WAN)
  2) VMnet20 (MGMT)
  3) VMnet21 (SOC)
  4) VMnet22 (VICTIM)
  5) VMnet23 (RED)

**Installer (console):**
1. Boot → **Install pfSense**
2. Keymap → **Default** → Continue
3. Partition → **Auto (UFS)** (or ZFS if preferred)
4. Install → **Reboot**

**First boot (console menu):**
- **14) Enable Secure Shell** → **Yes**
- Allow **admin** over SSH (or both admin/root)
- LAN may show `192.168.1.1` initially — automation will change to **`172.22.10.1`**.

**Credentials:**
- If asked during install, use your chosen password.
- Otherwise default: `admin / pfsense`.
- The repo expects: `.env` → `PFSENSE_ADMIN_USER=admin`, `PFSENSE_ADMIN_PASS=...`.

**Back to automation:**
- In your PowerShell window (where `make up-all` paused), press **Enter**.
- Ansible will import config (interfaces, DHCP, firewall rules, remote syslog) and reboot pfSense.

**Final IPs (expected):**
- MGMT/LAN = **172.22.10.1**
- SOC = 172.22.20.1
- VICTIM = 172.22.30.1
- RED = 172.22.40.1
