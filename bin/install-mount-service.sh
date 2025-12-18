#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Install script onto rootfs (must exist before /home is mounted)
sudo install -D -m 0755 \
  "$ROOT_DIR/bin/mount-ebs-volumes.sh" \
  /usr/local/sbin/mount-ebs-volumes.sh

# Install systemd unit onto rootfs
sudo install -D -m 0644 \
  "$ROOT_DIR/systemd/mount-ebs-volumes.service" \
  /etc/systemd/system/mount-ebs-volumes.service

sudo systemctl daemon-reload
sudo systemctl reset-failed mount-ebs-volumes.service >/dev/null 2>&1 || true
sudo systemctl enable --now mount-ebs-volumes.service

echo ""
echo "Installed mount-ebs-volumes.service"

# Verify mounts now (fail fast)
if ! mountpoint -q /home; then
  echo "ERROR: /home is not mounted."
  systemctl status mount-ebs-volumes.service || true
  journalctl -u mount-ebs-volumes.service -n 200 --no-pager || true
  exit 1
fi

if ! mountpoint -q /data; then
  echo "ERROR: /data is not mounted."
  systemctl status mount-ebs-volumes.service || true
  journalctl -u mount-ebs-volumes.service -n 200 --no-pager || true
  exit 1
fi

echo "OK: /home and /data are mounted."
echo "Status:"
echo "  systemctl status mount-ebs-volumes.service"
