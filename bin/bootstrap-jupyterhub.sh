#!/usr/bin/env bash
set -euo pipefail
umask 022

# JupyterHub release/bootstrap script (runs on host via systemd ExecStartPre)
# Responsibilities:
#   - ensure /home is mounted
#   - ensure shared state dirs exist under /home/jupyterhub/state
#   - ensure per-release venv exists under /home/jupyterhub/current/venv
#   - install/upgrade jupyterhub deps into that venv
#   - ensure cookie secret exists (stable across releases)

JH_ROOT="${JH_ROOT:-/home/jupyterhub}"
JH_APP="${JH_ROOT}/current"
JH_VENV="${JH_APP}/venv"
JH_STATE="${JH_ROOT}/state"

# 1) Basic preconditions
if ! mountpoint -q /home; then
  echo "[jupyterhub-bootstrap] ERROR: /home is not a mountpoint (mount-ebs-volumes.service should run first)"
  exit 1
fi

if [[ ! -d "$JH_APP" ]]; then
  echo "[jupyterhub-bootstrap] ERROR: $JH_APP does not exist (deploy a release first)"
  exit 1
fi

# 2) Ensure shared state dirs
mkdir -p "${JH_STATE}/pid" "${JH_STATE}/logs"

# 3) Ensure per-release venv
if [[ ! -x "${JH_VENV}/bin/python" ]]; then
  echo "[jupyterhub-bootstrap] Creating per-release venv at ${JH_VENV}..."
  python3 -m venv "${JH_VENV}"
fi

# 4) Install/upgrade hub deps (keep minimal; add more only if needed)
echo "[jupyterhub-bootstrap] Installing/upgrading hub packages in ${JH_VENV}..."
"${JH_VENV}/bin/pip" install --upgrade pip wheel setuptools
"${JH_VENV}/bin/pip" install --upgrade jupyterhub jupyterlab oauthenticator[globus]

# 5) Stable cookie secret (recommended, and matches new config path)
COOKIE_SECRET="${JH_STATE}/jupyterhub_cookie_secret"
if [[ ! -f "$COOKIE_SECRET" ]]; then
  echo "[bootstrap] Creating persistent cookie secret"
  # Create file with correct perms atomically, then write secret
  install -m 600 -o jupyterhub -g jupyter /dev/null "$COOKIE_SECRET"
  openssl rand -hex 32 > "$COOKIE_SECRET"
fi

ENV_FILE="/home/jupyterhub/etc/jupyterhub.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[bootstrap] ERROR: missing $ENV_FILE"
  echo "[bootstrap] Create it before starting JupyterHub."
  exit 1
fi

USER_VENV="${JH_STATE}/user-venv"
if [[ ! -x "${USER_VENV}/bin/python" ]]; then
  echo "[bootstrap] Creating single-user venv at ${USER_VENV}..."
  python3 -m venv "${USER_VENV}"
fi
echo "[bootstrap] Installing user-server packages into ${USER_VENV}..."
"${USER_VENV}/bin/pip" install --upgrade pip wheel setuptools uv
"${USER_VENV}/bin/pip" install --upgrade jupyterlab jupyter_server


echo "[jupyterhub-bootstrap] OK."
