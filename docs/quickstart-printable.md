# SOC-9000 Quick-Start (Printable)

**Tools (Windows):** VMware Workstation 17 Pro, Git, Packer, kubectl, Helm, OpenSSL, WSL2/Ubuntu 22.04 (Ansible)

**Folders:** `E:\SOC-9000\{isos,artifacts,temp}`

**ISOs:** ubuntu-22.04.iso, win11-eval.iso, pfsense.iso (+ optional nessus_latest_amd64.deb)

**VMware nets:** VMnet20=172.22.10.0/24, VMnet21=172.22.20.0/24, VMnet22=172.22.30.0/24, VMnet23=172.22.40.0/24, VMnet8=NAT (configure with `scripts/configure-vmnet.ps1`, verify with `scripts/verify-networking.ps1`)

**Repo:**

    git clone <repo-url> E:\SOC-9000\SOC-9000
    cd E:\SOC-9000\SOC-9000
    Copy-Item .env.example .env # edit .env

**Bring up everything (will pause for pfSense):**

    pwsh -File .\scripts\lab-up.ps1

**pfSense (manual):** Create VM → 5 NICs (WAN=VMnet8, MGMT=VMnet20, SOC=VMnet21, VICTIM=VMnet22, RED=VMnet23) → Install → Reboot → Console **14) Enable SSH** → back to PowerShell, press **Enter**.

**URLs:**  
Portainer `https://portainer.lab.local:9443`  
Wazuh `https://wazuh.lab.local`  
TheHive `https://thehive.lab.local`  
Cortex `https://cortex.lab.local`  
CALDERA `https://caldera.lab.local`  
DVWA `https://dvwa.lab.local`  
Nessus `https://nessus.lab.local:8834`  
*(If names fail: run `scripts/hosts-refresh.ps1` as Admin.)*

**TheHive↔Cortex:** in TheHive → Admin → Cortex → add `http://cortex.soc.svc:9001` + Cortex API key.

**Telemetry check (Wazuh):** Agents show **containerhost** & **victim-win**; search `log.file.path:/var/log/pfsense/pfsense.log`.

**Daily:**
- Kali shell: `kubectl -n red exec -it deploy/kali-cli -- bash`
- Backup: `pwsh -File scripts/backup-run.ps1`
- Reset: `pwsh -File scripts/reset-lab.ps1` (add `-Hard` for full reset)
- Stop VMs: `pwsh -File scripts/lab-down.ps1`
