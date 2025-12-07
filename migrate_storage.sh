#!/bin/bash
# migrate_storage.sh
#
# Usage:
#   ./migrate_storage.sh <TO_STORAGE> <ID1> [ID2 ...] [--remove-source]
#
# Example:
#   ./migrate_storage.sh SSD-ZFS-NAS 100 101 102
#   ./migrate_storage.sh SSD-ZFS-NAS 100 --remove-source

set -o pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <TO_STORAGE> <ID1> [ID2 ...] [--remove-source]"
  exit 1
fi

DST="$1"
shift

REMOVE_SOURCE=0
IDS=()

# Parse args: collect IDs, detect --remove-source
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

# delete flags
if [ $REMOVE_SOURCE -eq 1 ]; then
  DELETE_FLAG_VM="--delete 1"
  DELETE_FLAG_CT="--delete"      # flag only
else
  DELETE_FLAG_VM="--delete 0"
  DELETE_FLAG_CT=""              # nothing
fi

# Best-effort storage validation
if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$DST"; then
  echo "WARNING: Destination storage '$DST' not found in 'pvesm status'."
fi

move_vm() {
  local VMID="$1"
  echo "ID $VMID is a VM"

  # Find all disks whose storage != DST
  local DISKS
  DISKS=$(qm config "$VMID" | awk -v dst="$DST" -F: '
    /^(ide|sata|scsi|virtio|efidisk|tpmstate|unused)[0-9]+/ || /^mp[0-9]+/ {
      key=$1
      sub(/^[ \t]+/,"",key)
      val=$2
      sub(/^[ \t]+/,"",val)
      split(val,a,",")
      # first segment is "storage:volname"
      split(a[1],b,":")
      storage=b[1]
      if (storage != dst) {
        print key
      }
    }
  ')

  if [ -z "$DISKS" ]; then
    echo "  VM $VMID: all disks already on $DST, nothing to move."
    return
  fi

  local STATE
  STATE=$(qm status "$VMID" | awk '{print $2}')

  if [ "$STATE" = "running" ]; then
    echo "  VM $VMID is running - Proxmox may allow online move, otherwise it will error."
  fi

  for DISK in $DISKS; do
    echo "  VM $VMID: moving $DISK -> $DST"
    qm disk move "$VMID" "$DISK" "$DST" $DELETE_FLAG_VM
  done
}

move_ct() {
  local CTID="$1"
  echo "ID $CTID is a CT"

  # Find all volumes (rootfs/mpX) whose storage != DST
  local VOLS
  VOLS=$(pct config "$CTID" | awk -v dst="$DST" -F: '
    /^rootfs/ || /^mp[0-9]+/ {
      key=$1
      sub(/^[ \t]+/,"",key)
      val=$2
      sub(/^[ \t]+/,"",val)
      split(val,a,",")
      split(a[1],b,":")
      storage=b[1]
      if (storage != dst) {
        print key
      }
    }
  ')

  if [ -z "$VOLS" ]; then
    echo "  CT $CTID: all volumes already on $DST, nothing to move."
    return
  fi

  local WAS_RUNNING=0
  if pct status "$CTID" | grep -q "status: running"; then
    WAS_RUNNING=1
    echo "  CT $CTID: stopping for move"
    pct stop "$CTID"
  fi

  for VOL in $VOLS; do
    echo "  CT $CTID: moving $VOL -> $DST"
    pct move-volume "$CTID" "$VOL" "$DST" $DELETE_FLAG_CT
  done

  if [ $WAS_RUNNING -eq 1 ]; then
    echo "  CT $CTID: starting again"
    pct start "$CTID"
  fi
}

echo "=== MIGRATE STORAGE JOB START ==="
echo "TO STORAGE: $DST"
echo "DELETE SOURCE VOLUMES: $([ $REMOVE_SOURCE -eq 1 ] && echo YES || echo NO)"
echo "TARGET IDS: ${IDS[*]}"
echo "================================="

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
