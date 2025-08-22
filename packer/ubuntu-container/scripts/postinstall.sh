#!/usr/bin/env bash
set -euo pipefail

log() { printf '%s %s\n' "[-]" "$*"; }
ok()  { printf '%s %s\n' "[OK]" "$*"; }

# Basic health info in the Packer console
echo "=== OS info ==="
uname -a
. /etc/os-release || true
echo "ID=${ID:-unknown} VERSION_ID=${VERSION_ID:-unknown}"

# 1) Wait for cloud-init to actually finish (more reliable than is-active)
if command -v cloud-init >/dev/null 2>&1; then
  log "Waiting for cloud-init to finish..."
  if cloud-init status --wait; then ok "cloud-init complete"; else log "cloud-init wait returned non-zero (continuing)"; fi
fi

# 2) Ensure SSH + guest agents
log "Enabling SSH and guest agents..."
systemctl enable --now ssh || true
systemctl enable --now open-vm-tools.service || true
systemctl enable --now qemu-guest-agent.service || true
ok "Services enabled (where present)"

# 3) Package/cache cleanup
export DEBIAN_FRONTEND=noninteractive
log "Cleaning apt caches and autoremove..."
apt-get -y autoremove --purge || true
apt-get -y clean || true
rm -rf /var/lib/apt/lists/* || true

# 4) Journal/log vacuum (keeps today’s tiny crumbs)
log "Vacuuming journals..."
journalctl --rotate || true
journalctl --vacuum-time=1s || true
find /var/log -type f -name "*.gz" -delete || true

# 5) Trim free space (helps shrink VMDK)
log "Running fstrim..."
fstrim -av || true

echo "postinstall complete."