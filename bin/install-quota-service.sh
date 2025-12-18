#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

sudo install -D -m 0755 \
  "$ROOT_DIR/bin/enable-home-quotas.sh" \
  /usr/local/sbin/enable-home-quotas.sh

sudo install -D -m 0644 \
  "$ROOT_DIR/systemd/enable-home-quotas.service" \
  /etc/systemd/system/enable-home-quotas.service

sudo systemctl daemon-reload
sudo systemctl reset-failed enable-home-quotas.service >/dev/null 2>&1 || true
sudo systemctl enable --now enable-home-quotas.service

echo ""
echo "Installed enable-home-quotas.service"
echo "Status:"
echo "  systemctl status enable-home-quotas.service"
