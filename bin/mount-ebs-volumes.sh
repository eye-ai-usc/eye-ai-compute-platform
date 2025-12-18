#!/usr/bin/env bash
set -euo pipefail

HOME_DEV="${HOME_DEV:-/dev/nvme1n1}"
DATA_DEV="${DATA_DEV:-/dev/nvme2n1}"

HOME_TMP_MNT="/mnt/home"

mkfs_if_needed() {
  local dev="$1"
  if ! blkid "$dev" >/dev/null 2>&1; then
    echo "Formatting $dev as ext4..."
    mkfs.ext4 -F "$dev"
  fi
}

ensure_fstab_entry() {
  local uuid="$1"
  local mnt="$2"
  local opts="$3"
  if ! grep -q "UUID=${uuid}  ${mnt} " /etc/fstab; then
    echo "UUID=${uuid}  ${mnt}  ext4  ${opts}  0  2" >> /etc/fstab
  fi
}

ensure_mount() {
  local dev="$1" mnt="$2" opts="$3"
  mkdir -p "$mnt"
  local uuid
  uuid=$(blkid -s UUID -o value "$dev")
  ensure_fstab_entry "$uuid" "$mnt" "$opts"
  if ! mountpoint -q "$mnt"; then
    mount "$mnt"
  fi
}

setup_shared_perms() {
  getent group jupyter >/dev/null || groupadd -g 900 jupyter
  chgrp jupyter /data
  chmod 2775 /data
}

setup_swap_nvme() {
  local mnt="/opt/dlami/nvme"
  local swapfile="${mnt}/swapfile"

  if ! mountpoint -q "$mnt"; then
    echo "Swap target $mnt is not mounted; skipping swapfile setup on NVMe."
    return
  fi

  if swapon --show | awk '{print $1}' | grep -qx "$swapfile"; then
    echo "Swapfile $swapfile already active; skipping creation."
    return
  fi

  if [ -f "$swapfile" ]; then
    echo "Swapfile $swapfile exists but is not active; enabling swap."
    chmod 600 "$swapfile"
    mkswap "$swapfile"
    swapon "$swapfile"
  else
    local total_bytes
    total_bytes=$(df --output=size -B1 "$mnt" | tail -n1 | tr -d ' ')

    if [ -z "$total_bytes" ] || [ "$total_bytes" -le 0 ]; then
      echo "Unable to determine filesystem size for $mnt; skipping swapfile setup."
      return
    fi

    local swap_bytes=$(( total_bytes * 95 / 100 ))
    echo "Creating swapfile of size $swap_bytes bytes at $swapfile on $mnt..."
    fallocate -l "$swap_bytes" "$swapfile"
    chmod 600 "$swapfile"
    mkswap "$swapfile"
    swapon "$swapfile"
  fi

  if ! grep -qE "^${swapfile}[[:space:]]" /etc/fstab; then
    echo "$swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

migrate_existing_home_into_home_dev() {
  local src="/home"
  local tmp="${HOME_TMP_MNT}"

  # Only migrate if /home isn't mounted yet and has content
  if mountpoint -q "$src"; then
    echo "/home is already a mountpoint; skipping migration."
    return
  fi
  if [ ! -d "$src" ] || [ -z "$(ls -A "$src" 2>/dev/null || true)" ]; then
    echo "/home is empty; no migration needed."
    return
  fi

  echo "Migrating existing /home contents into HOME_DEV via temporary mount at $tmp..."

  mkdir -p "$tmp"

  # If tmp isn't mounted, mount the HOME_DEV there (without relying on fstab)
  if ! mountpoint -q "$tmp"; then
    mount "$HOME_DEV" "$tmp"
  fi

  # Copy rootfs /home -> EBS home filesystem
  rsync -aAX "$src"/ "$tmp"/

  sync

  # Unmount temp mount so we can mount it at /home cleanly
  umount "$tmp"

  echo "Migration completed."
}

echo "Preparing /home and /data mounts..."

mkfs_if_needed "$HOME_DEV"
mkfs_if_needed "$DATA_DEV"

# Migrate any existing /home contents into the HOME_DEV filesystem before mounting it at /home.
migrate_existing_home_into_home_dev

ensure_mount "$HOME_DEV" /home "defaults,nofail,usrquota"
ensure_mount "$DATA_DEV" /data "defaults,nofail"

setup_shared_perms
setup_swap_nvme

echo "Current mounts:"
df -h | egrep ' /home$| /data$|/opt/dlami/nvme' || true
