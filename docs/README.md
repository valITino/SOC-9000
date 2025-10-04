# SOC-9000 Documentation

Comprehensive documentation for the SOC-9000 automated lab environment.

---

## Quick Links

### Getting Started
- **[Beginner's Guide](BEGINNER-GUIDE.md)** - Start here if you're new to SOC-9000
- **[Prerequisites](00-prereqs.md)** - System requirements and tool installation
- **[Quick Start (Printable)](quickstart-printable.md)** - One-page quick reference

### Build & Deploy
- **[Packer Builds](02-packer.md)** - VM image creation with Packer
- **[pfSense & k3s](03-pfsense-and-k3s.md)** - Network firewall and Kubernetes setup
- **[Platform & Apps](04-platform-and-apps.md)** - Core platform deployment

### SOC Applications
- **[Wazuh](05-wazuh.md)** - SIEM and security monitoring
- **[TheHive & Cortex](06-thehive-cortex.md)** - Incident response and analysis
- **[Nessus](07-nessus.md)** - Vulnerability scanning (container)
- **[Nessus VM](07B-nessus-vm.md)** - Vulnerability scanning (VM)
- **[Atomic & CALDERA](08-atomic-caldera-wazuh.md)** - Adversary emulation

### Operations
- **[Orchestration](09-orchestration.md)** - End-to-end automation
- **[Backup & Reset](10-backup-reset.md)** - Lab maintenance

### Reference
- **[Networking](NETWORKING.md)** - Network topology and configuration
- **[ISO Downloads](iso-downloads.md)** - Where to get required ISOs
- **[Releases](releases.md)** - Version history and release process

---

## Documentation Structure

```
docs/
├── README.md                    # This file - documentation index
├── BEGINNER-GUIDE.md            # Comprehensive beginner's guide
├── quickstart-printable.md      # One-page quick reference
│
├── 00-prereqs.md                # Prerequisites and setup
├── 01-orchestration.md          # (Legacy) Initial setup
├── 02-packer.md                 # VM builds with Packer
├── 03-pfsense-and-k3s.md        # pfSense and Kubernetes
├── 04-platform-and-apps.md      # Platform deployment
├── 05-wazuh.md                  # Wazuh SIEM
├── 06-thehive-cortex.md         # TheHive & Cortex
├── 07-nessus.md                 # Nessus container
├── 07B-nessus-vm.md             # Nessus VM
├── 08-atomic-caldera-wazuh.md   # Adversary emulation
├── 09-orchestration.md          # Full automation
├── 10-backup-reset.md           # Maintenance
│
├── NETWORKING.md                # Network details
├── iso-downloads.md             # ISO sources
├── pfsense-install-cheatsheet.md # (Legacy) Manual pfSense install
├── overview.md                  # (Legacy) Project overview
└── releases.md                  # Release management
```

---

## Recommended Reading Order

### For First-Time Users
1. [BEGINNER-GUIDE.md](BEGINNER-GUIDE.md)
2. [00-prereqs.md](00-prereqs.md)
3. [quickstart-printable.md](quickstart-printable.md)
4. Run `.\setup-soc9000.ps1 -All`

### For Advanced Users
1. [02-packer.md](02-packer.md) - Understand VM builds
2. [03-pfsense-and-k3s.md](03-pfsense-and-k3s.md) - Network and platform
3. [09-orchestration.md](09-orchestration.md) - Full automation
4. Application-specific docs (05-08)

### For Developers
- Main README.md (repo root) - Development workflow
- MIGRATION.md (repo root) - Architecture changes
- REFACTORING-SUMMARY.md (repo root) - Modularization details
- AUTOMATION-COMPLETE.md (repo root) - Automation implementation

---

## Getting Help

1. **Check documentation** - Most questions are answered in the guides above
2. **Review logs** - Check `E:\SOC-9000-Install\logs\` for build/deployment logs
3. **Run validation** - Use `.\build.ps1` to validate your environment
4. **GitHub Issues** - Report bugs or request features

---

**Last Updated:** 2025-10-04
**Documentation Version:** 1.2.0
