#!/usr/bin/env bash
set -euo pipefail
umask 022

# Weekly (or manual) JupyterHub environment update.
#
# Stages a NEW release from the current release's source tree, builds a fresh
# venv from the pinned requirements, and activates it only if the package set
# actually changed. Upgrading the deployed release's venv in place would defeat
# the per-release model: `current` would stop matching what was deployed, and a
# symlink-flip rollback could not restore the previous package set.
#
# Everything dangerous -- migrating, flipping, restarting, verifying, reverting
# -- lives in activate-release.sh, which the deploy script also uses, so there is
# one implementation of it rather than two.
#
# Environment:
#   JH_KEEP_RELEASES  releases to retain (default 5; current and previous are
#                     never pruned). Passed through to activate-release.sh.
#
# See activate-release.sh for the health check and rollback knobs.

ROOT="${JH_ROOT:-/home/jupyterhub}"
RELEASES="$ROOT/releases"
CURRENT_LINK="$ROOT/current"
STATE="${JH_STATE_DIR:-$ROOT/state}"
LOCK_FILE="${STATE}/.release.lock"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
NEW_RELEASE="$RELEASES/$TS"

log()  { echo "[jupyterhub-update] $*"; }
fail() { echo "[jupyterhub-update] ERROR: $*" >&2; exit 1; }

mountpoint -q /home || fail "/home is not a mountpoint"
[[ -e "$CURRENT_LINK" ]] || fail "no release at $CURRENT_LINK"

CURRENT_RELEASE="$(readlink -f "$CURRENT_LINK")"
[[ -d "$CURRENT_RELEASE" ]] || fail "current release $CURRENT_RELEASE is missing"

# Probe the release lock before doing any work. A deploy in progress means this
# run should defer, not build a release from a `current` that is about to move.
# Deferring is always correct here: the timer fires again next week.
mkdir -p "$STATE"
if ! ( exec 9>"$LOCK_FILE"; flock -n 9 ); then
	log "a release operation is in progress; deferring this update"
	exit 0
fi

log "Current release: $CURRENT_RELEASE"
log "Staging new release: $NEW_RELEASE"

mkdir -p "$NEW_RELEASE"
# Copy the release source but never the venv: a venv bakes absolute paths into
# its shebangs and pyvenv.cfg, so the new one is built from scratch below.
rsync -a --delete --exclude 'venv/' "$CURRENT_RELEASE/" "$NEW_RELEASE/"
chmod +x "$NEW_RELEASE/bin/"*.sh || true

discard_new() { rm -rf -- "$NEW_RELEASE"; }

# Build the venv while the current release keeps serving. No database work here:
# migration is not reversible and must not happen on a path that might discard
# this release, so activate-release.sh does it after committing to the flip.
if ! JH_APP="$NEW_RELEASE" BOOTSTRAP_MODE=relaxed JH_AUTO_UPGRADE_DB=0 \
     "$NEW_RELEASE/bin/bootstrap-jupyterhub.sh"; then
	discard_new
	fail "bootstrap failed; $CURRENT_RELEASE left running"
fi

if [[ ! -x "$NEW_RELEASE/venv/bin/jupyterhub" ]]; then
	discard_new
	fail "no jupyterhub binary in $NEW_RELEASE/venv; $CURRENT_RELEASE left running"
fi

# Nothing changed? Discard rather than accumulating identical venvs every week,
# and leave the running hub completely untouched.
if diff -q <("$CURRENT_RELEASE/venv/bin/pip" freeze 2>/dev/null) \
           <("$NEW_RELEASE/venv/bin/pip" freeze 2>/dev/null) >/dev/null 2>&1; then
	log "No package changes; keeping $CURRENT_RELEASE"
	discard_new
	rm -f -- "${STATE}/NEEDS_RESTART"
	exit 0
fi

# Hand off. JH_LOCK_WAIT=0 makes activation defer rather than queue behind a
# deploy that started while we were building; exit 75 is that deferral.
log "Package changes detected; activating $NEW_RELEASE"
set +e
JH_LOCK_WAIT=0 "$NEW_RELEASE/bin/activate-release.sh" "$NEW_RELEASE"
rc=$?
set -e

case "$rc" in
	0)
		log "Update complete."
		;;
	75)
		log "Activation deferred; discarding $NEW_RELEASE and leaving $CURRENT_RELEASE running"
		discard_new
		;;
	*)
		# activate-release.sh has already rolled back; this release is garbage.
		log "Activation failed and was rolled back; discarding $NEW_RELEASE"
		discard_new
		exit "$rc"
		;;
esac
