#!/usr/bin/env bash
set -euo pipefail
umask 022

# JupyterHub release/bootstrap script (runs on host via systemd ExecStartPre and via update service / timer)
#
# Responsibilities:
#   - ensure /home is mounted
#   - ensure shared state dirs exist under /home/jupyterhub/state
#   - ensure per-release venv exists under /home/jupyterhub/current/venv
#   - install/upgrade jupyterhub deps into that venv
#   - ensure cookie secret exists (stable across releases)
#
# BOOTSTRAP_MODE:
#   strict  (default): failures are fatal (clean-system bootstrap)
#   relaxed           failures are warnings (timer/manual updates)

BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-strict}"
NEEDS_RESTART_FILE="/home/jupyterhub/state/NEEDS_RESTART"

JH_ROOT="${JH_ROOT:-/home/jupyterhub}"
JH_APP="${JH_ROOT}/current"
JH_VENV="${JH_APP}/venv"
JH_STATE="${JH_ROOT}/state"

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
if [[ "$CLEAN_SYSTEM" -eq 1 || "$BOOTSTRAP_MODE" != "strict" ]]; then
  log "Installing/upgrading hub packages in ${JH_VENV} (clean=${CLEAN_SYSTEM}, mode=${BOOTSTRAP_MODE})"

  if "${JH_VENV}/bin/pip" install --upgrade pip wheel setuptools | tee /tmp/pip-hub-base.out; then
    # Touch restart marker if pip actually installed or built packages
    if grep -qiE "Successfully installed|Installing collected packages" /tmp/pip-hub-base.out; then
      touch "$NEEDS_RESTART_FILE"
    fi
  else
    maybe_fail "Failed to upgrade base pip packages in hub venv"
  fi

  if "${JH_VENV}/bin/pip" install --upgrade jupyterhub jupyterlab oauthenticator[globus] | tee /tmp/pip-hub.out; then
    if grep -qiE "Successfully installed|Installing collected packages" /tmp/pip-hub.out; then
      touch "$NEEDS_RESTART_FILE"
    fi
  else
    maybe_fail "Failed to upgrade hub packages"
  fi
else
  log "Skipping hub package upgrade (existing system, strict mode)"
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

# Install/upgrade user-server deps (clean system or relaxed mode only)
if [[ "$CLEAN_SYSTEM" -eq 1 || "$BOOTSTRAP_MODE" != "strict" ]]; then
  log "Installing/upgrading user-server packages in ${USER_VENV} (clean=${CLEAN_SYSTEM}, mode=${BOOTSTRAP_MODE})"

  if "${USER_VENV}/bin/pip" install --upgrade pip wheel setuptools uv | tee /tmp/pip-user-base.out; then
    if grep -qiE "Successfully installed|Installing collected packages" /tmp/pip-user-base.out; then
      touch "$NEEDS_RESTART_FILE"
    fi
  else
    maybe_fail "Failed to upgrade base pip packages in user venv"
  fi

  if "${USER_VENV}/bin/pip" install --upgrade jupyterlab jupyter_server | tee /tmp/pip-user.out; then
    if grep -qiE "Successfully installed|Installing collected packages" /tmp/pip-user.out; then
      touch "$NEEDS_RESTART_FILE"
    fi
  else
    maybe_fail "Failed to upgrade user-server packages"
  fi
else
  log "Skipping user-server package upgrade (existing system, strict mode)"
fi

log "OK (mode=${BOOTSTRAP_MODE})."