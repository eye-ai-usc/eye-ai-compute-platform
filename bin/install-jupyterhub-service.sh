#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT="/home/jupyterhub"
RELEASES="$ROOT/releases"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
NEW_RELEASE="$RELEASES/$TS"

CURRENT_LINK="$ROOT/current"
PREVIOUS_LINK="$ROOT/previous"

# 0) Ensure persistent /home is mounted
if ! mountpoint -q /home; then
  echo "ERROR: /home is not a mountpoint; refusing to install."
  exit 1
fi

sudo mkdir -p "$RELEASES" "$ROOT/state"

# 1) Stage new release (copy repo -> timestamped release dir)
sudo mkdir -p "$NEW_RELEASE"
sudo rsync -a --delete "$SRC_DIR/" "$NEW_RELEASE/"
sudo chmod +x "$NEW_RELEASE/bin/"*.sh || true

# 2) Preserve old install pointer as "previous" (best-effort)
if [ -L "$CURRENT_LINK" ]; then
  OLD_TARGET="$(readlink -f "$CURRENT_LINK" || true)"
  if [ -n "${OLD_TARGET:-}" ] && [ -d "$OLD_TARGET" ]; then
    sudo ln -sfn "$OLD_TARGET" "$PREVIOUS_LINK"
  fi
fi

# 3) Atomically switch current -> new release
sudo ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"

# 4) Install/refresh ONLY the JupyterHub unit from the current release
# (mount + quota services are installed/enabled by install-mount-service.sh / install-quota-service.sh)
sudo install -m 0644 "$CURRENT_LINK/systemd/jupyterhub.service" /etc/systemd/system/jupyterhub.service

sudo systemctl daemon-reload
sudo systemctl enable jupyterhub
sudo systemctl restart jupyterhub

# 5) Emit status + helpers
echo ""
echo "Installed new release: $NEW_RELEASE"
echo "Current release:       $(readlink -f "$CURRENT_LINK")"

echo ""
echo "Show recent releases:"
echo "  ls -1dt /home/jupyterhub/releases/* | head -n 10"

if [ -L "$PREVIOUS_LINK" ]; then
  PREV_TARGET="$(readlink -f "$PREVIOUS_LINK" || true)"
  if [ -n "${PREV_TARGET:-}" ] && [ -d "$PREV_TARGET" ]; then
    echo "Previous release:      $PREV_TARGET"
    echo ""
    echo "Rollback (copy/paste):"
    echo "  sudo ln -sfn \"$PREV_TARGET\" \"$CURRENT_LINK\" && sudo systemctl restart jupyterhub"
  else
    echo "Previous release:      (present but invalid)"
    echo ""
    echo "Rollback (template):"
    echo "  sudo ln -sfn /home/jupyterhub/releases/<timestamp> \"$CURRENT_LINK\" && sudo systemctl restart jupyterhub"
  fi
else
  echo "Previous release:      (none recorded yet)"
  echo ""
  echo "Rollback (template):"
  echo "  sudo ln -sfn /home/jupyterhub/releases/<timestamp> \"$CURRENT_LINK\" && sudo systemctl restart jupyterhub"
fi

echo ""
echo "Check status:"
echo "  systemctl status jupyterhub"
