#!/bin/bash
# migrate_storage.sh
#
# Usage:
#   ./migrate_storage.sh <FROM_STORAGE> <TO_STORAGE> <ID1> [ID2 ...] [--remove-source]
#
# Examples:
#   KEEP source:
#     ./migrate_storage.sh HDD-ZFS-4TB SSD-ZFS-NAS 100
#
#   DELETE source:
#     ./migrate_storage.sh HDD-ZFS-4TB SSD-ZFS-NAS 100 --remove-source

set -o pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <FROM_STORAGE> <TO_STORAGE> <ID1> [ID2 ...] [--remove-source]"
  exit 1
fi

SRC="$1"
DST="$2"
shift 2

REMOVE_SOURCE=0
IDS=()

for arg in "$@"; do
  if [ "$arg" = "--remove-source" ]; then
    REMOVE_SOURCE=1
  else
    IDS+=("$arg")
  fi
done

if [ ${#IDS[@]} -eq 0 ]; then
  echo "Error: no VM/CT IDs specified."
  exit 1
fi

if [ "$SRC" = "$DST" ]; then
  echo "ERROR: FROM_STORAGE and TO_STORAGE are the same."
  exit 1
fi

# delete flag values
if [ $REMOVE_SOURCE -eq 1 ]; then
  DELETE_FLAG_VM="--delete 1"
  DELETE_FLAG_CT="--delete 1"
else
  DELETE_FLAG_VM="--delete 0"
  DELETE_FLAG_CT="--delete 0"
fi

# Storage validation (best effort)
pvesm status | awk 'NR>1 {print $1}' | grep -qx "$SRC" || echo "WARNING: Source storage '$SRC' not found"
pvesm status | awk 'NR>1 {print $1}' | grep -qx "$DST" || echo "WARNING: Target storage '$DST' not found"

move_vm() {
  local VMID="$1"
  echo "ID $VMID is a VM"

  local DISKS
  DISKS=$(qm config "$VMID" | awk -v s="$SRC" -F: '$2 ~ " "s {gsub(/^[ \t]+/,"",$1); print $1}')

  if [ -z "$DISKS" ]; then
    echo "  VM $VMID: no disks on $SRC, skipping."
    return
  fi

  local STATE
  STATE=$(qm status "$VMID" | awk '{print $2}')

  if [ "$STATE" = "running" ]; then
    echo "  VM $VMID is running - you may see a brief pause while storage moves."
  fi

  for DISK in $DISKS; do
    echo "  VM $VMID: moving $DISK from $SRC to $DST"
    qm disk move "$VMID" "$DISK" "$DST" $DELETE_FLAG_VM
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
    pct move-volume "$CTID" "$VOL" "$DST" $DELETE_FLAG_CT
  done

  if [ $WAS_RUNNING -eq 1 ]; then
    echo "  CT $CTID: starting again"
    pct start "$CTID"
  fi
}

echo "=== MOVE JOB START ==="
echo "FROM:   $SRC"
echo "TO:     $DST"
echo "DELETE SOURCE: $([ $REMOVE_SOURCE -eq 1 ] && echo YES || echo NO)"
echo "TARGET IDS: ${IDS[*]}"
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
