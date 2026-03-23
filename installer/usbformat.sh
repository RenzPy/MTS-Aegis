#!/bin/bash

###########################################################################################
#                     MTS Aegis - Drive Format Engine                                   #
#                           Renato Oliveira / MT-Solutions                              #
###########################################################################################
#
# Usage: sudo /usr/local/bin/usbformat.sh
#
# Resolves the block device connected to Port A via its stable PCI path symlink,
# unmounts all partitions, and formats the whole disk as FAT32 labeled CLEAN_USB.
# Writes status to /opt/usbscan/logs/result.txt throughout so the web UI tracks
# progress correctly and udev-triggered scan re-fires are suppressed.
#
# Exit codes:
#   0  success
#   1  device not found or format failed
###########################################################################################

set -uo pipefail

# --- Load hardware port configuration ---
# Port paths are stored in /etc/aegis/ports.conf and written by the installer.
# To reconfigure: sudo aegis-detect-ports  (or edit ports.conf manually)
RESULT_FILE="/opt/usbscan/logs/result.txt"
LOG_DIR="/opt/usbscan/logs"

mkdir -p "$LOG_DIR"

# --- Load hardware port configuration ---
# Port paths are stored in /etc/aegis/ports.conf and written by the installer.
# To reconfigure: sudo aegis-detect-ports  (or edit ports.conf manually)
AEGIS_CONF="/etc/aegis/ports.conf"
if [ ! -f "$AEGIS_CONF" ]; then
    echo "FORMAT ENGINE ERROR: Port configuration not found at ${AEGIS_CONF}."
    echo "       Run the Aegis installer or: sudo aegis-detect-ports"
    echo "WAITING" > "$RESULT_FILE"
    exit 1
fi
# shellcheck source=/etc/aegis/ports.conf
source "$AEGIS_CONF"

PORT_A_PATH="/dev/disk/by-path/${AEGIS_PORT_A}"

# --- Write FORMATTING sentinel immediately ---
# This must happen before partprobe so that if udev fires usbscan.sh during
# the format, the web UI SSE stream reads FORMATTING and holds that state
# rather than treating it as a new scan starting.
echo "FORMATTING" > "$RESULT_FILE"
echo "FORMAT ENGINE: Sentinel written. Beginning format sequence."

# --- Resolve the block device ---
# First preference: use the stable PCI symlink for Port A (most reliable).
# Fallback: walk sdb..sde and take the first one that exists.
TARGET=""

if [ -L "$PORT_A_PATH" ]; then
    RESOLVED=$(readlink -f "$PORT_A_PATH")
    echo "FORMAT ENGINE: Port A symlink resolved to: $RESOLVED"
    # The symlink may point to a partition (e.g. /dev/sdb1) — strip it to get
    # the whole disk. Handles both sdb1 style and nvme0n1p1 style.
    TARGET=$(echo "$RESOLVED" | sed 's/p\?[0-9]*$//')
    echo "FORMAT ENGINE: Base device: $TARGET"
fi

# Fallback detection if symlink didn't resolve to a valid block device
if [ -z "$TARGET" ] || [ ! -b "$TARGET" ]; then
    echo "FORMAT ENGINE: Symlink resolution failed or device invalid. Falling back to scan..."
    for candidate in /dev/sdb /dev/sdc /dev/sdd /dev/sde; do
        if [ -b "$candidate" ]; then
            TARGET="$candidate"
            echo "FORMAT ENGINE: Found via fallback: $TARGET"
            break
        fi
    done
fi

if [ -z "$TARGET" ] || [ ! -b "$TARGET" ]; then
    echo "FORMAT ENGINE ERROR: No valid USB block device found. Is the drive plugged in?"
    echo "WAITING" > "$RESULT_FILE"
    exit 1
fi

echo "FORMAT ENGINE: Target confirmed: $TARGET"

# --- Safety check: refuse to format the OS drive ---
# The root filesystem device must never be the format target.
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
if [ "$TARGET" = "$ROOT_DEV" ]; then
    echo "FORMAT ENGINE ERROR: SAFETY ABORT. Target $TARGET is the OS drive ($ROOT_DEV)."
    echo "WAITING" > "$RESULT_FILE"
    exit 1
fi

# --- Unmount sequence ---
echo "FORMAT ENGINE: Running partprobe..."
partprobe "$TARGET" 2>/dev/null || true
sleep 1

echo "FORMAT ENGINE: Killing processes using $TARGET..."
fuser -k "$TARGET" 2>/dev/null || true
sleep 1

# Unmount all partitions of this disk (handles sdb1, sdb2, etc.)
for part in "${TARGET}"?*; do
    if [ -b "$part" ]; then
        echo "FORMAT ENGINE: Unmounting $part..."
        umount -l -f "$part" 2>/dev/null || true
    fi
done

# Also unmount the base device itself in case it was mounted directly
umount -l -f "$TARGET" 2>/dev/null || true
sleep 1

# --- Format ---
echo "FORMAT ENGINE: Running mkfs.vfat on $TARGET..."
if mkfs.vfat -I -F 32 -n "CLEAN_USB" "$TARGET"; then
    echo "FORMAT ENGINE: SUCCESS. $TARGET formatted as FAT32 [CLEAN_USB]."
    # Write WAITING explicitly so the SSE stream transitions cleanly.
    # Deleting result.txt would cause the stream to fall back to checking
    # usbscan.log mtime — if it was touched recently it would broadcast
    # SCANNING and re-trigger the scan UI.
    echo "WAITING" > "$RESULT_FILE"
    exit 0
else
    echo "FORMAT ENGINE ERROR: mkfs.vfat failed on $TARGET."
    echo "WAITING" > "$RESULT_FILE"
    exit 1
fi
