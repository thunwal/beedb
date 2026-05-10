#!/usr/bin/env bash
# Pull latest changes from the repository and restart the stack on the VM.
# Run from your local machine.
# Usage: bash scripts/deploy.sh <vm-ip> [key-file]
set -euo pipefail

VM_IP="${1:?Usage: $0 <vm-ip> [key-file]}"
KEY="${2:-$HOME/.ssh/beedb_ed25519}"

ssh -i "$KEY" ubuntu@"$VM_IP" \
  "cd ~/beedb && git pull && docker compose up -d"
