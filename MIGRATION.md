# SOC-9000 Refactoring Migration Guide

**Version:** 1.0.0
**Date:** 2025-10-04

---

## Overview

The SOC-9000 codebase has been refactored from a script-heavy architecture to a **modular, maintainable structure** with a single orchestrator script. This document explains what changed, how to migrate, and compatibility notes.

---

## What Changed

### 🔄 **Before → After Mapping**

| **Old Location** | **New Location** | **Status** |
|---|---|---|
| `scripts/setup-soc9000.ps1` | `./setup-soc9000.ps1` (repo root) | ✅ Replaced with new orchestrator |
| `scripts/build-packer.ps1` | `./ubuntu-build.ps1` + `legacy/build-packer.ps1` (shim) | ✅ Split + Shim |
| `scripts/windows-build.ps1` | `./windows-build.ps1` (moved to root) | ✅ Moved |
| *(new)* | `./nessus-build.ps1` | ✅ New builder |
| *(new)* | `./pfsense-build.ps1` | ✅ New builder |
| *(inline functions)* | `modules/SOC9000.Utils.psm1` | ✅ Extracted to module |
| *(inline functions)* | `modules/SOC9000.Build.psm1` | ✅ Extracted to module |
| *(inline functions)* | `modules/SOC9000.Platform.psm1` | ✅ Extracted to module |
| *(scattered config)* | `config/soc9000.config.psd1` | ✅ Centralized config |

---

## New Structure

```
SOC-9000/
│
├── setup-soc9000.ps1          # 🆕 Main orchestrator (interactive + CLI)
├── ubuntu-build.ps1            # 🆕 Ubuntu VM builder (extracted from build-packer)
├── windows-build.ps1           # ✅ Windows VM builder (moved from scripts/)
├── nessus-build.ps1            # 🆕 Nessus VM builder
├── pfsense-build.ps1           # 🆕 pfSense VM builder
│
├── modules/                    # 🆕 PowerShell modules
│   ├── SOC9000.Utils.psm1      # Logging, validation, paths, retries
│   ├── SOC9000.Build.psm1      # Packer/VMware build helpers
│   └── SOC9000.Platform.psm1   # OS checks, prereqs, tool installers
│
├── config/                     # 🆕 Central configuration
│   └── soc9000.config.psd1     # Paths, versions, network, tools
│
├── legacy/                     # 🆕 Compatibility shims
│   └── build-packer.ps1        # Deprecation shim → calls ubuntu-build.ps1
│
├── scripts/                    # 🧹 Cleaned up helpers only
│   ├── install-prereqs.ps1     # (kept, unchanged)
│   ├── download-isos.ps1       # (kept, unchanged)
│   ├── configure-vmnet.ps1     # (kept, unchanged)
│   ├── verify-networking.ps1   # (kept, unchanged)
│   ├── wsl-prepare.ps1         # (kept, unchanged)
│   ├── wsl-init-user.ps1       # (kept, unchanged)
│   └── ... (other existing scripts remain)
│
├── tests/                      # 🆕 Pester tests
│   ├── SOC9000.Utils.Tests.ps1
│   ├── SOC9000.Build.Tests.ps1
│   └── SOC9000.Platform.Tests.ps1
│
└── .env                        # (unchanged - still used for overrides)
```

---

## How to Migrate

### ✅ **For End Users (Running Setup)**

**Old way:**
```powershell
cd scripts
.\setup-soc9000.ps1
```

**New way:**
```powershell
# From repo root
.\setup-soc9000.ps1 -All -Verbose
```

**What's new:**
- 🎯 **Interactive menu** (just run `.\setup-soc9000.ps1`)
- 🚀 **Selective builds**: `-Ubuntu`, `-Windows`, `-Nessus`, `-PfSense`
- 🔍 **Better UX**: Numbered steps, progress bars, friendly errors
- 📝 **Consistent logging**: All logs in `E:\SOC-9000-Install\logs` (or `C:\` if no E:)

### ✅ **For Developers (Building Individual VMs)**

#### Ubuntu Build

**Old way:**
```powershell
cd scripts
.\build-packer.ps1 -Only ubuntu -Headless
```

**New way:**
```powershell
# From repo root
.\ubuntu-build.ps1 -Verbose

# OR use orchestrator
.\setup-soc9000.ps1 -Ubuntu -Verbose
```

#### Windows Build

**Old way:**
```powershell
cd scripts
.\windows-build.ps1
```

**New way:**
```powershell
# From repo root
.\windows-build.ps1 -Verbose

# OR use orchestrator
.\setup-soc9000.ps1 -Windows -Verbose
```

#### Nessus Build (New!)

```powershell
.\nessus-build.ps1 -Verbose

# OR
.\setup-soc9000.ps1 -Nessus -Verbose
```

#### pfSense Build (New!)

```powershell
.\pfsense-build.ps1 -Verbose

# OR
.\setup-soc9000.ps1 -PfSense -Verbose
```

---

## Compatibility Shims

### 🛡️ **Legacy `build-packer.ps1` Still Works**

For backwards compatibility, `legacy/build-packer.ps1` is a shim that:

1. **Prints a deprecation warning**
2. **Maps old parameters to new scripts**:
   - `-Only ubuntu` → calls `.\ubuntu-build.ps1`
   - `-Only windows` → calls `.\windows-build.ps1`
3. **Exits cleanly**

**Example:**
```powershell
# This still works (with a warning):
cd scripts
.\build-packer.ps1 -Only ubuntu -Headless
# ⚠️ [DEPRECATED] build-packer.ps1 is deprecated. Use ./ubuntu-build.ps1 instead.
# (then runs the new script)
```

---

## Breaking Changes

### ⚠️ **None (Intentional Design)**

All existing workflows are preserved via:
- **Shims** for old entry points
- **Parameter compatibility** (same flags work)
- **Same output locations** (VMs, logs, artifacts)

### 🔧 **Minor Adjustments**

1. **PowerShell 7.2+ Required**: Scripts now use `#requires -Version 7.2`
2. **Module Import**: If calling functions directly, import modules:
   ```powershell
   Import-Module .\modules\SOC9000.Utils.psm1
   ```
3. **Config Overrides**: Centralized in `config/soc9000.config.psd1` (`.env` still works)

---

## New Features

### 🎉 **Interactive Setup Menu**

Run without arguments:
```powershell
.\setup-soc9000.ps1
```

You'll see:
```
===========================================================================
  >> SOC-9000 Lab Setup Orchestrator
===========================================================================

What would you like to build?

  [1] Build All (Ubuntu + Windows + Nessus + pfSense)
  [2] Build Ubuntu only
  [3] Build Windows only
  [4] Build Nessus only
  [5] Build pfSense only
  [6] Prerequisites check only
  [Q] Quit

Choose an option:
```

### 🚀 **Noninteractive CLI**

```powershell
# Build everything
.\setup-soc9000.ps1 -All -Verbose

# Build selectively
.\setup-soc9000.ps1 -Ubuntu -Windows -Verbose

# Check prereqs only
.\setup-soc9000.ps1 -PrereqsOnly

# Dry-run (WhatIf)
.\setup-soc9000.ps1 -All -WhatIf

# Force rebuild (no prompts)
.\setup-soc9000.ps1 -All -Force -NonInteractive
```

### 📊 **Progress Tracking**

- **Step numbering**: "Step 3/7: Build Ubuntu image"
- **Progress bars**: For long Packer builds
- **Real-time logs**: Tailed to console every 20s
- **Exit codes**: `0` = success, `1` = error, `2` = reboot required, `3` = user abort

### 🧪 **Testing**

Run basic smoke tests:
```powershell
Invoke-Pester .\tests\
```

---

## Configuration Management

### 🔧 **Priority Order** (highest to lowest):

1. **Command-line parameters**: `.\setup-soc9000.ps1 -IsoDir 'D:\ISOs'`
2. **Environment variables**: `$env:ISO_DIR = 'D:\ISOs'`
3. **`.env` file**: `ISO_DIR=D:\ISOs`
4. **`config/soc9000.config.psd1`**: Default paths and settings
5. **Hard-coded fallbacks**: `E:\SOC-9000-Install` or `C:\SOC-9000-Install`

### 📝 **Example `.env`** (unchanged):
```
ISO_DIR=E:\SOC-9000-Install\isos
INSTALL_ROOT=E:\SOC-9000-Install
UBUNTU_USERNAME=labadmin
VMNET8_HOSTIP=192.168.8.1
VMNET2_HOSTIP=192.168.2.1
```

---

## Troubleshooting

### ❓ **"setup-soc9000.ps1 not found"**

**Fix**: You're in the wrong directory. Run from **repo root**:
```powershell
cd C:\path\to\SOC-9000
.\setup-soc9000.ps1
```

### ❓ **"Module not found"**

**Fix**: Modules are in `./modules/`. Import manually if needed:
```powershell
Import-Module .\modules\SOC9000.Utils.psm1 -Force
```

### ❓ **"Legacy script still in scripts/"**

**Answer**: Intentional! `scripts/setup-soc9000.ps1` is the **old version**. The new one is at **repo root**: `.\setup-soc9000.ps1`

### ❓ **"I want the old behavior back"**

**Fix**: Use the shim:
```powershell
.\legacy\build-packer.ps1 -Only ubuntu -Headless
```

---

## Testing the Migration

### ✅ **Validation Steps**

1. **Run full setup**:
   ```powershell
   .\setup-soc9000.ps1 -All -Verbose
   ```
   - Should produce same artifacts as before
   - Check: `E:\SOC-9000-Install\VMs\Ubuntu\*.vmx`
   - Check: `E:\SOC-9000-Install\VMs\Windows\*.vmx`

2. **Run individual builders**:
   ```powershell
   .\ubuntu-build.ps1 -Verbose
   .\windows-build.ps1 -Verbose
   ```

3. **Test shim**:
   ```powershell
   .\legacy\build-packer.ps1 -Only ubuntu -Headless
   # Should print deprecation warning and work
   ```

4. **Run tests**:
   ```powershell
   Invoke-Pester .\tests\ -Output Detailed
   ```

---

## Rollback Plan

If you need to revert:

1. **Checkout previous commit**:
   ```powershell
   git checkout <previous-commit-hash>
   ```

2. **Or keep both versions**:
   - Old scripts still in `scripts/`
   - New structure in repo root
   - Use whichever works for your workflow

---

## Support

**Questions or Issues?**

1. Check this migration guide
2. Review `README.md` for updated examples
3. Inspect `config/soc9000.config.psd1` for defaults
4. Run `Get-Help .\setup-soc9000.ps1 -Full` for parameter docs
5. Open an issue on GitHub

---

## Checklist for Developers

- [ ] Read this migration guide
- [ ] Update any CI/CD pipelines to use new entry points
- [ ] Test new orchestrator: `.\setup-soc9000.ps1 -All -Verbose`
- [ ] Test individual builders: `.\ubuntu-build.ps1`, `.\windows-build.ps1`
- [ ] Run Pester tests: `Invoke-Pester .\tests\`
- [ ] Update any documentation referencing old paths
- [ ] Verify `.env` file still works as expected
- [ ] Confirm artifacts are in same locations as before

---

**End of Migration Guide**
