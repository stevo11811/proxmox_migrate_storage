#!/bin/bash
# move-storage.sh
#
# Usage:
#   move-storage.sh <FROM_STORAGE> <TO_STORAGE> <ID1> [ID2 ...]
#
# Example:
#   move-storage.sh HDD-ZFS-6TB SSD-ZFS-NAS 101 102 203

set -o pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <FROM_STORAGE> <TO_STORAGE> <ID1> [ID2 ...]"
  exit 1
fi

SRC="$1"
DST="$2"
shift 2

if [ "$SRC" = "$DST" ]; then
  echo "ERROR: FROM_STORAGE and TO_STORAGE are the same ($SRC)."
  exit 1
fi

# Verify storages exist (best effort)
if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$SRC"; then
  echo "WARNING: Source storage '$SRC' not found in 'pvesm status'."
fi
if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$DST"; then
  echo "WARNING: Destination storage '$DST' not found in 'pvesm status'."
fi

move_vm() {
  local VMID="$1"

  echo "ID $VMID is a VM"

  # Find disks whose storage is $SRC
  local DISKS
  DISKS=$(qm config "$VMID" | awk -v s="$SRC" -F: '$2 ~ " "s {gsub(/^[ \t]+/,"",$1); print $1}')

  if [ -z "$DISKS" ]; then
    echo "  VM $VMID: no disks on $SRC, skipping."
    return
  fi

  local STATE
  STATE=$(qm status "$VMID" | awk '{print $2}')

  for DISK in $DISKS; do
    if [ "$STATE" = "running" ]; then
      echo "  VM $VMID: live-moving $DISK from $SRC to $DST"
      qm disk move "$VMID" "$DISK" "$DST" --online 1 --delete 1
    else
      echo "  VM $VMID: offline-moving $DISK from $SRC to $DST"
      qm disk move "$VMID" "$DISK" "$DST" --delete 1
    fi
  done
}

move_ct() {
  local CTID="$1"

  echo "ID $CTID is a CT"

  local VOLS
  VOLS=$(pct config "$CTID" | awk -v s="$SRC" -F: '$2 ~ " "s {gsub(/^[ \t]+/,"",$1); print $1}')

  if [ -z "$VOLS" ]; then
    echo "  CT $CTID: no volumes on $SRC, skipping."
    return
  fi

  local WAS_RUNNING=0
  if pct status "$CTID" | grep -q "status: running"; then
    WAS_RUNNING=1
    echo "  CT $CTID: stopping for move"
    pct stop "$CTID"
  fi

  for VOL in $VOLS; do
    echo "  CT $CTID: moving $VOL from $SRC to $DST"
    pct move-volume "$CTID" "$VOL" "$DST" --delete
  done

  if [ $WAS_RUNNING -eq 1 ]; then
    echo "  CT $CTID: starting again"
    pct start "$CTID"
  fi
}

echo "Moving from storage '$SRC' to '$DST' for IDs: $*"
for ID in "$@"; do
  echo "=== Processing ID $ID ==="

  if qm config "$ID" >/dev/null 2>&1; then
    move_vm "$ID"
  elif pct config "$ID" >/dev/null 2>&1; then
    move_ct "$ID"
  else
    echo "  ID $ID: not found as VM or CT, skipping."
  fi
done

echo "Done."
