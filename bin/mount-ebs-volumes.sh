#!/usr/bin/env bash
set -euo pipefail

# Mount the EBS volumes backing /home and /data, set shared permissions, and
# optionally set up swap on the instance-store NVMe.
#
# DESIGN RULES
#
# 1. On an already-configured host this script must be a fast no-op. Everything
#    it sets up is recorded in /etc/fstab by UUID and mounted by systemd before
#    this unit runs. If it finds the mounts in place, it does nothing.
#
# 2. Nothing destructive or long-running happens without an explicit opt-in.
#    mkfs and the one-time /home migration are gated behind environment flags
#    and a sentinel, so neither is reachable from an ordinary boot.
#
# 3. Devices are identified by UUID wherever possible. Kernel names like
#    /dev/nvme1n1 are not stable across boots, and this host has four NVMe
#    controllers.
#
# Environment:
#   ALLOW_MKFS=1            permit formatting a device that has no filesystem
#   ALLOW_HOME_MIGRATION=1  permit the one-time rootfs /home -> EBS copy
#   HOME_DEV / DATA_DEV     fallback device paths, used only when the mount is
#                           absent from fstab and not already mounted

ALLOW_MKFS="${ALLOW_MKFS:-0}"
ALLOW_HOME_MIGRATION="${ALLOW_HOME_MIGRATION:-0}"

HOME_DEV="${HOME_DEV:-/dev/nvme1n1}"
DATA_DEV="${DATA_DEV:-/dev/nvme2n1}"

HOME_TMP_MNT="/mnt/home"
STATE_DIR="/var/lib/eye-ai-compute"
MIGRATION_SENTINEL="${STATE_DIR}/home-migrated"

log()  { echo "[mount-ebs] $*"; }
warn() { echo "[mount-ebs] WARNING: $*" >&2; }
die()  { echo "[mount-ebs] ERROR: $*" >&2; exit 1; }

# True when the mountpoint already has an fstab entry. If it does, systemd has
# already mounted it (this unit is ordered After=local-fs.target) and there is
# nothing for us to do.
has_fstab_entry() {
  local mnt="$1"
  awk -v m="$mnt" '!/^[[:space:]]*#/ && $2 == m { found = 1 } END { exit !found }' /etc/fstab
}

mkfs_if_needed() {
  local dev="$1"
  if blkid "$dev" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$ALLOW_MKFS" != "1" ]]; then
    # Refusing here is the point. Kernel device names shift between boots, so an
    # unattended mkfs in the boot path can format the wrong disk.
    die "$dev has no filesystem and ALLOW_MKFS is not set; refusing to format. Run with ALLOW_MKFS=1 by hand once you have confirmed the device."
  fi
  log "Formatting $dev as ext4 (ALLOW_MKFS=1)..."
  mkfs.ext4 -F "$dev"
}

ensure_fstab_entry() {
  local uuid="$1" mnt="$2" opts="$3"
  if has_fstab_entry "$mnt"; then
    return 0
  fi
  log "Adding fstab entry for $mnt (UUID=$uuid)"
  echo "UUID=${uuid}  ${mnt}  ext4  ${opts}  0  2" >> /etc/fstab
}

ensure_mount() {
  local dev="$1" mnt="$2" opts="$3"

  # Fast path: already mounted. Nothing to verify, nothing to change.
  if mountpoint -q "$mnt"; then
    return 0
  fi

  mkdir -p "$mnt"

  if has_fstab_entry "$mnt"; then
    # fstab knows about it but systemd did not mount it. Let mount resolve the
    # device from fstab rather than trusting a kernel name.
    log "$mnt is in fstab but not mounted; mounting"
    mount "$mnt"
    return 0
  fi

  [[ -b "$dev" ]] || die "$dev is not a block device and $mnt is not in fstab"
  mkfs_if_needed "$dev"
  local uuid
  uuid="$(blkid -s UUID -o value "$dev")" || die "could not read UUID from $dev"
  ensure_fstab_entry "$uuid" "$mnt" "$opts"
  mount "$mnt"
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
    log "Swap target $mnt is not mounted; skipping swapfile setup."
    return
  fi

  if swapon --show | awk '{print $1}' | grep -qx "$swapfile"; then
    return
  fi

  if [ -f "$swapfile" ]; then
    log "Swapfile $swapfile exists but is not active; enabling swap."
    chmod 600 "$swapfile"
    mkswap "$swapfile"
    swapon "$swapfile"
  else
    local total_bytes
    total_bytes=$(df --output=size -B1 "$mnt" | tail -n1 | tr -d ' ')
    if [ -z "$total_bytes" ] || [ "$total_bytes" -le 0 ]; then
      warn "Unable to determine filesystem size for $mnt; skipping swapfile setup."
      return
    fi
    # 95% leaves the volume effectively full. Kept as-is to avoid changing the
    # existing swap size on a running host, but see the note in README: this is
    # why /opt/dlami/nvme reports 0 bytes available.
    local swap_bytes=$(( total_bytes * 95 / 100 ))
    log "Creating swapfile of size $swap_bytes bytes at $swapfile..."
    fallocate -l "$swap_bytes" "$swapfile"
    chmod 600 "$swapfile"
    mkswap "$swapfile"
    swapon "$swapfile"
  fi

  if ! grep -qE "^${swapfile}[[:space:]]" /etc/fstab; then
    echo "$swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

# One-time bootstrap only: copy a fresh instance's rootfs /home onto the EBS
# volume before that volume takes over the mountpoint.
#
# Four independent guards, because every one of them has a failure mode that
# ends in a multi-minute rsync during boot:
#   - explicit opt-in flag
#   - sentinel recording that it already ran
#   - /home must not already be a mountpoint
#   - the target device must not be mounted anywhere else (this is what turns
#     the copy into a volume-against-itself rsync when the mount lands mid-run)
migrate_existing_home_into_home_dev() {
  local src="/home"
  local tmp="${HOME_TMP_MNT}"

  if [[ "$ALLOW_HOME_MIGRATION" != "1" ]]; then
    return 0
  fi
  if [[ -e "$MIGRATION_SENTINEL" ]]; then
    log "Home migration already recorded at $MIGRATION_SENTINEL; skipping."
    return 0
  fi
  if mountpoint -q "$src"; then
    log "$src is already a mountpoint; skipping migration."
    return 0
  fi
  if [ ! -d "$src" ] || [ -z "$(ls -A "$src" 2>/dev/null || true)" ]; then
    log "$src is empty; no migration needed."
    return 0
  fi
  if findmnt -S "$HOME_DEV" >/dev/null 2>&1; then
    warn "$HOME_DEV is already mounted elsewhere; refusing to migrate (this is the self-copy case)."
    return 0
  fi

  log "Migrating existing $src into $HOME_DEV via temporary mount at $tmp..."
  mkdir -p "$tmp"
  if ! mountpoint -q "$tmp"; then
    mount "$HOME_DEV" "$tmp"
  fi
  rsync -aAX "$src"/ "$tmp"/
  sync
  umount "$tmp"

  mkdir -p "$STATE_DIR"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$MIGRATION_SENTINEL"
  log "Migration completed; recorded at $MIGRATION_SENTINEL"
}

ensure_nvme_mount() {
  local mnt="/opt/dlami/nvme"
  local lv_dev="/dev/mapper/vg.01-lv_ephemeral"

  mkdir -p "$mnt"
  if mountpoint -q "$mnt"; then
    return 0
  fi

  mount "$mnt" >/dev/null 2>&1 || true
  if mountpoint -q "$mnt"; then
    return 0
  fi

  if [[ -b "$lv_dev" ]]; then
    local uuid
    uuid=$(blkid -s UUID -o value "$lv_dev" 2>/dev/null || true)
    if [[ -n "$uuid" ]] && ! has_fstab_entry "$mnt"; then
      echo "UUID=${uuid}  ${mnt}  ext4  defaults  0  2" >> /etc/fstab
    fi
    mount "$mnt" >/dev/null 2>&1 || true
  fi
}

log "Preparing /home and /data mounts..."

migrate_existing_home_into_home_dev

ensure_mount "$HOME_DEV" /home "defaults,nofail,usrquota"
ensure_mount "$DATA_DEV" /data "defaults,nofail"

setup_shared_perms
ensure_nvme_mount
setup_swap_nvme

# Named mountpoints only. Bare `df -h` stats every mounted filesystem, so one
# unresponsive FUSE or network mount would hang this unit indefinitely.
log "Current mounts:"
df -h /home /data /opt/dlami/nvme 2>/dev/null || true
