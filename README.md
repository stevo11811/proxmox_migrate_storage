# Proxmox VM & Container Storage Migration Script

This script safely migrates **virtual machine disks and LXC container volumes** to a specified destination storage in Proxmox. It auto-detects the source storage per disk, avoids duplicate migrations, and supports optional source cleanup.

---

## ✅ Key Features

- ✅ Auto-detects **current storage per disk/volume**
- ✅ Moves only disks **not already on the destination**
- ✅ Prevents **duplicate volumes in mixed storage setups**
- ✅ Supports **VMs and LXC containers**
- ✅ Safely **skips bind mounts and local path mounts**
- ✅ Optional source cleanup with `--remove-source`
- ✅ Automatically stops/starts running containers when required
- ✅ No source storage needs to be specified

---

## ✅ Usage

```bash
./migrate_storage.sh <TO_STORAGE> <ID1> [ID2 ...] [--remove-source]
