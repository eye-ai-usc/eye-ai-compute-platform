#!/usr/bin/env bash
set -euo pipefail

# Deploy this working tree as a new JupyterHub release.
#
# This stages the release and then hands it to activate-release.sh, which owns
# building, migrating, flipping, restarting, verifying, and reverting. The
# weekly update service uses the same script, so a deploy and an automatic
# update follow identical, mutually exclusive code paths.
#
# The previous version of this script flipped the `current` symlink and then
# restarted, leaving the venv to be built by ExecStartPre under
# jupyterhub.service's 300s TimeoutStartSec. A slow build meant `current`
# pointed at a release with no working venv, Restart=always flapped to the start
# limit, and nothing reverted. It also armed the update timer before the restart,
# so a Persistent=true catch-up run could collide with the deploy.

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

# 2) Install systemd units from the staged release BEFORE activating, since the
#    restart that activation performs must use them.
#
#    Note: a failed activation reverts the release symlink but not these files.
#    Units change rarely, and the previous release still carries its own copies
#    under $PREVIOUS_LINK/systemd/ if they ever need restoring by hand.
sudo install -m 0644 "$NEW_RELEASE/systemd/jupyterhub.service" \
  /etc/systemd/system/jupyterhub.service

sudo install -m 0644 "$NEW_RELEASE/systemd/jupyterhub-update.service" \
  /etc/systemd/system/jupyterhub-update.service

sudo install -m 0644 "$NEW_RELEASE/systemd/jupyterhub-update.timer" \
  /etc/systemd/system/jupyterhub-update.timer

sudo install -m 0644 "$NEW_RELEASE/systemd/jupyterhub-failure-notify@.service" \
  /etc/systemd/system/jupyterhub-failure-notify@.service

# Installed to /usr/local/sbin rather than run from the release, so the failure
# handler still works when the release itself is what broke.
sudo install -m 0755 "$NEW_RELEASE/bin/notify-failure.sh" \
  /usr/local/sbin/jupyterhub-notify-failure.sh

sudo systemctl daemon-reload
sudo systemctl enable jupyterhub

# 3) Activate: build, migrate, flip, restart, verify, revert on failure.
#    Nothing before this point has touched the running hub.
#
#    Forward the activation knobs explicitly. sudo resets the environment, so an
#    operator running `JH_HEALTH_TIMEOUT=10 ./install-jupyterhub-service.sh`
#    would otherwise see the variable silently dropped here -- and a rollback
#    rehearsal that quietly used the default timeout would report success
#    without ever exercising the rollback.
ACTIVATE_ENV=()
for _v in JH_HEALTH_TIMEOUT JH_HEALTH_URL JH_LOCK_WAIT JH_ROLLBACK_ON_FAILURE \
          JH_KEEP_RELEASES JH_ROOT JH_STATE_DIR; do
  if [[ -n "${!_v:-}" ]]; then
    ACTIVATE_ENV+=("${_v}=${!_v}")
    echo "[install] forwarding ${_v}=${!_v} to activate-release.sh"
  fi
done

if ! sudo env "${ACTIVATE_ENV[@]}" "$NEW_RELEASE/bin/activate-release.sh" "$NEW_RELEASE"; then
  echo ""
  echo "ERROR: activation failed. The previous release has been restored and the"
  echo "       pre-migration database put back."
  echo ""
  echo "This run did not arm jupyterhub-update.timer. A timer armed by an earlier"
  echo "deploy is unaffected and still scheduled -- check with:"
  echo "  systemctl list-timers --all | grep jupyterhub"
  echo ""
  echo "The staged release is left in place for diagnosis and is pruned on the"
  echo "next successful activation."
  echo ""
  echo "Inspect:"
  echo "  journalctl -u jupyterhub -n 100 --no-pager"
  echo "  systemctl status jupyterhub"
  exit 1
fi

# 4) Arm the weekly update only once the hub is verified serving. Arming it
#    earlier lets a Persistent=true catch-up run start while the deploy is still
#    in flight.
sudo systemctl enable --now jupyterhub-update.timer

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
    echo ""
    echo "If that release predates a database migration, restore the database too:"
    echo "  sudo cp -a \"\$(cat /home/jupyterhub/state/.last-db-backup)\" /home/jupyterhub/state/jupyterhub.sqlite"
  else
    echo "Previous release:      (present but invalid)"
    echo ""
    echo "Rollback (template):"
    echo "  sudo ln -sfn /home/jupyterhub/releases/<timestamp> \"$CURRENT_LINK\" && sudo systemctl restart jupyterhub"
  fi
else
  echo "Previous release:      (none recorded yet)"
fi

echo ""
echo "Check status:"
echo "  systemctl status jupyterhub"
echo "  systemctl list-timers --all | grep jupyterhub"
