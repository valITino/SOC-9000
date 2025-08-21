#!/usr/bin/env bash
set -euo pipefail

# Basic health info in the Packer console
echo "=== OS info ==="
uname -a
. /etc/os-release
echo "ID=$ID VERSION_ID=$VERSION_ID"

# Ensure cloud-init finalised + SSH agent is enabled
systemctl is-active --quiet cloud-init || true
systemctl enable --now ssh

# Make sure open-vm-tools/qemu-guest-agent are running
systemctl enable --now open-vm-tools.service || true
systemctl enable --now qemu-guest-agent.service || true

# Trim apt cache to shrink artifact
apt-get -y autoremove || true
apt-get -y clean || true
rm -rf /var/lib/apt/lists/* || true

echo "postinstall complete."
