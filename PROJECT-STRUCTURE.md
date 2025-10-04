# SOC-9000 Project Structure

Clean, organized, professional repository structure for the SOC-9000 automated cybersecurity lab.

---

## Repository Layout

```
SOC-9000/
│
├── README.md                       # Project overview and quick start
├── CHANGELOG.md                    # Version history (v1.0.0 → v1.3.0)
├── MIGRATION.md                    # Migration guide for older versions
├── PROJECT-STRUCTURE.md            # This file - repo organization
│
├── build.ps1                       # Build helper (linting + testing)
├── deploy.ps1                      # Deployment helper (validation)
│
├── setup-soc9000.ps1              # Main orchestrator (interactive/CLI)
├── ubuntu-build.ps1                # Ubuntu container host builder
├── windows-build.ps1               # Windows 11 victim builder
├── nessus-build.ps1                # Nessus VM builder (automated)
├── pfsense-build.ps1               # pfSense VM builder (automated)
│
├── .gitignore                      # Comprehensive ignore rules (94 lines)
├── .markdownlint.json              # Markdown linting configuration
├── PSScriptAnalyzerSettings.psd1   # PowerShell code quality rules
│
├── .env.example                    # Environment configuration template
│
├── modules/                        # PowerShell modules (reusable code)
│   ├── SOC9000.Utils.psm1          # Logging, validation, paths
│   ├── SOC9000.Utils.psd1          # Module manifest
│   ├── SOC9000.Build.psm1          # Packer/VMware helpers
│   ├── SOC9000.Build.psd1          # Module manifest
│   ├── SOC9000.Platform.psm1       # OS checks, prerequisites
│   └── SOC9000.Platform.psd1       # Module manifest
│
├── config/                         # Centralized configuration
│   └── soc9000.config.psd1         # Paths, versions, settings
│
├── scripts/                        # Organized scripts (35 total)
│   ├── setup/                      # Setup scripts (7 files)
│   │   ├── install-prereqs.ps1     # Install PowerShell, Packer, etc.
│   │   ├── download-isos.ps1       # Download Ubuntu, open vendor pages
│   │   ├── configure-vmnet.ps1     # Create VMware networks
│   │   ├── generate-vmnet-profile.ps1  # Generate vnetlib import file
│   │   ├── wsl-prepare.ps1         # Enable WSL features
│   │   ├── wsl-init-user.ps1       # Configure WSL Ubuntu
│   │   └── copy-ssh-key-to-wsl.ps1 # SSH key management
│   │
│   ├── build/                      # Build scripts (3 files)
│   │   ├── nessus-vm-build-and-config.ps1  # (Legacy) Nessus VM
│   │   ├── full_iso-noprompt-autounattend.ps1  # Windows ISO prep
│   │   └── clean-packer-cache.ps1  # Clean Packer cache
│   │
│   ├── deploy/                     # Deployment scripts (11 files)
│   │   ├── apply-k8s.ps1           # Deploy Kubernetes apps
│   │   ├── wazuh-vendor-and-deploy.ps1  # Wazuh SIEM
│   │   ├── telemetry-bootstrap.ps1 # Telemetry agents
│   │   ├── bootstrap-traefik.ps1   # Traefik ingress
│   │   ├── expose-wazuh-manager.ps1  # Wazuh network config
│   │   ├── deploy-nessus-essentials.ps1  # Nessus container
│   │   ├── install-thehive-cortex.ps1  # TheHive + Cortex
│   │   ├── install-rwx-storage.ps1 # ReadWriteMany storage
│   │   ├── vmrun-lib.ps1           # VMware CLI helpers
│   │   ├── apply-containerhost-netplan.ps1  # Static IPs
│   │   └── wire-networks.ps1       # VMX network wiring
│   │
│   └── utils/                      # Utility scripts (14 files)
│       ├── lab-up.ps1              # End-to-end lab bring-up
│       ├── lab-down.ps1            # Shutdown all VMs
│       ├── lab-status.ps1          # Show lab status
│       ├── up.ps1                  # (Legacy) VM startup
│       ├── down.ps1                # (Legacy) VM shutdown
│       ├── reset-lab.ps1           # Reset lab to clean state
│       ├── uninstall-soc9000.ps1   # Uninstall lab
│       ├── smoke-test.ps1          # Validate environment
│       ├── verify-networking.ps1   # Check VMware networks
│       ├── hosts-refresh.ps1       # Update Windows hosts file
│       ├── hosts-add.ps1           # Add hosts entries
│       ├── backup-run.ps1          # Backup lab
│       ├── gen-ssl.ps1             # Generate SSL certificates
│       ├── storage-defaults-reset.ps1  # Reset storage
│       ├── package-release.ps1     # Package for distribution
│       └── vmnetdhcp-lease-delete.ps1  # Clean DHCP leases
│
├── legacy/                         # Backwards compatibility
│   └── build-packer.ps1            # Deprecation shim
│
├── packer/                         # Packer VM templates
│   ├── ubuntu-container/           # Ubuntu container host
│   │   ├── ubuntu-container.pkr.hcl
│   │   ├── http/                   # Cloud-init files
│   │   └── packer.auto.pkrvars.hcl.example
│   │
│   ├── windows-victim/             # Windows 11 victim
│   │   ├── windows.pkr.hcl
│   │   ├── autounattend.xml        # Automated Windows install
│   │   └── scripts/                # Provisioning scripts
│   │
│   ├── nessus-vm/                  # Nessus vulnerability scanner
│   │   ├── nessus.pkr.hcl
│   │   ├── http/                   # Cloud-init files
│   │   └── scripts/                # Nessus installation
│   │
│   └── pfsense/                    # pfSense firewall
│       └── pfsense.pkr.hcl         # Automated pfSense install
│
├── ansible/                        # Ansible playbooks
│   ├── inventory.ini               # Ansible inventory
│   ├── site.yml                    # Main playbook
│   ├── site-backup.yml             # Backup playbook
│   ├── site-nessus.yml             # Nessus playbook
│   ├── site-telemetry.yml          # Telemetry playbook
│   ├── group_vars/                 # Group variables
│   └── roles/                      # Ansible roles
│       ├── containerhost_k3s/      # k3s installation
│       ├── containerhost_rsyslog/  # Rsyslog config
│       ├── containerhost_wazuh_agent/  # Wazuh agent
│       ├── metallb/                # MetalLB load balancer
│       ├── nessus_vm/              # Nessus VM config
│       ├── pfsense_restore/        # pfSense config restore
│       ├── pfsense_syslog/         # pfSense syslog
│       ├── portainer/              # Portainer deployment
│       ├── windows_atomic/         # Atomic Red Team
│       ├── windows_caldera/        # CALDERA agent
│       └── windows_wazuh_agent/    # Wazuh Windows agent
│
├── k8s/                            # Kubernetes manifests
│   ├── apps/                       # Application deployments
│   │   ├── caldera/                # CALDERA
│   │   ├── cortex/                 # Cortex
│   │   ├── dvwa/                   # DVWA
│   │   ├── kali/                   # Kali Linux
│   │   ├── nessus/                 # Nessus (container)
│   │   ├── thehive/                # TheHive
│   │   └── wazuh/                  # Wazuh SIEM
│   │
│   └── platform/                   # Platform components
│       ├── metallb/                # Load balancer
│       ├── nfs-provisioner/        # NFS storage
│       └── traefik/                # Ingress controller
│
├── compose/                        # Docker Compose files
│   └── (optional Docker deployments)
│
├── tests/                          # Pester tests (7 files)
│   ├── SOC9000.Utils.Tests.ps1     # Utils module tests (17 tests)
│   ├── SOC9000.Build.Tests.ps1     # Build module tests (13 tests)
│   ├── SOC9000.Platform.Tests.ps1  # Platform module tests (9 tests)
│   ├── Integration.VMware.Tests.ps1  # VMware integration tests
│   ├── Unit.VMnetProfile.Tests.ps1 # VMnet profile tests
│   └── (other test files)
│
├── docs/                           # Documentation (18 files)
│   ├── README.md                   # Documentation index
│   ├── BEGINNER-GUIDE.md           # Comprehensive beginner's guide
│   ├── quickstart-printable.md     # One-page quick reference
│   │
│   ├── 00-prereqs.md               # Prerequisites and setup
│   ├── 02-packer.md                # Packer VM builds
│   ├── 03-pfsense-and-k3s.md       # pfSense and Kubernetes
│   ├── 04-platform-and-apps.md     # Platform deployment
│   ├── 05-wazuh.md                 # Wazuh SIEM
│   ├── 06-thehive-cortex.md        # TheHive & Cortex
│   ├── 07-nessus.md                # Nessus (container)
│   ├── 07B-nessus-vm.md            # Nessus (VM)
│   ├── 08-atomic-caldera-wazuh.md  # Adversary emulation
│   ├── 09-orchestration.md         # Full automation
│   ├── 10-backup-reset.md          # Maintenance
│   │
│   ├── NETWORKING.md               # Network topology
│   ├── iso-downloads.md            # ISO sources
│   └── releases.md                 # Release management
│
├── .claude/                        # Claude Code settings
│   └── settings.local.json
│
├── .github/                        # GitHub configuration
│   └── (workflows, issues, etc.)
│
└── .idea/                          # JetBrains IDE settings

```

---

## File Statistics

### PowerShell Code
- **Modules:** 3 files (.psm1) + 3 manifests (.psd1)
- **Builder Scripts:** 7 root-level scripts
- **Helper Scripts:** 35 scripts (organized in scripts/)
- **Legacy:** 1 deprecation shim
- **Tests:** 7 Pester test files (39 tests total)
- **Total:** 59 PowerShell files

### Documentation
- **Root:** 4 markdown files (README, CHANGELOG, MIGRATION, PROJECT-STRUCTURE)
- **Docs:** 18 markdown files (guides, references)
- **Total:** 22 markdown files (down from 25 in v1.2.0)

### Configuration
- **PowerShell:** soc9000.config.psd1, PSScriptAnalyzerSettings.psd1
- **Environment:** .env.example
- **Build:** Packer HCL templates (4 VMs)
- **Deployment:** Ansible playbooks, Kubernetes manifests

### Infrastructure as Code
- **Packer Templates:** 4 VMs (Ubuntu, Windows, Nessus, pfSense)
- **Ansible Playbooks:** 4 playbooks, 11 roles
- **Kubernetes Manifests:** 7 apps, 3 platform components

---

## Organization Principles

### 1. Separation of Concerns
- **Root-level builders** - VM creation (user-facing entry points)
- **modules/** - Reusable code (never called directly)
- **scripts/** - Organized by purpose (setup/build/deploy/utils)
- **config/** - Centralized settings
- **packer/** - VM templates (infrastructure as code)
- **ansible/** - Configuration management
- **k8s/** - Application deployment

### 2. Clear Naming Conventions
- **Builders:** `<component>-build.ps1` (ubuntu-build.ps1, windows-build.ps1)
- **Modules:** `SOC9000.<Purpose>.psm1` + `.psd1` manifest
- **Scripts:** `<verb>-<noun>.ps1` (install-prereqs.ps1, configure-vmnet.ps1)
- **Tests:** `<Module>.Tests.ps1` (SOC9000.Utils.Tests.ps1)

### 3. Logical Grouping
- **scripts/setup/** - One-time setup (prerequisites, ISOs, networks, WSL)
- **scripts/build/** - Build helpers (Nessus VM, ISO prep, cache cleanup)
- **scripts/deploy/** - Deployment automation (k8s, Wazuh, apps, networking)
- **scripts/utils/** - Operational tools (up/down, status, backups, SSL)

### 4. Documentation Hierarchy
- **README.md** - Quick start and overview
- **CHANGELOG.md** - Complete version history
- **docs/README.md** - Documentation index
- **docs/** - Detailed guides organized by topic

---

## Quick Navigation

### Getting Started
```powershell
.\setup-soc9000.ps1 -All -Verbose  # Build everything
```

### Development
```powershell
.\build.ps1                        # Lint + test
.\deploy.ps1 -ValidateOnly         # Validate environment
```

### Operations
```powershell
.\scripts\utils\lab-up.ps1         # Full deployment
.\scripts\utils\lab-status.ps1     # Check status
.\scripts\utils\lab-down.ps1       # Shutdown
```

### Maintenance
```powershell
.\scripts\utils\backup-run.ps1     # Backup
.\scripts\utils\reset-lab.ps1      # Reset
```

---

## Benefits of This Structure

✅ **Clear entry points** - Root-level builders for users
✅ **Organized scripts** - 4 categories instead of flat directory
✅ **Reusable code** - PowerShell modules for common functions
✅ **Professional** - Module manifests, tests, linting
✅ **Maintainable** - Separation of concerns
✅ **Discoverable** - Clear naming and documentation
✅ **Testable** - Comprehensive Pester tests
✅ **Scalable** - Easy to add new components

---

**Last Updated:** 2025-10-04
**Structure Version:** 1.3.0
