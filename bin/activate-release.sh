#!/usr/bin/env bash
set -euo pipefail
umask 022

# Activate a staged JupyterHub release: build, migrate, flip, restart, verify,
# and revert on failure. Both install-jupyterhub-service.sh (deploying from a
# git clone) and update-jupyterhub-release.sh (rebuilding from the running
# release) stage a directory and then hand it here, so there is exactly one
# implementation of the dangerous part.
#
#   activate-release.sh /home/jupyterhub/releases/<timestamp>
#
# THE RULE
#
# Build before you flip, verify after you flip, and never exit without doing one
# or the other. Every failure mode below either lands on the new release with a
# hub that answers requests, or lands back on the previous release with its
# pre-migration database restored. There is no third outcome.
#
# Ordering matters and is deliberate:
#
#   1. Build the venv while the old release is still serving. A build failure
#      costs nothing -- the flip has not happened.
#   2. Migrate the database only after committing to the flip. Migration is not
#      reversible, so it must not happen on a path that might discard the
#      release.
#   3. Flip, restart, verify. From the moment the symlink moves, a trap owns the
#      rollback, so a SIGTERM from TimeoutStartSec cannot abandon the system
#      mid-change.
#
# Environment:
#   JH_LOCK_WAIT           seconds to wait for the release lock. 0 means do not
#                          wait: exit 75 (EX_TEMPFAIL) so a timer-driven caller
#                          can defer instead of colliding. Default 300.
#   JH_HEALTH_TIMEOUT      seconds to wait for the hub to serve (default 120)
#   JH_HEALTH_URL          override; otherwise derived from the release config
#   JH_ROLLBACK_ON_FAILURE 1 (default) reverts on a failed verify. 0 still
#                          verifies and still exits non-zero; it only declines
#                          to revert.
#   JH_KEEP_RELEASES       releases to retain after success (default 5)

NEW_RELEASE="${1:-}"
[[ -n "$NEW_RELEASE" ]] || { echo "usage: $0 <release-dir>" >&2; exit 2; }

ROOT="${JH_ROOT:-/home/jupyterhub}"
RELEASES="$ROOT/releases"
CURRENT_LINK="$ROOT/current"
PREVIOUS_LINK="$ROOT/previous"
STATE="${JH_STATE_DIR:-$ROOT/state}"
LOCK_FILE="${STATE}/.release.lock"
DB_BACKUP_MARKER="${STATE}/.last-db-backup"

LOCK_WAIT="${JH_LOCK_WAIT:-300}"
HEALTH_TIMEOUT="${JH_HEALTH_TIMEOUT:-120}"
HEALTH_URL="${JH_HEALTH_URL:-}"
KEEP_RELEASES="${JH_KEEP_RELEASES:-5}"
ROLLBACK="${JH_ROLLBACK_ON_FAILURE:-1}"
HAVE_CURL="$(command -v curl || true)"

log()  { echo "[activate-release] $*"; }
fail() { echo "[activate-release] ERROR: $*" >&2; exit 1; }

# State the trap reads. FLIPPED means the symlink has moved and the system is
# mid-change; VERIFIED means it is safe to leave that way.
FLIPPED=0
VERIFIED=0
PREV_RELEASE=""
DB_BACKUP=""

# ---------------------------------------------------------------- lock -------

mkdir -p "$STATE"
exec 9>"$LOCK_FILE"
if [[ "$LOCK_WAIT" == "0" ]]; then
	if ! flock -n 9; then
		# Deferring is always correct for a periodic caller: the update runs
		# again next week, and colliding with a deploy is strictly worse than
		# skipping one cycle.
		log "another release operation holds $LOCK_FILE; deferring"
		exit 75
	fi
else
	flock -w "$LOCK_WAIT" 9 || fail "timed out after ${LOCK_WAIT}s waiting for $LOCK_FILE"
fi

# ------------------------------------------------------------ preconditions --

mountpoint -q /home || fail "/home is not a mountpoint"
[[ -d "$NEW_RELEASE" ]] || fail "$NEW_RELEASE is not a directory"
[[ -x "$NEW_RELEASE/bin/bootstrap-jupyterhub.sh" ]] || fail "no bootstrap script in $NEW_RELEASE"
[[ -f "$NEW_RELEASE/etc/jupyterhub_config.py" ]] || fail "no jupyterhub_config.py in $NEW_RELEASE"

if [[ -e "$CURRENT_LINK" ]]; then
	PREV_RELEASE="$(readlink -f "$CURRENT_LINK" || true)"
	[[ -d "$PREV_RELEASE" ]] || PREV_RELEASE=""
fi

if [[ "$PREV_RELEASE" == "$NEW_RELEASE" ]]; then
	fail "$NEW_RELEASE is already the current release"
fi

# ------------------------------------------------------- health check setup --

# Derive from the release's own config so the URL cannot drift from it. This is
# deliberately the proxy address (bind_url), not the Hub's internal API port:
# checking the internal port reports success with configurable-http-proxy dead,
# when nothing is actually reachable. String literals only -- a config that
# computes bind_url from the environment needs JH_HEALTH_URL set.
derive_health_url() {
	local config="$1"
	[[ -f "$config" ]] || return 1
	python3 - "$config" <<'PY'
import re, sys

src = open(sys.argv[1]).read()

def literal(name):
    hits = re.findall(
        r'^\s*c\.JupyterHub\.%s\s*=\s*["\']([^"\']+)["\']' % name, src, re.M
    )
    return hits[-1] if hits else None

bind = literal("bind_url")
if not bind:
    raise SystemExit(1)

base = literal("base_url") or "/"
if not base.startswith("/"):
    base = "/" + base
if not base.endswith("/"):
    base += "/"

print(bind.rstrip("/") + base + "hub/health")
PY
}

health_ok() {
	if [[ -n "$HAVE_CURL" && -n "$HEALTH_URL" ]]; then
		curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1
	else
		# Degraded rather than fatal when curl is missing or the config could
		# not be parsed. Reports only that the process has not exited.
		systemctl is-active --quiet jupyterhub.service
	fi
}

if [[ -z "$HEALTH_URL" ]]; then
	if HEALTH_URL="$(derive_health_url "$NEW_RELEASE/etc/jupyterhub_config.py")"; then
		log "Health endpoint derived from release config: $HEALTH_URL"
	else
		HEALTH_URL=""
		log "WARNING: could not derive a health URL; set JH_HEALTH_URL to enable the serving check"
	fi
fi
if [[ -z "$HAVE_CURL" || -z "$HEALTH_URL" ]]; then
	log "WARNING: falling back to systemctl is-active for the health check"
fi

# ------------------------------------------------------------- rollback ------

# Ignore TERM and INT while reverting. A second signal during rollback is the
# one way to still end up half-changed, and systemd sends SIGKILL only after
# TimeoutStopSec, which is long enough for two symlink writes and a file copy.
rollback() {
	trap '' TERM INT

	log "Rolling back to ${PREV_RELEASE:-<none>}"

	# Symlink first: it is instant, and it is what decides which code runs.
	if [[ -n "$PREV_RELEASE" ]]; then
		ln -sfn "$PREV_RELEASE" "$CURRENT_LINK"
	fi

	# Then the database. Reverting code alone is not enough -- an older hub
	# cannot open a schema the new one migrated.
	if [[ -n "$DB_BACKUP" && -f "$DB_BACKUP" ]]; then
		if cp -a "$DB_BACKUP" "${STATE}/jupyterhub.sqlite"; then
			log "Restored pre-migration database from $DB_BACKUP"
		else
			log "WARNING: could not restore $DB_BACKUP; the database is still migrated"
		fi
	fi

	systemctl try-restart jupyterhub.service || true
	FLIPPED=0
}

# Owns every exit path from the flip onward, including SIGTERM from
# TimeoutStartSec, so the script cannot abandon the system mid-change.
on_exit() {
	local rc=$?
	if (( FLIPPED == 1 && VERIFIED == 0 )); then
		if [[ "$ROLLBACK" == "1" ]]; then
			rollback
		else
			log "WARNING: verification did not pass and JH_ROLLBACK_ON_FAILURE=0"
			log "WARNING: $CURRENT_LINK still points at $NEW_RELEASE; revert by hand"
		fi
	fi
	exit "$rc"
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# ------------------------------------------------------- 1. build the venv ---

# The old release is still serving. A failure here costs nothing.
#
# JH_SKIP_USER_VENV=1: the single-user venv under state/ is shared by every user
# and every release, and no rollback can revert it. It must not be touched by a
# build that might still be discarded, so it is updated in step 4 instead, once
# the hub is verified serving.
log "Building venv in $NEW_RELEASE (old release still serving)"
if ! JH_APP="$NEW_RELEASE" BOOTSTRAP_MODE=relaxed JH_AUTO_UPGRADE_DB=0 \
     JH_SKIP_USER_VENV=1 "$NEW_RELEASE/bin/bootstrap-jupyterhub.sh"; then
	fail "bootstrap failed; ${PREV_RELEASE:-current release} left running"
fi
[[ -x "$NEW_RELEASE/venv/bin/jupyterhub" ]] || fail "no jupyterhub in $NEW_RELEASE/venv"

NEW_VER="$("$NEW_RELEASE/venv/bin/jupyterhub" --version 2>/dev/null || echo unknown)"
OLD_VER="unknown"
if [[ -n "$PREV_RELEASE" && -x "$PREV_RELEASE/venv/bin/jupyterhub" ]]; then
	OLD_VER="$("$PREV_RELEASE/venv/bin/jupyterhub" --version 2>/dev/null || echo unknown)"
fi
log "JupyterHub ${OLD_VER} -> ${NEW_VER}"

# ------------------------------------------- 2. migrate, having committed ----

# Only now, with the build proven and the flip about to happen. Migration is not
# reversible, so it must never run on a path that might discard the release.
# BOOTSTRAP_MODE=strict skips the package install (the venv now exists, so
# CLEAN_SYSTEM is 0) and JH_AUTO_UPGRADE_DB=always runs the backup and migration.
rm -f -- "$DB_BACKUP_MARKER"
log "Backing up and migrating the database"
if ! JH_APP="$NEW_RELEASE" BOOTSTRAP_MODE=strict JH_AUTO_UPGRADE_DB=always \
     "$NEW_RELEASE/bin/bootstrap-jupyterhub.sh"; then
	fail "database migration failed; ${PREV_RELEASE:-current release} left running"
fi
if [[ -f "$DB_BACKUP_MARKER" ]]; then
	DB_BACKUP="$(cat "$DB_BACKUP_MARKER")"
	log "Pre-migration database backup: $DB_BACKUP"
fi

# --------------------------------------------------- 3. flip and verify ------

if [[ -n "$PREV_RELEASE" ]]; then
	ln -sfn "$PREV_RELEASE" "$PREVIOUS_LINK"
fi
ln -sfn "$NEW_RELEASE" "$CURRENT_LINK"
FLIPPED=1
rm -f -- "${STATE}/NEEDS_RESTART"
log "Switched current -> $NEW_RELEASE (previous -> ${PREV_RELEASE:-<none>})"

systemctl restart jupyterhub.service || true

deadline=$((SECONDS + HEALTH_TIMEOUT))
while (( SECONDS < deadline )); do
	# Give up early rather than waiting out the timeout on a unit systemd has
	# already abandoned. Restart=always cycles through auto-restart first and
	# only lands in failed once the start limit is hit.
	if systemctl is-failed --quiet jupyterhub.service; then
		log "jupyterhub entered a failed state"
		break
	fi
	if systemctl is-active --quiet jupyterhub.service && health_ok; then
		VERIFIED=1
		break
	fi
	sleep 2
done

if (( VERIFIED == 0 )); then
	# The EXIT trap performs the rollback; exiting non-zero is what triggers it
	# and what tells the caller the deploy did not take.
	fail "jupyterhub did not start serving within ${HEALTH_TIMEOUT}s"
fi

log "jupyterhub is serving on $NEW_RELEASE (${HEALTH_URL:-is-active})"

# ------------------------------------------- 4. shared single-user venv ------

# Only now. This venv is shared across users and releases and cannot be rolled
# back, so it is the last thing changed and only on a release that is verified
# serving. JH_SKIP_HUB_VENV=1 keeps this from re-running pip against the hub
# venv, which would risk pulling a newer package than the one just verified.
#
# Failure here is deliberately not fatal: the hub is up and users can log in.
# Their notebook servers keep running whatever is already installed.
log "Updating the shared single-user venv"
if ! JH_APP="$NEW_RELEASE" BOOTSTRAP_MODE=relaxed JH_AUTO_UPGRADE_DB=0 \
     JH_SKIP_HUB_VENV=1 "$NEW_RELEASE/bin/bootstrap-jupyterhub.sh"; then
	log "WARNING: single-user venv update failed; the hub is serving and users are unaffected"
	log "WARNING: rerun by hand: JH_SKIP_HUB_VENV=1 BOOTSTRAP_MODE=relaxed $CURRENT_LINK/bin/bootstrap-jupyterhub.sh"
fi

# ------------------------------------------------------------- 5. prune ------

protect_current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
protect_previous="$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || true)"
# The `|| true` matters: under `set -o pipefail`, ls exiting non-zero because
# nothing matches would otherwise abort the script.
# shellcheck disable=SC2012
{ ls -1dt "$RELEASES"/* 2>/dev/null || true; } | tail -n "+$((KEEP_RELEASES + 1))" | while read -r r; do
	if [[ "$r" == "$protect_current" || "$r" == "$protect_previous" ]]; then
		continue
	fi
	log "Pruning old release $r"
	rm -rf -- "$r"
done

log "Done."
