#!/usr/bin/env bash
# Run once as root on a fresh Ubuntu 26.04 LTS VM (Exoscale).
# Exoscale pre-configures the ubuntu user and installs the SSH key —
# this script only hardens SSH, sets the firewall, and installs Docker.
# Usage: sudo bash vm-setup.sh
set -euo pipefail

APP_USER="ubuntu"

# ── SSH hardening ─────────────────────────────────────────────────────────────
# Exoscale already sets up key-based auth; enforce the settings explicitly.

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
echo "Done. Log back in as $APP_USER and follow README.md"
