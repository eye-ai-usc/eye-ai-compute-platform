#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: must be run as root" >&2
  exit 1
fi

if [[ "$#" -lt 1 ]]; then
  echo "Usage: grant-sudo <user1> [user2 ...]" >&2
  exit 1
fi

SUDOERS_FILE="/etc/sudoers.d/90-nopasswd-users"

for user in "$@"; do
  if ! id "$user" >/dev/null 2>&1; then
    echo "WARNING: user '$user' does not exist; skipping" >&2
    continue
  fi

  entry="${user} ALL=(ALL) NOPASSWD:ALL"

  if [[ -f "$SUDOERS_FILE" ]] && grep -qxF "$entry" "$SUDOERS_FILE"; then
    echo "[grant-sudo] $user already has NOPASSWD sudo"
    continue
  fi

  echo "$entry" >> "$SUDOERS_FILE"
  echo "[grant-sudo] granted NOPASSWD sudo to $user"
done

chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null
