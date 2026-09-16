#!/usr/bin/env bash
set -uo pipefail

# Prune every user's uv cache on the instance-store scratch volume.
#
# jupyterhub_config.py points UV_CACHE_DIR at <scratch>/uv-cache/<user>, which
# keeps build caches out of quota'd home directories. The cost of that is a
# shared, unquota'd volume: one user filling it breaks uv for everyone. This
# bounds the growth.
#
# `uv cache prune` removes unreachable entries only, so it never breaks an
# environment a user still has -- unlike clearing the cache outright. That makes
# it safe to run unattended.
#
# Environment:
#   SCRATCH_DIR  instance-store mount (default /opt/dlami/nvme)
#   UV_BIN       uv executable (default the single-user venv's)

SCRATCH_DIR="${SCRATCH_DIR:-/opt/dlami/nvme}"
UV_CACHE_ROOT="${SCRATCH_DIR}/uv-cache"
UV_BIN="${UV_BIN:-/home/jupyterhub/state/user-venv/bin/uv}"

log() { echo "[prune-uv-caches] $*"; }

if [[ ! -d "$UV_CACHE_ROOT" ]]; then
	log "no cache root at $UV_CACHE_ROOT; nothing to do"
	exit 0
fi

if [[ ! -x "$UV_BIN" ]]; then
	log "ERROR: no uv at $UV_BIN"
	exit 1
fi

before="$(df -h --output=avail "$SCRATCH_DIR" 2>/dev/null | tail -1 | tr -d ' ')"
log "free before: ${before:-unknown}"

pruned=0
skipped=0
for dir in "$UV_CACHE_ROOT"/*; do
	[[ -d "$dir" ]] || continue
	user="$(basename "$dir")"

	# A cache whose owner no longer exists is left alone rather than deleted:
	# removing another account's data unattended is not this script's call.
	if ! id -u "$user" >/dev/null 2>&1; then
		log "WARNING: $dir has no matching user; leaving it"
		skipped=$((skipped + 1))
		continue
	fi

	if sudo -u "$user" env "UV_CACHE_DIR=$dir" "$UV_BIN" cache prune >/dev/null 2>&1; then
		pruned=$((pruned + 1))
	else
		log "WARNING: prune failed for $user"
		skipped=$((skipped + 1))
	fi
done

after="$(df -h --output=avail "$SCRATCH_DIR" 2>/dev/null | tail -1 | tr -d ' ')"
log "pruned ${pruned} cache(s), skipped ${skipped}; free after: ${after:-unknown}"
