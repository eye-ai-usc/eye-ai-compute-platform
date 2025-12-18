#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "[install-caddy] ERROR: must run as root (use sudo -i)."
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

ENV_FILE="/home/jupyterhub/etc/jupyterhub.env"
TMPL="${ROOT_DIR}/etc/Caddyfile.template"
DST="/etc/caddy/Caddyfile"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[install-caddy] ERROR: missing $ENV_FILE"
  echo "[install-caddy] Create it first and set PUBLIC_HOSTNAME=host.example.org"
  exit 1
fi

if [[ ! -f "$TMPL" ]]; then
  echo "[install-caddy] ERROR: missing template: $TMPL"
  exit 1
fi

# Load env vars from operator-controlled env file
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"
if [[ -z "$PUBLIC_HOSTNAME" ]]; then
  echo "[install-caddy] ERROR: PUBLIC_HOSTNAME is not set in $ENV_FILE"
  exit 1
fi

# Basic sanity: reject schemes/paths (we want a bare host[:port])
if [[ "$PUBLIC_HOSTNAME" == *"://"* || "$PUBLIC_HOSTNAME" == */* ]]; then
  echo "[install-caddy] ERROR: PUBLIC_HOSTNAME must be a bare hostname (optionally host:port)."
  echo "[install-caddy] Got: $PUBLIC_HOSTNAME"
  exit 1
fi

echo "[install-caddy] Installing Caddy (apt)..."
apt-get install -y caddy

echo "[install-caddy] Writing $DST for host: $PUBLIC_HOSTNAME"
install -d -m 0755 /etc/caddy
sed "s/{{HOST}}/${PUBLIC_HOSTNAME}/g" "$TMPL" > "$DST"

echo "[install-caddy] Validating Caddyfile..."
caddy fmt --overwrite "$DST"
caddy validate --config "$DST"

echo "[install-caddy] Enabling + restarting Caddy..."
systemctl enable caddy
systemctl restart caddy

echo "[install-caddy] Done."
echo "Check:"
echo "  systemctl status caddy"
echo "  journalctl -u caddy -n 200 --no-pager"
