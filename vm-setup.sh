#!/usr/bin/env bash
# Run once as root on a fresh Ubuntu 26.04 LTS VM (Exoscale).
# Installs the authorised SSH key, hardens SSH, sets the firewall, and installs Docker.
# Usage: sudo bash vm-setup.sh
set -euo pipefail

APP_USER="ubuntu"

# ── SSH authorised key ─────────────────────────────────────────────────────────
# Install the project SSH key, replacing whatever Exoscale injected.

SSH_DIR="/home/${APP_USER}/.ssh"
mkdir -p "$SSH_DIR"
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCpeJ+3UiQuA0b9p0OdK/A7mtN8bQ3EdBpBlu3Txi0Nfs+8AFFeZhynjxzcBGlFiE7q+aTGcet/ZwBHKyNzRA0yCreI0KdXynfXB1qb/VHYN2JooygA42VTb6WWyp4wSCRw9gQmDNOm9/GKD41l1BWvPsRL9YHGbKmgNkyHRraspjul58Lq2y8PU1PZgC+9LXYV9TgT/8xnJ3/O7suCx3ZI2bAUn/5dYNgOIJbgxupUBiAXSvFkLeXLcxeJ/C86K+hfyJHeCaeiOkduVvDIn/BRPHk0uJoZ716rWtWXHIdLn7G/5QmaCtQC/8jQR+WwGJ0c5sr+HdP8cKX5sYzvRh8T rsa-key-20220511" \
  > "${SSH_DIR}/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${APP_USER}:${APP_USER}" "$SSH_DIR"

# ── SSH hardening ─────────────────────────────────────────────────────────────

SSHD_CONF=/etc/ssh/sshd_config
cp "$SSHD_CONF" "${SSHD_CONF}.bak"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'               "$SSHD_CONF"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'    "$SSHD_CONF"
systemctl reload ssh

# ── Firewall ──────────────────────────────────────────────────────────────────

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh          # port 22 only — 5432 is never exposed
ufw --force enable

# ── Docker ───────────────────────────────────────────────────────────────────

apt-get update -qq
apt-get install -y -qq ca-certificates curl git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

usermod -aG docker "$APP_USER"

systemctl enable --now docker

echo ""
echo "Done. The docker group membership requires a new shell session to take effect."
echo "Log out and SSH back in, then continue with README.md"
