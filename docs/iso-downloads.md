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
4. Download the matching **SHA256 checksum** file from the mirror and save it alongside the ISO.
5. Save both files into your `ISO_DIR`. The installer automatically detects any pfSense ISO file name and verifies it against the checksum when present.

If automatic downloading fails, the installer will open the download page for
you and pause.  Place the ISO into the `isos` directory and then resume the
installation.

## Windows 11 ISO

Windows 11 evaluation ISOs expire periodically and require you to accept
Microsoft’s license terms.  The installer attempts to download a valid
evaluation ISO only if you supply a non‑expiring URL via the `-Win11Url`
parameter.  For most users, the recommended approach is to download an
official Windows 11 ISO manually:

1. Navigate to the Microsoft Windows 11 download page at
   <https://www.microsoft.com/de-de/software-download/windows11>.
2. Under **Download Windows 11 Disk Image (ISO)**, select **Windows 11** and
   choose your preferred language (e.g. **English International**) for the x64
   architecture.
3. After you click **Download**, the page will generate a unique URL valid for
   24 hours.  Sign in with your Microsoft account if prompted.
4. Download the ISO **and the vendor-provided SHA256 checksum** (if available).
   The ISO file name may differ from the default `win11-eval.iso`, for example `Win11_23H2_EnglishInternational_x64.iso`.
5. Copy the ISO and its checksum into your `ISO_DIR`. The installer detects any ISO whose name contains "win" and "11" automatically. If multiple Windows 11 ISOs exist, remove the extras or rename the one you intend to use for clarity.

## Nessus Essentials

Tenable requires you to register for a free Nessus Essentials activation key
before downloading the installation package.  Use a disposable (burner) email
address if you prefer not to receive marketing emails.  To download the
`.deb` package for Ubuntu:

1. Visit <https://www.tenable.com/products/nessus/nessus-essentials> and fill
   out the registration form to obtain an activation key.  A burner email
   address can be used.
2. After registration, follow the download link provided and select the Linux
   (Ubuntu/Debian) installer.
3. Download the `.deb` **and the associated SHA256 checksum** from Tenable.
4. Save both files into your `ISO_DIR`. The installer automatically detects Nessus packages that include `amd64` in the name and verifies them when a checksum is present.

## Summary

- Place all downloaded files into the directory specified by the `ISO_DIR`
  environment variable (default: `E:\\SOC-9000-Pre-Install\\isos`).
- The installer automatically detects pfSense, Windows 11, and Nessus files based on their content; renaming is optional. If checksum files (`*.sha256`) are present, they are used for verification.
- After downloading and copying the files, re‑run the installer with the
  `-SkipPrereqs` option to continue the lab bring‑up.