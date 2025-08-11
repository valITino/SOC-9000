#!/usr/bin/env bash
set -euxo pipefail
echo "labadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-labadmin >/dev/null
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
sudo timedatectl set-timezone Europe/Zurich || true
sudo systemctl enable --now ssh
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh
sudo touch /etc/soc-9000.nessus.built
