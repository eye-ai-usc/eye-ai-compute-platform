#!/usr/bin/env bash
set -uo pipefail

# Prune every user's uv cache.
#
# uv's cache grows without bound as environments are built, and it lives in the
# quota'd home directory: it was 27 GB for one user here. `uv cache prune`
# removes unreachable entries only, so it never breaks an environment somebody
# still has -- which is what makes it safe to run unattended. On this host a
# first prune recovered 10 GiB from a single user.
#
# Expect less than the directory's apparent size. uv hardlinks from its cache
# into venv site-packages, so anything a live environment still references
# survives; the space simply stops being attributed to the cache.
#
# Environment:
#   HOME_FS  filesystem holding user homes (default /home), reported before/after
#   UV_BIN   uv executable (default the single-user venv's)

HOME_FS="${HOME_FS:-/home}"
UV_BIN="${UV_BIN:-/home/jupyterhub/state/user-venv/bin/uv}"

# uv walks up from the working directory looking for uv.toml / pyproject.toml.
# Run from a directory every user can traverse: started from somewhere like
# another user's home it fails with EACCES before it ever reaches the cache, and
# a project config found on the way up could redirect cache-dir and defeat the
# explicit UV_CACHE_DIR below.
cd / || exit 1

log() { echo "[prune-uv-caches] $*"; }

if [[ ! -x "$UV_BIN" ]]; then
	log "ERROR: no uv at $UV_BIN"
	exit 1
fi

before="$(df -h --output=avail "$HOME_FS" 2>/dev/null | tail -1 | tr -d ' ')"
log "free on ${HOME_FS} before: ${before:-unknown}"

pruned=0
skipped=0
while IFS=: read -r user _ uid _ _ home _; do
	[[ "$uid" -ge 1000 ]] || continue
	[[ "$home" == "${HOME_FS}"/* ]] || continue

	cache="${home}/.cache/uv"
	[[ -d "$cache" ]] || continue

	if sudo -u "$user" env "HOME=$home" "UV_CACHE_DIR=$cache" "$UV_BIN" cache prune >/dev/null 2>&1; then
		pruned=$((pruned + 1))
	else
		log "WARNING: prune failed for ${user}"
		skipped=$((skipped + 1))
	fi
done < /etc/passwd

after="$(df -h --output=avail "$HOME_FS" 2>/dev/null | tail -1 | tr -d ' ')"
log "pruned ${pruned} cache(s), skipped ${skipped}; free on ${HOME_FS} after: ${after:-unknown}"
