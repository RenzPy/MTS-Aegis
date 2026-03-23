#!/bin/bash

###########################################################################################
#                     MTS Aegis - Secure File Transfer Engine                           #
#                           Renato Oliveira / MT-Solutions                              #
###########################################################################################
#
# Transfers files from the scanned (dirty) USB in Port A (Type-A) to the
# clean destination USB in Port C (Type-C).
#
# Device identification uses the stable PCI path symlinks — the same method
# used by usbformat.sh and webui.py — so there is no ambiguity about which
# physical device is source and which is destination.
#
# Exit codes:
#   0  success
#   1  device error, mount error, or transfer error

set -uo pipefail

# --- Load hardware port configuration ---
# Port paths are stored in /etc/aegis/ports.conf and written by the installer.
# To reconfigure: sudo aegis-detect-ports  (or edit ports.conf manually)
AEGIS_CONF="/etc/aegis/ports.conf"
if [ ! -f "$AEGIS_CONF" ]; then
    echo "ERROR: Port configuration not found at ${AEGIS_CONF}."
    echo "       Run the Aegis installer or: sudo aegis-detect-ports"
    exit 1
fi
# shellcheck source=/etc/aegis/ports.conf
source "$AEGIS_CONF"

PORT_A_LINK="/dev/disk/by-path/${AEGIS_PORT_A}"
PORT_C_LINK="/dev/disk/by-path/${AEGIS_PORT_C}"

SOURCE_MNT="/mnt/usbscan"
DEST_MNT="/mnt/usb_safe"

# --- Cleanup trap: always unmount both mount points on any exit ---
cleanup() {
    local code=$?
    sync 2>/dev/null || true
    umount -l "$DEST_MNT"   2>/dev/null || true
    umount -l "$SOURCE_MNT" 2>/dev/null || true
    exit "$code"
}
trap cleanup EXIT

# --- Ensure mount points exist ---
mkdir -p "$SOURCE_MNT" "$DEST_MNT"

# ─── 1. Resolve Source Device (Port A — the scanned/dirty USB) ────────────────
echo "TRANSFER ENGINE: Resolving Port A (source)..."

if [ ! -L "$PORT_A_LINK" ]; then
    echo "ERROR: No device detected on Port A (Type-A). Is the scanned USB still plugged in?"
    exit 1
fi

# Resolve the symlink. It may point to the whole disk (e.g. /dev/sdb) or a
# partition (e.g. /dev/sdb1). We want the partition to mount, but also need
# the base disk for the same-device safety check.
SOURCE_RAW=$(readlink -f "$PORT_A_LINK")
echo "TRANSFER ENGINE: Port A symlink -> ${SOURCE_RAW}"

# Derive the partition to mount: if the symlink already points to a partition
# (ends in a digit), use it directly. Otherwise, try <device>1.
if echo "$SOURCE_RAW" | grep -qE '[0-9]$'; then
    SOURCE_DEV="$SOURCE_RAW"
    SOURCE_BASE=$(echo "$SOURCE_RAW" | sed 's/p\?[0-9]*$//')
else
    # Whole-disk symlink — prefer partition 1 if it exists
    if [ -b "${SOURCE_RAW}1" ]; then
        SOURCE_DEV="${SOURCE_RAW}1"
    else
        SOURCE_DEV="$SOURCE_RAW"
    fi
    SOURCE_BASE="$SOURCE_RAW"
fi

if [ ! -b "$SOURCE_DEV" ]; then
    echo "ERROR: Source block device ${SOURCE_DEV} does not exist."
    exit 1
fi
echo "TRANSFER ENGINE: Source device: ${SOURCE_DEV} (base: ${SOURCE_BASE})"

# ─── 2. Resolve Destination Device (Port C — the clean USB) ──────────────────
echo "TRANSFER ENGINE: Resolving Port C (destination)..."

if [ ! -L "$PORT_C_LINK" ]; then
    echo "ERROR: No device detected on Port C (Type-C). Please plug in the clean destination USB."
    exit 1
fi

DEST_RAW=$(readlink -f "$PORT_C_LINK")
echo "TRANSFER ENGINE: Port C symlink -> ${DEST_RAW}"

if echo "$DEST_RAW" | grep -qE '[0-9]$'; then
    DEST_DEV="$DEST_RAW"
    DEST_BASE=$(echo "$DEST_RAW" | sed 's/p\?[0-9]*$//')
else
    if [ -b "${DEST_RAW}1" ]; then
        DEST_DEV="${DEST_RAW}1"
    else
        DEST_DEV="$DEST_RAW"
    fi
    DEST_BASE="$DEST_RAW"
fi

if [ ! -b "$DEST_DEV" ]; then
    echo "ERROR: Destination block device ${DEST_DEV} does not exist."
    exit 1
fi
echo "TRANSFER ENGINE: Destination device: ${DEST_DEV} (base: ${DEST_BASE})"

# ─── 3. Safety: refuse if both ports resolved to the same physical disk ───────
if [ "$SOURCE_BASE" = "$DEST_BASE" ]; then
    echo "ERROR: Source and destination resolved to the same physical device (${SOURCE_BASE}). Aborting."
    exit 1
fi

# ─── 4. Mount source read-only ────────────────────────────────────────────────
# usbscan.sh may have already mounted the source. If so, we just use it.
# If not (e.g. script called manually), mount it ourselves.
if mountpoint -q "$SOURCE_MNT"; then
    echo "TRANSFER ENGINE: ${SOURCE_MNT} already mounted, reusing."
else
    echo "TRANSFER ENGINE: Mounting ${SOURCE_DEV} at ${SOURCE_MNT} (read-only)..."
    if ! mount -o ro,nosuid,nodev,noexec "$SOURCE_DEV" "$SOURCE_MNT"; then
        echo "ERROR: Could not mount source ${SOURCE_DEV} at ${SOURCE_MNT}."
        exit 1
    fi
fi

# Verify the source mount actually has content
FILE_COUNT=$(find "$SOURCE_MNT" -maxdepth 1 | wc -l)
if [ "$FILE_COUNT" -le 1 ]; then
    echo "WARNING: Source mount ${SOURCE_MNT} appears empty. Check that the USB has files."
fi
echo "TRANSFER ENGINE: Source ready. Found approximately $((FILE_COUNT - 1)) top-level item(s)."

# ─── 5. Unmount destination if already mounted, then remount fresh ────────────
# We always remount to ensure we have write access and the correct device.
if mountpoint -q "$DEST_MNT"; then
    echo "TRANSFER ENGINE: ${DEST_MNT} already mounted, unmounting first..."
    umount -l "$DEST_MNT" 2>/dev/null || true
fi

echo "TRANSFER ENGINE: Mounting ${DEST_DEV} at ${DEST_MNT} (read-write)..."
if ! mount "$DEST_DEV" "$DEST_MNT"; then
    echo "ERROR: Failed to mount destination ${DEST_DEV} at ${DEST_MNT}. Is it formatted?"
    exit 1
fi

# ─── 6. Transfer ──────────────────────────────────────────────────────────────
FOLDER_NAME="CLEAN_FILES_$(date +%Y%m%d_%H%M%S)"
echo "TRANSFER ENGINE: Creating destination folder '${FOLDER_NAME}'..."
mkdir -p "${DEST_MNT}/${FOLDER_NAME}"

echo "TRANSFER ENGINE: Starting rsync from ${SOURCE_MNT}/ to ${DEST_MNT}/${FOLDER_NAME}/..."

# --recursive --times: correct for FAT32 targets (no Unix permissions/ownership)
# --no-perms --no-owner --no-group: suppress permission-related errors on FAT
# --stats: print transfer summary at the end for logging
# NOT using -a (archive) because it implies --perms/--owner/--group which
# conflict with FAT32 and can cause silent failures or errors
if ! rsync \
        --recursive \
        --times \
        --no-perms \
        --no-owner \
        --no-group \
        --human-readable \
        --stats \
        "${SOURCE_MNT}/" "${DEST_MNT}/${FOLDER_NAME}/"; then
    echo "ERROR: rsync failed. Destination may be full, write-protected, or unformatted."
    exit 1
fi

sync
echo "SUCCESS: Files transferred from ${SOURCE_DEV} to ${DEST_DEV} in folder '${FOLDER_NAME}'."
# Cleanup trap fires here — unmounts both drives
