# ISO Download Instructions

This document explains how to obtain the third‑party ISO images and packages
needed by the SOC‑9000 lab installer.  Some vendors require you to sign in or
register for access, and file names may differ from the defaults used by the
automation.  Follow the guidance below to ensure that the installer can find
your downloads.

## Ubuntu Server

The installer automatically downloads the Ubuntu 22.04 server ISO from
Canonical’s website.  No manual action is required unless your network blocks
the download, in which case you may obtain the ISO from
<https://releases.ubuntu.com/jammy/> and place it into your `ISO_DIR` as
`ubuntu-22.04.iso`.

## pfSense CE

pfSense downloads are hosted by Netgate and require you to log in with a
Netgate account before you can access the file.  You can register with a
temporary (burner) email address if you do not wish to associate your primary
identity.  After logging in:

1. Navigate to <https://www.pfsense.org/download/>.
2. Select the **pfSense CE** version and architecture (e.g. `amd64` installer).
3. Choose a mirror close to your location and download the ISO.
4. Save the file into your `ISO_DIR` as **`pfsense.iso`** (rename if needed).

If automatic downloading fails, the installer will open the download page for
you and pause.  Place the ISO into the `isos` directory and then resume the
installation.

## Windows 11 ISO

Windows 11 evaluation ISOs expire periodically and require you to accept
Microsoft’s license terms.  The installer attempts to download a valid
evaluation ISO only if you supply a non‑expiring URL via the `-Win11Url`
parameter.  For most users, the recommended approach is to download an
official Windows 11 ISO manually:

1. Visit the Microsoft Evaluation Center at
   <https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise>.
2. Sign in with your Microsoft account and select the **Windows 11
   Enterprise** edition you require (for example, "Windows 11 EnglishInternational x64").
3. Download the ISO.  The file name may differ from the default
   `win11-eval.iso`, for example `Win11_23H2_EnglishInternational_x64.iso`.
4. Copy or rename the file into your `ISO_DIR`.  The installer will attempt to
   detect any ISO whose name contains "win" and "11" automatically.  If
   multiple Windows 11 ISOs exist, rename the one you intend to use to
   `win11-eval.iso` for clarity.

## Nessus Essentials

Tenable requires you to register for a free Nessus Essentials activation key
before downloading the installation package.  Use a disposable email address
if desired.  To download the `.deb` package for Ubuntu:

1. Go to <https://www.tenable.com/products/nessus/nessus-essentials> and
   complete the registration form to receive an activation key.
2. Follow the download link provided after registration and select the Linux
   (Ubuntu/Debian) installer.
3. Save the file into your `ISO_DIR` as **`nessus_latest_amd64.deb`** (rename
   the file if the vendor uses a versioned name).

## Summary

- Place all downloaded files into the directory specified by the `ISO_DIR`
  environment variable (default: `E:\\SOC-9000-Pre-Install\\isos`).
- Ensure the file names match those expected by the installer (`pfsense.iso`,
  `win11-eval.iso`, and `nessus_latest_amd64.deb`).  The installer will
  automatically detect Windows 11 ISOs with other names, but renaming to the
  expected name avoids ambiguity.
- After downloading and copying the files, re‑run the installer with the
  `-SkipPrereqs` option to continue the lab bring‑up.