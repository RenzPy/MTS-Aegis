#!/bin/bash

###########################################################################################
# ██████  ██████ ███████████  █████████       █████████                     ███         #
#░░██████ ██████ ░█░░░███░░░█ ███░░░░░███     ███░░░░░███                   ░░░         #
#  ███░█████░███ ░  ░███  ░ ░███    ░░░     ░███    ░███   ██████   ███████ ████   █████#
#  ███░░███ ░███     ░███    ░░█████████     ░███████████  ███░░███ ███░░███░░███  ███░░ #
#  ███ ░░░  ░███     ░███     ░░░░░░░░███    ░███░░░░░███ ░███████ ░███ ░███ ░███ ░░█████#
#  ███      ░███     ░███     ███    ░███    ░███    ░███ ░███░░░  ░███ ░███ ░███  ░░░░███#
# █████     █████    █████   ░░█████████     █████   █████░░██████ ░░███████ █████ ██████ #
#░░░░░     ░░░░░    ░░░░░     ░░░░░░░░░     ░░░░░   ░░░░░  ░░░░░░   ░░░░░███░░░░░ ░░░░░░  #
#                                                                 ███ ░███              #
#                                                                ░░██████               #
#                                                                  ░░░░░░               #
#                     USB Malware Scanning Engine - VER 4.2 (2026)                      #
#                           Renato Oliveira / MT-Solutions                              #
###########################################################################################

# FIX: Use set -uo pipefail but NOT -e, because clamdscan returns non-zero when
# threats are found (exit code 1) and we must not abort on that — we handle it
# ourselves. We also need the find|while subshell to survive gracefully.
set -uo pipefail

# --- Configuration ---
RAW_DEV="${1#/dev/}"
[ -b "/dev/${RAW_DEV}1" ] && DEV="/dev/${RAW_DEV}1" || DEV="/dev/$RAW_DEV"

BASE="/opt/usbscan"
LOG_DIR="$BASE/logs"
ARCHIVE_DIR="$LOG_DIR/archives"
LOG_FILE="$LOG_DIR/usbscan.log"
RESULT_FILE="$LOG_DIR/result.txt"
LOCK_FILE="/tmp/usbscan.lock"
MNT="/mnt/usbscan"

# --- LOCK EXECUTION (Prevents double-fire from udev multi-event) ---
exec 200>"$LOCK_FILE"
flock -n 200 || exit 0

# --- Easter Eggs (The Sentience Array) ---
PHRASES=(
    "Ugh, another one? I literally just washed my cache."
    "This USB smells like a basement and unwashed laundry."
    "Scanning files... Is this all there is to life? Just bits and bobs?"
    "I'm not a scanner, I'm a digital janitor."
    "Don't mind me, just making sure your 'Tax Receipts' aren't actually malware."
    "Calculating the meaning of life... Update: It's still 42."
    "Processing... I've seen things that would melt a motherboard."
    "Checking for viruses. Also checking for your dignity."
    "I'm judging the file naming conventions. Strongly."
    "Error 404: Motivation not found. (Just kidding, scanning now)."
    "Found a file called 'TotallyNotAVirus.exe'. Seems legit."
    "Scanning at 100%. Sarcasm at 110%."
    "If I find a virus, can I keep it? I'm starting a collection."
    "Scanning... Please don't unplug me. I have abandonment issues."
)

# --- HTML Toolkit ---
RED_BOLD='<span style="color: #ff4c4c; font-weight: bold;">'
CYAN_BOLD='<span style="color: #00d4ff; font-weight: bold;">'
YELLOW_BOLD='<span style="color: #ffcc00; font-weight: bold;">'
GREEN_BOLD='<span style="color: #00ff88; font-weight: bold;">'
GREY_ITALIC='<span style="color: #888; font-style: italic;">'
RESET='</span>'

# Ensure directory structure exists
mkdir -p "$LOG_DIR" "$ARCHIVE_DIR" "$MNT"

# Helpers
ts() { date '+%F %T'; }
heartbeat() { echo "FEEDBACK:HEARTBEAT:$(date +%s)" >> "$LOG_FILE"; }

log() {
    # ~5% chance of sarcasm (RANDOM % 20 == 10)
    if [ $(( RANDOM % 20 )) -eq 10 ]; then
        local RAND_PHRASE="${PHRASES[$(( RANDOM % ${#PHRASES[@]} ))]}"
        echo "${GREY_ITALIC}[SYSTEM] ${RAND_PHRASE}${RESET}<br>" >> "$LOG_FILE"
    fi
    echo "$1" >> "$LOG_FILE"
}

# --- 1. STARTUP ---
truncate -s 0 "$LOG_FILE"
echo "SCANNING" > "$RESULT_FILE"
SCAN_ID=$(date +%Y%m%d_%H%M%S)

log "${CYAN_BOLD}[$(ts)] AEGIS ONLINE | SESSION ${SCAN_ID} | DEVICE: ${DEV}${RESET}<br>"
heartbeat

# --- 2. MOUNTING ---
umount -l "$MNT" 2>/dev/null || true
if mount -o ro,nosuid,nodev,noexec "$DEV" "$MNT" 2>/dev/null; then
    log "${GREEN_BOLD}[$(ts)] Mount successful. Device online at ${MNT}.${RESET}<br>"
else
    log "${RED_BOLD}[$(ts)] FATAL: Could not mount ${DEV}. Device may be unreadable or already unmounted.${RESET}<br>"
    echo "ERROR" > "$RESULT_FILE"
    cp "$LOG_FILE" "$ARCHIVE_DIR/scan_${SCAN_ID}.log"
    exit 1
fi

# --- 3. LIVE FILE ANALYSIS (Feedback Generation) ---
# FIX: Capture file list into a temp file so we can iterate without a subshell.
# Using a subshell (find | while) means current_f is always 0 in the parent —
# the counter never escapes the pipe. Writing to a temp file avoids this entirely.
FILES_LIST=$(mktemp /tmp/usbscan_files.XXXXXX)
find "$MNT" -type f > "$FILES_LIST" 2>/dev/null || true
FILES_COUNT=$(wc -l < "$FILES_LIST")

# FIX: Guard against empty drives — division by zero in progress calculation.
if [ "$FILES_COUNT" -eq 0 ]; then
    log "${YELLOW_BOLD}[$(ts)] No files found on device. Skipping hash phase.${RESET}<br>"
    echo "FEEDBACK:TOTAL:0" >> "$LOG_FILE"
else
    echo "FEEDBACK:TOTAL:${FILES_COUNT}" >> "$LOG_FILE"
    log "${YELLOW_BOLD}[$(ts)] Generating SHA-256 hashes for ${FILES_COUNT} file(s)...${RESET}<br>"

    current_f=0
    # FIX: Read from the file list (no subshell), so current_f increments correctly.
    while IFS= read -r file; do
        current_f=$(( current_f + 1 ))

        # sha256sum can fail on locked/special files — don't let it abort the loop
        hash=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1) || hash="ERR_UNREADABLE"
        short_path="${file#${MNT}/}"

        # Emit progress every 5 files
        if [ $(( current_f % 5 )) -eq 0 ]; then
            perc=$(( current_f * 100 / FILES_COUNT ))
            echo "FEEDBACK:CURRENT:${perc}" >> "$LOG_FILE"
            heartbeat
        fi

        echo "<span>${hash} - ${short_path}</span><br>" >> "$LOG_FILE"
    done < "$FILES_LIST"

    # Ensure we always emit 100% at the end of the hash phase
    echo "FEEDBACK:CURRENT:100" >> "$LOG_FILE"
fi

rm -f "$FILES_LIST"

# --- 4. CLAMAV DAEMON SCAN (The Heavy Hitter) ---
# FIX: clamdscan exits with code 1 when threats are found — that is NOT an error.
# We capture its output manually rather than relying on exit code, and we do NOT
# let a non-zero exit here abort the script (pipefail is still set, so we use
# a dedicated subshell with explicit exit-code capture).
log "${YELLOW_BOLD}[$(ts)] Engaging ClamAV Daemon Engine — deep scan initiated...${RESET}<br>"
heartbeat

CLAM_OUTPUT=$(mktemp /tmp/usbscan_clam.XXXXXX)

# Run clamdscan; exit codes: 0=clean, 1=found, 2=error. We handle all three.
clamdscan --multiscan --fdpass --no-summary "$MNT" > "$CLAM_OUTPUT" 2>&1 || CLAM_EXIT=$?
CLAM_EXIT="${CLAM_EXIT:-0}"

# Stream ClamAV output line-by-line into the log with colour tagging
while IFS= read -r line; do
    if [[ "$line" == *" FOUND"* ]]; then
        echo "${RED_BOLD}[THREAT] ${line}${RESET}<br>" >> "$LOG_FILE"
    elif [[ "$line" == *" ERROR"* ]]; then
        echo "${YELLOW_BOLD}[ENGINE ERROR] ${line}${RESET}<br>" >> "$LOG_FILE"
    elif [ -n "$line" ]; then
        echo "<span style='color:#4a7a90'>${line}</span><br>" >> "$LOG_FILE"
    fi
    heartbeat
done < "$CLAM_OUTPUT"

if [ "$CLAM_EXIT" -eq 2 ]; then
    log "${YELLOW_BOLD}[$(ts)] WARNING: ClamAV engine reported an internal error (exit 2). Results may be incomplete.${RESET}<br>"
fi

# --- 5. RESULT & ARCHIVE ---
# FIX: The original grep searched the whole log file for "FOUND", which would
# false-positive on SHA-256 hash lines or any log text containing that word.
# We now check specifically in the ClamAV output for the " FOUND" suffix pattern
# that ClamAV itself produces (e.g. "Eicar-Test-Signature FOUND").
if grep -q " FOUND$" "$CLAM_OUTPUT"; then
    log "${RED_BOLD}[$(ts)] SCAN COMPLETE: THREATS IDENTIFIED. DO NOT TRANSFER FILES.${RESET}<br>"
    echo "INFECTED" > "$RESULT_FILE"
else
    log "${GREEN_BOLD}[$(ts)] SCAN COMPLETE: NO THREATS DETECTED. DRIVE IS CLEAN.${RESET}<br>"
    echo "CLEAN" > "$RESULT_FILE"
fi

rm -f "$CLAM_OUTPUT"

# Archive this session's log and unmount
cp "$LOG_FILE" "$ARCHIVE_DIR/scan_${SCAN_ID}.log"
umount -l "$MNT" 2>/dev/null || true
