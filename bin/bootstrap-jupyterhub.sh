#!/usr/bin/env bash
set -euo pipefail
umask 022

# JupyterHub release/bootstrap script (runs on host via systemd ExecStartPre and via update service / timer)
#
# Responsibilities:
#   - ensure /home is mounted
#   - ensure shared state dirs exist under /home/jupyterhub/state
#   - ensure per-release venv exists under the release dir's venv/
#   - install/upgrade jupyterhub deps into that venv from pinned requirements
#   - back up and migrate the hub database when the installed hub needs it
#   - ensure cookie secret exists (stable across releases)
#
# BOOTSTRAP_MODE:
#   strict  (default): failures are fatal (clean-system bootstrap)
#   relaxed           failures are warnings (timer/manual updates)
#
# JH_APP:
#   Defaults to ${JH_ROOT}/current. The update script overrides it so a new
#   release can be built before the current symlink is moved, which keeps the
#   deployed release immutable and rollback a symlink flip.
#
# JH_AUTO_UPGRADE_DB:
#   1 (default): back up the hub database and run `jupyterhub upgrade-db` after
#                packages are installed or upgraded. Alembic is a no-op when the
#                schema is already current.
#   always     : additionally migrate on every service start. Self-healing, but
#                it mutates state on restart, which the strict-mode contract
#                otherwise avoids. Set it in /home/jupyterhub/etc/jupyterhub.env
#                if you would rather the hub repair itself than fail to start.
#   0          : never. The hub will refuse to start on a schema mismatch.

BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-strict}"
JH_AUTO_UPGRADE_DB="${JH_AUTO_UPGRADE_DB:-1}"

# JH_SKIP_HUB_VENV / JH_SKIP_USER_VENV:
#   Skip the package install for one venv or the other. activate-release.sh uses
#   these to separate the two, because they live in different places and carry
#   different risk.
#
#   The hub venv is per-release and rolls back with a symlink flip. The
#   single-user venv lives under state/ and is shared by every user and every
#   release, so nothing can roll it back. It must therefore be touched only once
#   a release is committed and serving, never during a build that might be
#   discarded.
#
#   Creating an absent venv is not gated by these: that adds nothing and mutates
#   nothing, and it keeps a first install from leaving users without a server.
JH_SKIP_HUB_VENV="${JH_SKIP_HUB_VENV:-0}"
JH_SKIP_USER_VENV="${JH_SKIP_USER_VENV:-0}"

JH_ROOT="${JH_ROOT:-/home/jupyterhub}"
JH_APP="${JH_APP:-${JH_ROOT}/current}"
JH_VENV="${JH_APP}/venv"
# Honor JH_STATE_DIR so this agrees with etc/jupyterhub_config.py, which reads
# the same variable to locate the database and cookie secret.
JH_STATE="${JH_STATE_DIR:-${JH_ROOT}/state}"

NEEDS_RESTART_FILE="${JH_STATE}/NEEDS_RESTART"
JH_BACKUPS="${JH_STATE}/backups"
JH_DB="${JH_STATE}/jupyterhub.sqlite"
JH_CONFIG="${JH_APP}/etc/jupyterhub_config.py"
REQ_HUB="${JH_APP}/etc/requirements-hub.txt"
REQ_USER="${JH_APP}/etc/requirements-user.txt"

# Timestamped-backup retention (database copies and pip freezes)
JH_BACKUP_KEEP="${JH_BACKUP_KEEP:-10}"

log() {
  echo "[jupyterhub-bootstrap] $*"
}

warn() {
  echo "[jupyterhub-bootstrap] WARNING: $*" >&2
}

maybe_fail() {
  if [[ "$BOOTSTRAP_MODE" == "strict" ]]; then
    return 1
  else
    warn "$1"
    return 0
  fi
}

# Keep the newest JH_BACKUP_KEEP files sharing a prefix, remove older ones.
# The `|| true` matters: under `set -o pipefail`, ls exiting non-zero because
# nothing matches would otherwise abort the whole bootstrap.
prune_backups() {
  local prefix="$1" f
  # shellcheck disable=SC2012
  { ls -1t "${prefix}"* 2>/dev/null || true; } | tail -n "+$((JH_BACKUP_KEEP + 1))" | while read -r f; do
    rm -f -- "$f"
  done
}

# Record exactly what is installed, so requirements pins can be tightened from
# real data and so a rollback has an exact version to reinstall.
record_freeze() {
  local venv="$1" label="$2" ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$JH_BACKUPS"
  if "${venv}/bin/pip" freeze > "${JH_BACKUPS}/pip-freeze-${label}-${ts}.txt" 2>/dev/null; then
    log "Recorded ${label} freeze: ${JH_BACKUPS}/pip-freeze-${label}-${ts}.txt"
    prune_backups "${JH_BACKUPS}/pip-freeze-${label}-"
  else
    warn "Could not record ${label} package freeze"
  fi
}

# Back up the hub database, then bring its schema up to what the installed hub
# expects. JupyterHub changes the schema across releases and refuses to start
# until this runs, so the package upgrade and the migration belong in one step.
upgrade_db() {
  local ts backup
  if [[ "$JH_AUTO_UPGRADE_DB" != "1" && "$JH_AUTO_UPGRADE_DB" != "always" ]]; then
    log "Skipping database upgrade (JH_AUTO_UPGRADE_DB=${JH_AUTO_UPGRADE_DB})"
    return 0
  fi
  if [[ ! -f "$JH_CONFIG" ]]; then
    warn "No config at ${JH_CONFIG}; skipping database upgrade"
    return 0
  fi
  if [[ ! -f "$JH_DB" ]]; then
    log "No database at ${JH_DB} yet; it will be created on first start"
    return 0
  fi
  if [[ ! -x "${JH_VENV}/bin/alembic" ]]; then
    # Fail here with something actionable rather than letting the migration die
    # inside jupyterhub with a bare FileNotFoundError traceback.
    maybe_fail "No alembic console script in ${JH_VENV}/bin; cannot migrate the database" || return 1
    return 0
  fi

  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  # The ".auto." infix keeps retention off backups taken by hand: pruning only
  # ever matches this prefix, so an operator's pre-upgrade copy survives.
  backup="${JH_BACKUPS}/jupyterhub.sqlite.auto.${ts}"
  mkdir -p "$JH_BACKUPS"

  if ! cp -a "$JH_DB" "$backup"; then
    # Never migrate without a backup: the migration is not reversible, and the
    # pre-migration copy is the only way back to the previous hub version.
    maybe_fail "Could not back up ${JH_DB}; refusing to upgrade the database" || return 1
    return 0
  fi
  log "Backed up database to ${backup}"
  # Record the path so an automated rollback can restore the pre-migration copy;
  # reverting the code alone leaves an older hub facing a migrated schema.
  echo "$backup" > "${JH_STATE}/.last-db-backup"
  prune_backups "${JH_BACKUPS}/jupyterhub.sqlite.auto."

  log "Running jupyterhub upgrade-db (no-op if the schema is already current)"
  # jupyterhub.dbutil shells out to the `alembic` console script via
  # check_call(['alembic', ...]), which resolves through PATH. Invoking the hub
  # by absolute path is not enough -- under systemd, PATH is the unit default
  # and the venv's bin/ is absent, so this fails with FileNotFoundError:
  # 'alembic'. Put the venv first on PATH for the duration of the call.
  if PATH="${JH_VENV}/bin:${PATH}" "${JH_VENV}/bin/jupyterhub" upgrade-db -f "$JH_CONFIG"; then
    log "Database schema is current"
  else
    maybe_fail "jupyterhub upgrade-db failed; database left at ${backup}" || return 1
  fi
}

# Per-run scratch for pip output. Two bootstraps can run at once -- the update
# service building a new release while jupyterhub.service runs its own
# ExecStartPre bootstrap -- and a shared path would let the grep that decides
# whether packages changed read the wrong run's output. Output still reaches the
# journal through tee, so discarding these on exit costs no diagnostics.
PIP_LOG_DIR="$(mktemp -d -t jupyterhub-bootstrap-XXXXXXXX)"
trap 'rm -rf -- "$PIP_LOG_DIR"' EXIT

# Detect clean system: hub venv not yet initialized
CLEAN_SYSTEM=0
if [[ ! -x "${JH_VENV}/bin/jupyterhub" ]]; then
  CLEAN_SYSTEM=1
fi

# 1) Basic preconditions (always strict)
if ! mountpoint -q /home; then
  log "ERROR: /home is not a mountpoint (mount-ebs-volumes.service should run first)"
  exit 1
fi

if [[ ! -d "$JH_APP" ]]; then
  log "ERROR: $JH_APP does not exist (deploy a release first)"
  exit 1
fi

# 2) Ensure shared state dirs
mkdir -p "${JH_STATE}/pid" "${JH_STATE}/logs"

# 3) Ensure per-release venv
if [[ ! -x "${JH_VENV}/bin/python" ]]; then
  log "Creating per-release venv at ${JH_VENV}..."
  python3 -m venv "${JH_VENV}"
fi

# 4) Install/upgrade hub deps (clean system or relaxed mode only)
if [[ "$JH_SKIP_HUB_VENV" == "1" ]]; then
  log "Skipping hub package install (JH_SKIP_HUB_VENV=1)"
elif [[ "$CLEAN_SYSTEM" -eq 1 || "$BOOTSTRAP_MODE" != "strict" ]]; then
  log "Installing/upgrading hub packages in ${JH_VENV} (clean=${CLEAN_SYSTEM}, mode=${BOOTSTRAP_MODE})"

  if "${JH_VENV}/bin/pip" install --upgrade pip wheel setuptools | tee "${PIP_LOG_DIR}/pip-hub-base.out"; then
    # Touch restart marker if pip actually installed or built packages
    if grep -qiE "Successfully installed|Installing collected packages" "${PIP_LOG_DIR}/pip-hub-base.out"; then
      touch "$NEEDS_RESTART_FILE"
    fi
  else
    maybe_fail "Failed to upgrade base pip packages in hub venv"
  fi

  if [[ ! -f "$REQ_HUB" ]]; then
    # Installing unpinned is the failure mode this file exists to prevent, so
    # a missing requirements file is fatal in both modes.
    log "ERROR: missing $REQ_HUB"
    log "Hub packages must be installed from the release's pinned requirements."
    exit 1
  fi

  if "${JH_VENV}/bin/pip" install --upgrade -r "$REQ_HUB" | tee "${PIP_LOG_DIR}/pip-hub.out"; then
    if grep -qiE "Successfully installed|Installing collected packages" "${PIP_LOG_DIR}/pip-hub.out"; then
      touch "$NEEDS_RESTART_FILE"
      record_freeze "$JH_VENV" hub
    fi
    # Run unconditionally: the hub may have been upgraded by an earlier run that
    # did not reach this point, and alembic is a no-op at the current schema.
    upgrade_db
  else
    maybe_fail "Failed to upgrade hub packages"
  fi
else
  log "Skipping hub package upgrade (existing system, strict mode)"
  if [[ "$JH_AUTO_UPGRADE_DB" == "always" ]]; then
    upgrade_db
  fi
fi

# 5) Stable cookie secret
COOKIE_SECRET="${JH_STATE}/jupyterhub_cookie_secret"
if [[ ! -f "$COOKIE_SECRET" ]]; then
  log "Creating persistent cookie secret"
  # Create file with correct perms atomically, then write secret
  install -m 600 -o jupyterhub -g jupyter /dev/null "$COOKIE_SECRET"
  openssl rand -hex 32 > "$COOKIE_SECRET"
fi

# 6) Required environment file (always strict)
ENV_FILE="/home/jupyterhub/etc/jupyterhub.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "ERROR: missing $ENV_FILE"
  log "Create it before starting JupyterHub."
  exit 1
fi

# 7) Single-user venv
USER_VENV="${JH_STATE}/user-venv"
if [[ ! -x "${USER_VENV}/bin/python" ]]; then
  log "Creating single-user venv at ${USER_VENV}..."
  python3 -m venv "${USER_VENV}"
fi

# Install/upgrade user-server deps (clean system or relaxed mode only).
#
# This venv is shared state: every user's notebook server runs from it and no
# release rollback can revert it. A build that might be discarded must therefore
# leave it alone, which is what JH_SKIP_USER_VENV is for.
if [[ "$JH_SKIP_USER_VENV" == "1" ]]; then
  log "Skipping user-server package install (JH_SKIP_USER_VENV=1)"
elif [[ "$CLEAN_SYSTEM" -eq 1 || "$BOOTSTRAP_MODE" != "strict" ]]; then
  log "Installing/upgrading user-server packages in ${USER_VENV} (clean=${CLEAN_SYSTEM}, mode=${BOOTSTRAP_MODE})"

  if "${USER_VENV}/bin/pip" install --upgrade pip wheel setuptools uv | tee "${PIP_LOG_DIR}/pip-user-base.out"; then
    if grep -qiE "Successfully installed|Installing collected packages" "${PIP_LOG_DIR}/pip-user-base.out"; then
      touch "$NEEDS_RESTART_FILE"
    fi
  else
    maybe_fail "Failed to upgrade base pip packages in user venv"
  fi

  if [[ ! -f "$REQ_USER" ]]; then
    log "ERROR: missing $REQ_USER"
    log "User-server packages must be installed from the release's pinned requirements."
    exit 1
  fi

  if "${USER_VENV}/bin/pip" install --upgrade -r "$REQ_USER" | tee "${PIP_LOG_DIR}/pip-user.out"; then
    if grep -qiE "Successfully installed|Installing collected packages" "${PIP_LOG_DIR}/pip-user.out"; then
      touch "$NEEDS_RESTART_FILE"
      record_freeze "$USER_VENV" user
    fi
  else
    maybe_fail "Failed to upgrade user-server packages"
  fi
else
  log "Skipping user-server package upgrade (existing system, strict mode)"
fi

log "OK (mode=${BOOTSTRAP_MODE})."