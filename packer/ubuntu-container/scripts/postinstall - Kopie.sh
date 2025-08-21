#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
umask 022

echo "[postinstall] packages, timezone, ssh hardening, guest agent"

# Ensure sudo without password for labadmin (matches cloud-init)
echo "labadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-labadmin >/dev/null
sudo chown root:root /etc/sudoers.d/99-labadmin
sudo chmod 0440 /etc/sudoers.d/99-labadmin
sudo visudo -cf /etc/sudoers >/dev/null

sudo apt-get update -y
sudo apt-get -y -o Dpkg::Options::="--force-confnew" dist-upgrade
sudo apt-get install -y qemu-guest-agent open-vm-tools ca-certificates curl

sudo timedatectl set-timezone Europe/Zurich || true

# SSH: keep password auth OFF (we use keys)
sudo systemctl enable --now ssh
sudo sed -ri 's/^\s*#?\s*PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -ri 's/^\s*#?\s*ChallengeResponseAuthentication\s+.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

sudo systemctl enable --now qemu-guest-agent || true

sudo apt-get autoremove -y
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

sudo touch /etc/soc-9000.containerhost.built
echo "[postinstall] done"