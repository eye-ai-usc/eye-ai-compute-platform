#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[install-all] Installing mount-ebs-volumes systemd service + script..."
if [[ -x "$ROOT_DIR/bin/install-mount-service.sh" ]]; then
  "$ROOT_DIR/bin/install-mount-service.sh"
else
  echo "[install-all] ERROR: missing or non-executable: $ROOT_DIR/bin/install-mount-service.sh"
  exit 1
fi

echo ""
echo "[install-all] Verifying /home and /data are mounted..."
if ! mountpoint -q /home; then
  echo "[install-all] ERROR: /home is not mounted after mount-ebs-volumes.service"
  systemctl status mount-ebs-volumes.service || true
  journalctl -u mount-ebs-volumes.service -n 200 --no-pager || true
  exit 1
fi
if ! mountpoint -q /data; then
  echo "[install-all] ERROR: /data is not mounted after mount-ebs-volumes.service"
  systemctl status mount-ebs-volumes.service || true
  journalctl -u mount-ebs-volumes.service -n 200 --no-pager || true
  exit 1
fi

echo ""
echo "[install-all] Ensuring 'jupyterhub' system user exists..."

# Optional: pin a UID/GID for stability when reusing EBS across instances
JUPYTERHUB_UID="${JUPYTERHUB_UID:-900}"
JUPYTERHUB_GID="${JUPYTERHUB_GID:-900}"

if id jupyterhub >/dev/null 2>&1; then
  EXISTING_UID="$(id -u jupyterhub)"
  if [[ -n "${JUPYTERHUB_UID}" && "${EXISTING_UID}" != "${JUPYTERHUB_UID}" ]]; then
    echo "[install-all] ERROR: user 'jupyterhub' exists with uid=${EXISTING_UID}, expected uid=${JUPYTERHUB_UID}"
    echo "[install-all] Refusing to proceed to avoid ownership/permission mismatches on /home EBS."
    exit 1
  fi
  echo "[install-all] OK: user 'jupyterhub' already exists (uid=${EXISTING_UID})."
else
  echo "[install-all] Creating user 'jupyterhub' (uid=${JUPYTERHUB_UID})..."
  adduser --disabled-password --gecos "" --uid "${JUPYTERHUB_UID}" --gid "${JUPYTERHUB_GID}" jupyterhub
fi

echo ""
echo "[install-all] Ensuring persistent /home/jupyterhub directories exist..."
mkdir -p /home/jupyterhub/{etc,state,releases}
chmod 0750 /home/jupyterhub/etc || true
chown -R jupyterhub:jupyter /home/jupyterhub/etc /home/jupyterhub/state /home/jupyterhub/releases || true

if [[ ! -f /home/jupyterhub/etc/jupyterhub.env ]]; then
  cat > /home/jupyterhub/etc/jupyterhub.env <<EOF
# JupyterHub deployment environment (systemd EnvironmentFile)
PUBLIC_HOSTNAME=https://${HOSTNAME}
GLOBUS_CLIENT_ID=...
GLOBUS_CLIENT_SECRET=...
#ALLOWED_GROUPS=
#ADMIN_GROUPS=
EOF
  chmod 0640 /home/jupyterhub/etc/jupyterhub.env || true
  if id jupyterhub >/dev/null 2>&1; then
    chown jupyterhub:jupyter /home/jupyterhub/etc/jupyterhub.env || true
  fi
  echo "[install-all] Created template: /home/jupyterhub/etc/jupyterhub.env"
fi

if [[ ! -f /home/jupyterhub/etc/quotas.env ]]; then
  cat > /home/jupyterhub/etc/quotas.env <<'EOF'
# Quota service environment (optional systemd EnvironmentFile)
# 80/100 GiB in KiB:
#QUOTA_SOFT_KIB=83886080
#QUOTA_HARD_KIB=104857600
#APPLY_EXISTING_USERS=1
EOF
  chmod 0640 /home/jupyterhub/etc/quotas.env || true
  if id jupyterhub >/dev/null 2>&1; then
    chown jupyterhub:jupyter /home/jupyterhub/etc/quotas.env || true
  fi
  echo "[install-all] Created template: /home/jupyterhub/etc/quotas.env"
fi

echo ""
echo "[install-all] Installing enable-home-quotas systemd service + script..."
if [[ -x "$ROOT_DIR/bin/install-quota-service.sh" ]]; then
  "$ROOT_DIR/bin/install-quota-service.sh"
else
  echo "[install-all] ERROR: missing or non-executable: $ROOT_DIR/bin/install-quota-service.sh"
  exit 1
fi

echo ""
echo "[install-all] Verifying quotas are ON for /home..."
if (quotaon -p /home 2>/dev/null || true) | grep -qi '^user quota on '; then
  echo "[install-all] OK: quotas are ON for /home."
else
  echo "[install-all] ERROR: quotas do not appear to be ON for /home."
  systemctl status enable-home-quotas.service || true
  journalctl -u enable-home-quotas.service -n 200 --no-pager || true
  quotaon -p /home || true
  exit 1
fi

echo "[install-all] Installing configurable-http-proxy (Node-based Hub proxy)..."
apt-get install -y nodejs npm
npm install -g configurable-http-proxy
which configurable-http-proxy || { echo "configurable-http-proxy missing"; exit 1; }

echo ""
echo "[install-all] Deploying JupyterHub (per-release) + installing jupyterhub.service..."
if [[ -x "$ROOT_DIR/bin/install-jupyterhub-service.sh" ]]; then
  "$ROOT_DIR/bin/install-jupyterhub-service.sh"
else
  echo "[install-all] ERROR: missing or non-executable: $ROOT_DIR/bin/install-jupyterhub-service.sh"
  exit 1
fi

echo ""
echo "[install-all] Installing/refreshing Caddy reverse proxy..."
if [[ -x "$ROOT_DIR/bin/install-caddy.sh" ]]; then
  "$ROOT_DIR/bin/install-caddy.sh"
else
  echo "[install-all] ERROR: missing or non-executable: $ROOT_DIR/bin/install-caddy.sh"
  exit 1
fi

echo ""
echo "[install-all] Done."
echo "Status:"
echo "  systemctl status mount-ebs-volumes.service"
echo "  systemctl status enable-home-quotas.service"
echo "  systemctl status jupyterhub"
