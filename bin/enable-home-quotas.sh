#!/usr/bin/env bash
set -euo pipefail

HOME_QUOTA_FS="${HOME_QUOTA_FS:-/home}"

# 50/60 GiB in KiB
QUOTA_SOFT_KIB="${QUOTA_SOFT_KIB:-$((50*1024*1024))}"
QUOTA_HARD_KIB="${QUOTA_HARD_KIB:-$((60*1024*1024))}"

# Apply quotas to existing real users (UID>=1000)? 1=yes, 0=no
APPLY_EXISTING_USERS="${APPLY_EXISTING_USERS:-1}"

# Ensure quota tools exist
if ! command -v quotacheck >/dev/null 2>&1 || ! command -v setquota >/dev/null 2>&1; then
  echo "[quotas] Installing quota tools..."
  apt-get update
  apt-get install -y quota
fi

echo "[quotas] Enabling ext4 user quotas on ${HOME_QUOTA_FS}..."

if ! mountpoint -q "${HOME_QUOTA_FS}"; then
  echo "[quotas] ERROR: ${HOME_QUOTA_FS} is not a mountpoint."
  exit 1
fi

if ! findmnt -no OPTIONS "${HOME_QUOTA_FS}" | tr ',' '\n' | grep -qx 'usrquota'; then
  echo "[quotas] ERROR: ${HOME_QUOTA_FS} is not mounted with usrquota."
  echo "[quotas] Fix /etc/fstab for ${HOME_QUOTA_FS} to include 'usrquota', then remount."
  exit 1
fi

echo "[quotas] Running quotacheck + quotaon..."

quotaoff -u "${HOME_QUOTA_FS}" >/dev/null 2>&1 || true
quotaoff -g "${HOME_QUOTA_FS}" >/dev/null 2>&1 || true

rm -f "${HOME_QUOTA_FS}/aquota.user.new" "${HOME_QUOTA_FS}/aquota.group.new"

quotacheck -F vfsv1 -cufm "${HOME_QUOTA_FS}"
quotaon -u "${HOME_QUOTA_FS}"

if (quotaon -p "${HOME_QUOTA_FS}" 2>/dev/null || true) | grep -qi '^user quota on '; then
  echo "[quotas] OK: user quotas are ON for ${HOME_QUOTA_FS}."
else
  echo "[quotas] ERROR: user quotas do not appear to be ON for ${HOME_QUOTA_FS}."
  quotaon -p "${HOME_QUOTA_FS}" || true
  exit 1
fi

if [[ "${APPLY_EXISTING_USERS}" == "1" ]]; then
  echo "[quotas] Applying ${QUOTA_SOFT_KIB}/${QUOTA_HARD_KIB} KiB quotas to existing users with homes under ${HOME_QUOTA_FS}..."
  while IFS=: read -r user _ uid _ _ home _; do
    [[ "${uid}" -ge 1000 ]] || continue
    [[ "${home}" == "${HOME_QUOTA_FS}"/* ]] || continue
    setquota -u "${user}" "${QUOTA_SOFT_KIB}" "${QUOTA_HARD_KIB}" 0 0 "${HOME_QUOTA_FS}" || \
      echo "[quotas] WARNING: setquota failed for ${user}"
  done < /etc/passwd
else
  echo "[quotas] APPLY_EXISTING_USERS=0; skipping per-user quota application."
fi

echo "[quotas] Done."
