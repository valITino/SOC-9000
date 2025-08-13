# SOC-9000 Beginner Install Guide — Windows 11 + VMware Workstation

Welcome! This guide walks you through setting up the SOC‑9000 lab from scratch on a Windows 11 host.  It assumes you have little or no prior experience with Git, PowerShell, Kubernetes, or SOC labs.  Follow each step carefully and you’ll have a full‑featured security operations centre running locally.

---

## 1. What you will get

SOC‑9000 builds a miniature SOC environment with the following services and tools:

- **pfSense** – firewall and router
- **k3s** – lightweight Kubernetes
- **Traefik** – reverse proxy with TLS termination
- **MetalLB** – load balancer for k3s
- **Portainer** – GUI for managing Kubernetes
- **Wazuh** – SIEM/EDR
- **TheHive & Cortex** – incident response platform and analyzers
- **CALDERA** – adversary emulation framework
- **DVWA** – Damn Vulnerable Web App (target)
- **(Optional) Nessus** – vulnerability scanner

You’ll run everything locally on VMware Workstation.  pfSense routes traffic between four lab segments (MGMT, SOC, VICTIM, RED) and the host.  Traefik exposes all services on friendly hostnames with HTTPS.

---

## 2. Minimum requirements

| Item                | Minimum      | Recommended |
|---------------------|-------------:|-----------:|
| Windows             | 11 Pro       | 11 Pro     |
| VMware Workstation | 17.x         | 17.x       |
| CPU                 | 8 cores      | 12+ cores  |
| RAM                 | 24 GB        | 32–48 GB   |
| Free disk space     | 120 GB       | 200+ GB    |

You need enough CPU and memory to run several VMs concurrently.  More is always better.

---

## 3. Automatically download required images

The lab requires several OS images that are **not** stored in this repository.  A helper script is provided to download them for you:

- **Ubuntu 22.04 ISO** – base for ContainerHost and WSL
- **Windows 11 ISO** – base for the victim VM
- **pfSense ISO** – firewall/router installer
- **Nessus Essentials (.deb)** – optional for the Nessus VM path

To fetch the images:

1. Open **PowerShell as Administrator** and navigate to your cloned repo:
   ```powershell
   cd E:\SOC-9000\SOC-9000
   ```
2. Run the download script:
   ```powershell
   pwsh -File .\scripts\download-isos.ps1
   ```

The script checks your `isos` folder (`E:\SOC-9000\isos` by default), downloads Ubuntu automatically if it is missing, and opens vendor pages for pfSense, Windows 11, and Nessus so you can download them manually. pfSense and Nessus require free accounts; a burner email works fine. You can keep the original file names—the installer detects them automatically. If you prefer to supply your own files, place them in the folder and the script will skip them.

### One‑click installer

If you’d rather avoid manual cloning and setup, you can use the standalone installer.  This PowerShell script separates **where the repo lives** from **where downloads and build artifacts live**.  By default it clones the repository into `E:\SOC-9000` and downloads the required images into `E:\SOC-9000-Pre-Install`.  It then updates configuration paths and runs the full bring‑up.  You can override either location via parameters:

```powershell
# use defaults: repo in E:\SOC-9000 and ISOs/artifacts in E:\SOC-9000-Pre-Install
pwsh -File .\scripts\standalone-installer.ps1

# customise the install directory (where ISOs, artifacts and temp files live)
pwsh -File .\scripts\standalone-installer.ps1 -InstallDir "D:\Labs\SOC-9000-Pre-Install"

# customise both repo location and install location
pwsh -File .\scripts\standalone-installer.ps1 -RepoDir "D:\SOC-9000" -InstallDir "D:\Labs\SOC-9000-Pre-Install"
```

You can also build a self-contained installer script with embedded prerequisites using the build script:

```powershell
pwsh -File .\scripts\build-installer.ps1
# This produces SOC-9000-installer.ps1 in the repo root.  Run it with PowerShell to start.
```

---

## 4. Install required software

1. Still in **PowerShell as Administrator**, install Git, Packer, kubectl, Helm, OpenSSL and WSL:

   ```powershell
   winget install -e Git.Git HashiCorp.Packer Kubernetes.kubectl Helm.Helm OpenSSL.Win64
   wsl --install -d Ubuntu-22.04
   ```

2. Install the lab prerequisites (**Git** and **PowerShell 7**).  A helper script is provided to detect and install these tools via winget:

   ```powershell
   cd E:\SOC-9000\SOC-9000
   pwsh -File .\scripts\install-prereqs.ps1
   ```

   This step ensures that both Git and PowerShell 7 are available before you attempt to build the standalone installer or use other scripts.  If the tools are already installed, the script skips them.

3. After WSL installs, launch **Ubuntu 22.04** from the Start menu and run:

   ```bash
   sudo apt update && sudo apt -y install ansible git jq curl
   ```

---

## 5. Prepare lab folders

Create the folder structure that SOC‑9000 expects.  In **PowerShell**:

```powershell
New-Item -ItemType Directory E:\SOC-9000\isos,E:\SOC-9000\artifacts,E:\SOC-9000\temp -Force | Out-Null
```

The download script from step 3 will place your ISO files in `E:\SOC-9000\isos`.  `artifacts` and `temp` hold VM images and temporary build files.

---

## 6. Clone the repository and initialize

```powershell
git clone https://github.com/valITino/SOC-9000.git E:\SOC-9000\SOC-9000
cd E:\SOC-9000\SOC-9000
Copy-Item .env.example .env
```

The `init` target copies `.env.example` to `.env`.  Open `.env` in Notepad, adjust the ISO paths and network names if needed, and save it.

---

## 7. Verify VMware host‑only networks

Run `pwsh -File .\scripts\host-prepare.ps1` to auto-create the required VMnets (uses `vmnetcfgcli.exe`). After it completes, open **VMware Workstation → Edit → Virtual Network Editor** and confirm the following networks exist:

   - `VMnet20` → 172.22.10.0/24 (MGMT)
   - `VMnet21` → 172.22.20.0/24 (SOC)
   - `VMnet22` → 172.22.30.0/24 (VICTIM)
   - `VMnet23` → 172.22.40.0/24 (RED)
   - `VMnet8` remains NAT (WAN)

If a network is still missing, create it manually with DHCP disabled.

---

## 8. Bring up the entire lab

Run one command to build and start everything:

```powershell
pwsh -File .\scripts\lab-up.ps1
```

`lab-up.ps1` orchestrates all the steps: host preparation, Packer image builds, VM network wiring, netplan application, automatic pfSense configuration, TLS generation, platform bootstrapping, app deployments, and telemetry setup.  It pauses once for you to perform the basic pfSense install.  Follow the on‑screen prompts during that pause, then press **Enter** to continue.

---

## 9. Access your services

Once deployment finishes, open your browser and visit:

- **Portainer:** <https://portainer.lab.local:9443>
- **Wazuh:** <https://wazuh.lab.local>
- **TheHive:** <https://thehive.lab.local>
- **Cortex:** <https://cortex.lab.local>
- **CALDERA:** <https://caldera.lab.local>
- **DVWA:** <https://dvwa.lab.local>
- **Nessus:** <https://nessus.lab.local:8834> (if enabled)

If your host file isn’t updated yet, run:

```powershell
pwsh -File .\scripts\hosts-refresh.ps1
```

---

## 10. Test your installation

You can perform a quick smoke test to ensure all URLs respond:

```powershell
pwsh -File .\scripts\smoke-test.ps1
```

The script sends HTTP `HEAD` requests to each service and reports the status codes.

---

## 11. Reset or back up your lab

- **Soft reset (purge apps):**
  ```powershell
  pwsh -File .\scripts\reset-lab.ps1
  ```
- **Hard reset (also wipes data):**
  ```powershell
  pwsh -File .\scripts\reset-lab.ps1 -Hard
  ```
- **Backup:**
  ```powershell
  pwsh -File .\scripts\backup-run.ps1
  ```

Backups are stored under `E:\SOC-9000\backups` and contain cluster manifests, secrets lists (names/types only), and persistent volume data.

---

## 12. Appendices and troubleshooting

For detailed instructions on pfSense installation, platform apps, Wazuh, TheHive/Cortex, Nessus, CALDERA, and more, refer to the individual docs in the `docs/` folder:

- `00-prereqs.md` – prerequisites, host setup
- `03-pfsense-and-k3s.md` – pfSense install and k3s deployment
- `04-platform-and-apps.md` – Traefik, Portainer, base apps
- `05-wazuh.md` – Wazuh deployment
- `06-thehive-cortex.md` – TheHive and Cortex integration
- `07-nessus.md` / `07B-nessus-vm.md` – Nessus container/VM options
- `08-atomic-caldera-wazuh.md` – telemetry and adversary emulation
- `09-orchestration.md` – how the orchestration script works
- `10-backup-reset.md` – backup and reset commands

If you encounter errors, review the troubleshooting section of `09-orchestration.md`, run `pwsh -File .\scripts\hosts-refresh.ps1`, or inspect the logs in `E:\SOC-9000\temp`.

---

## Happy labbing!

You’re now ready to explore threat detection, incident response, adversary emulation, and vulnerability assessment in your own SOC‑9000 lab.  Feel free to modify and extend the environment to suit your needs.  Pull requests and contributions are welcome!
