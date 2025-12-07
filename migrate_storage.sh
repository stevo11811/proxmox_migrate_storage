#!/bin/bash
# move-storage.sh
#
# Usage:
#   move-storage.sh <FROM_STORAGE> <TO_STORAGE> <ID1> [ID2 ...] [--remove-source]
#
# Examples:
#   KEEP source:
#     ./move-storage.sh HDD-ZFS-6TB SSD-ZFS-NAS 101 102 203
#
#   DELETE source:
#     ./move-storage.sh HDD-ZFS-6TB SSD-ZFS-NAS 101 102 --remove-source

set -o pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <FROM_STORAGE> <TO_STORAGE> <ID1> [ID2 ...] [--remove-source]"
  exit 1
fi

SRC="$1"
DST="$2"
shift 2

DELETE_FLAG="--delete 0"
if [[ "$*" == *"--remove-source"* ]]; then
  DELETE_FLAG="--delete 1"
  # Remove flag from ID list
  IDS=($(echo "$@" | sed 's/--remove-source//g'))
else
  IDS=("$@")
fi

if [ "$SRC" = "$DST" ]; then
  echo "ERROR: FROM_STORAGE and TO_STORAGE are the same."
  exit 1
fi

# Storage validation (best effort)
pvesm status | awk 'NR>1 {print $1}' | grep -qx "$SRC" || echo "WARNING: Source storage '$SRC' not found"
pvesm status | awk 'NR>1 {print $1}' | grep -qx "$DST" || echo "WARNING: Target storage '$DST' not found"

move_vm() {
  local VMID="$1"
  echo "ID $VMID is a VM"

  DISKS=$(qm config "$VMID" | awk -v s="$SRC" -F: '$2 ~ " "s {gsub(/^[ \t]+/,"",$1); print $1}')
  [ -z "$DISKS" ] && echo "  VM $VMID: no disks on $SRC, skipping." && return

  STATE=$(qm status "$VMID" | awk '{print $2}')

  for DISK in $DISKS; do
    if [ "$STATE" = "running" ]; then
      echo "  VM $VMID: live-moving $DISK"
      qm disk move "$VMID" "$DISK" "$DST" --online 1 $DELETE_FLAG
    else
      echo "  VM $VMID: offline-moving $DISK"
      qm disk move "$VMID" "$DISK" "$DST" $DELETE_FLAG
    fi
  done
}

move_ct() {
  local CTID="$1"
  echo "ID $CTID is a CT"

  VOLS=$(pct config "$CTID" | awk -v s="$SRC" -F: '$2 ~ " "s {gsub(/^[ \t]+/,"",$1); print $1}')
  [ -z "$VOLS" ] && echo "  CT $CTID: no volumes on $SRC, skipping." && return

  WAS_RUNNING=0
  pct status "$CTID" | grep -q "running" && WAS_RUNNING=1 && pct stop "$CTID"

  for VOL in $VOLS; do
    echo "  CT $CTID: moving $VOL"
    pct move-volume "$CTID" "$VOL" "$DST" $DELETE_FLAG
  done

  [ $WAS_RUNNING -eq 1 ] && pct start "$CTID"
}

echo "=== MOVE JOB START ==="
echo "FROM:   $SRC"
echo "TO:     $DST"
echo "DELETE: $([[ "$DELETE_FLAG" == "--delete 1" ]] && echo YES || echo NO)"
echo "TARGET: ${IDS[*]}"
echo "======================="

for ID in "${IDS[@]}"; do
  echo ">>> Processing $ID"
  if qm config "$ID" >/dev/null 2>&1; then
    move_vm "$ID"
  elif pct config "$ID" >/dev/null 2>&1; then
    move_ct "$ID"
  else
    echo "  ID $ID: not found as VM or CT, skipping."
  fi
done

echo "=== DONE ==="
