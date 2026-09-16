#!/usr/bin/env bash
set -euo pipefail

# Apply the per-spawn umask, then hand off to the single-user server.
#
# Why a wrapper exists at all: jupyterhub_config.py sets UMASK in
# Spawner.environment, but umask is a process attribute, not an environment
# variable -- nothing reads $UMASK on its own. With Spawner.cmd pointing
# straight at the jupyterhub-singleuser binary there was no shell in the
# chain to apply it, so the setting was inert and kernels silently inherited
# systemd's default 0022.
#
# 0002 is what lets a second user write the shared deriva-ml bag cache on
# /data. It is safe because every account has a private primary group and
# shares only the secondary 'jupyter' group, so a looser umask exposes
# nothing under /home.

umask "${UMASK:-0002}"

exec "${SINGLEUSER_BIN:-/home/jupyterhub/current/venv/bin/jupyterhub-singleuser}" "$@"
