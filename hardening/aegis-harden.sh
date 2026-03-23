#!/bin/bash

###############################################################################
#              MTS AEGIS — Host Hardening Script                             #
#                   Renato Oliveira / MT-Solutions                           #
#                        MIT License                                          #
#                                                                             #
#  Locks down a Debian/Ubuntu bare-metal host into a single-purpose          #
#  appliance. Run ONCE after the Aegis application installer completes.      #
#                                                                             #
#  Supported: Ubuntu 22.04, 24.04 / Debian 11, 12                           #
#                                                                             #
#  What this script does:                                                     #
#    H1.  Full system update + reboot guard                                  #
#    H2.  User hardening + targeted sudo                                     #
#    H3.  SSH key-only access + hardened sshd_config                        #
#    H4.  Physical TTY lockdown (no console login)                          #
#    H5.  GRUB password (protects recovery mode)                            #
#    H6.  USBGuard (blocks HID/keyboards, allows storage)                   #
#    H7.  Firewall — ufw (SSH + web UI only)                               #
#    H8.  Service minimization                                               #
#    H9.  Kernel hardening (sysctl)                                         #
#    H10. Final reboot                                                        #
###############################################################################

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[AEGIS]${RESET} $*"; }
ok()     { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
fail()   { echo -e "${RED}[ FAIL ]${RESET} $*"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}"; }
ask()    { echo -e "${BOLD}${CYAN}  >>> $*${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || fail "Must run as root: sudo bash $0"

STATE_DIR="/var/lib/aegis-hardening"
FLAG_FILE="${STATE_DIR}/.reboot_pending"
mkdir -p "$STATE_DIR"

###############################################################################
# FIRST-RUN WIZARD — collect configuration
###############################################################################
CONF_FILE="${STATE_DIR}/harden.conf"

clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         MTS AEGIS — HOST HARDENING WIZARD           ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

if [ -f "$CONF_FILE" ] && [ -f "$FLAG_FILE" ]; then
    # Post-reboot continuation — load saved config
    info "Resuming after reboot, loading saved configuration..."
    # shellcheck source=/var/lib/aegis-hardening/harden.conf
    source "$CONF_FILE"
    rm -f "$FLAG_FILE"
else
    # Fresh run — interactive wizard
    echo -e "  This wizard will configure the hardening for your environment."
    echo -e "  All values can be changed by re-running this script."
    echo ""

    # ── Detect network interface ──────────────────────────────────────────────
    # Find the default route interface automatically
    DETECTED_NIC=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)

    echo -e "  ${BOLD}Network Interface${RESET}"
    if [ -n "$DETECTED_NIC" ]; then
        echo -e "  Detected default interface: ${CYAN}${DETECTED_NIC}${RESET}"
        ask "Use '${DETECTED_NIC}'? Press Enter to confirm or type a different interface name:"
        read -r NIC_INPUT
        AEGIS_NIC="${NIC_INPUT:-$DETECTED_NIC}"
    else
        ask "Enter the network interface name (e.g. eth0, eno2, enp3s0):"
        read -r AEGIS_NIC
        [ -z "$AEGIS_NIC" ] && fail "Network interface is required."
    fi
    echo ""

    # ── Operator username ─────────────────────────────────────────────────────
    echo -e "  ${BOLD}Operator Account${RESET}"
    echo -e "  This is the only account that can SSH into the appliance."
    ask "Enter the operator username [default: aegis-operator]:"
    read -r USER_INPUT
    AEGIS_USER="${USER_INPUT:-aegis-operator}"
    echo ""

    ask "Enter the operator password:"
    read -rs AEGIS_PASS
    echo ""
    ask "Confirm password:"
    read -rs AEGIS_PASS2
    echo ""
    [ "$AEGIS_PASS" = "$AEGIS_PASS2" ] || fail "Passwords do not match."
    [ -z "$AEGIS_PASS" ] && fail "Password cannot be empty."
    echo ""

    # ── GRUB password ─────────────────────────────────────────────────────────
    echo -e "  ${BOLD}GRUB Recovery Password${RESET}"
    echo -e "  Protects recovery mode and boot entry editing."
    echo -e "  The machine boots normally without it (unattended boot works)."
    ask "Enter GRUB password [default: same as operator password]:"
    read -rs GRUB_INPUT
    echo ""
    GRUB_PASS="${GRUB_INPUT:-$AEGIS_PASS}"
    echo ""

    # ── Web UI port ───────────────────────────────────────────────────────────
    echo -e "  ${BOLD}Ports${RESET}"
    ask "SSH port [default: 22]:"
    read -r SSH_PORT_INPUT
    AEGIS_SSH_PORT="${SSH_PORT_INPUT:-22}"

    ask "Aegis Web UI port [default: 8080]:"
    read -r WEB_PORT_INPUT
    AEGIS_WEB_PORT="${WEB_PORT_INPUT:-8080}"
    echo ""

    # ── Summary & confirm ─────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Configuration Summary:${RESET}"
    echo -e "    Network interface : ${CYAN}${AEGIS_NIC}${RESET}"
    echo -e "    Operator user     : ${CYAN}${AEGIS_USER}${RESET}"
    echo -e "    SSH port          : ${CYAN}${AEGIS_SSH_PORT}${RESET}"
    echo -e "    Web UI port       : ${CYAN}${AEGIS_WEB_PORT}${RESET}"
    echo ""
    ask "Proceed with hardening? [Y/n]:"
    read -r CONFIRM
    case "${CONFIRM,,}" in
        n|no) fail "Aborted." ;;
    esac

    # Save config for post-reboot continuation
    cat > "$CONF_FILE" << SAVECONF
AEGIS_USER="${AEGIS_USER}"
AEGIS_PASS="${AEGIS_PASS}"
AEGIS_NIC="${AEGIS_NIC}"
AEGIS_SSH_PORT="${AEGIS_SSH_PORT}"
AEGIS_WEB_PORT="${AEGIS_WEB_PORT}"
GRUB_PASS="${GRUB_PASS}"
SAVECONF
    chmod 600 "$CONF_FILE"
fi

SSH_KEY_DIR="/home/${AEGIS_USER}/.ssh"

###############################################################################
# H1. SYSTEM UPDATE
###############################################################################
header "H1 — System Update"

info "Running apt-get update..."
apt-get update -qq

info "Running full-upgrade..."
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

ok "System packages updated."

if [ -f /var/run/reboot-required ]; then
    warn "Reboot required to apply kernel updates."
    warn "This script will reboot now and resume automatically."
    echo ""
    echo -e "  ${BOLD}After reboot, re-run:${RESET}  sudo bash $0"
    echo ""
    touch "$FLAG_FILE"
    sleep 5
    systemctl reboot
    exit 0
fi
ok "No reboot required — continuing."

###############################################################################
# H2. USER HARDENING
###############################################################################
header "H2 — User Hardening"

if ! id "$AEGIS_USER" &>/dev/null; then
    info "Creating user ${AEGIS_USER}..."
    useradd -m -s /bin/bash -c "MTS Aegis Operator" "$AEGIS_USER"
fi

echo "${AEGIS_USER}:${AEGIS_PASS}" | chpasswd
ok "Password set for ${AEGIS_USER}."

# Remove from privileged groups
for grp in sudo adm plugdev lpadmin sambashare; do
    if groups "$AEGIS_USER" 2>/dev/null | grep -qw "$grp"; then
        gpasswd -d "$AEGIS_USER" "$grp" 2>/dev/null || true
    fi
done

passwd -l root
ok "Root account locked."

# Targeted sudoers — only the Aegis engine scripts
cat > /etc/sudoers.d/aegis-operator << SUDOERS
# MTS Aegis — Operator sudo rules (generated by aegis-harden.sh)
${AEGIS_USER} ALL=(ALL) NOPASSWD: /opt/usbscan/usbscan.sh
${AEGIS_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/usbcopy.sh
${AEGIS_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/usbformat.sh
${AEGIS_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/aegis-detect-ports
${AEGIS_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart aegis-webui
${AEGIS_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl status aegis-webui
${AEGIS_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart clamav-daemon
${AEGIS_USER} ALL=(ALL) NOPASSWD: /usr/bin/freshclam
SUDOERS
chmod 440 /etc/sudoers.d/aegis-operator
visudo -c -f /etc/sudoers.d/aegis-operator || fail "Sudoers syntax error."
ok "Targeted sudoers rules written."

# Auto-logout idle SSH sessions after 5 minutes
cat > /etc/profile.d/aegis-timeout.sh << 'TIMEOUT'
TMOUT=300
readonly TMOUT
export TMOUT
TIMEOUT
chmod 644 /etc/profile.d/aegis-timeout.sh
ok "Idle session timeout: 300 seconds."

cat > /etc/issue.net << 'BANNER'
╔══════════════════════════════════════════════════════╗
║          MTS AEGIS — USB THREAT ANALYSIS            ║
║              AUTHORISED ACCESS ONLY                 ║
║   Unauthorised access is prohibited and monitored   ║
╚══════════════════════════════════════════════════════╝
BANNER
ok "SSH banner written."

###############################################################################
# H3. SSH HARDENING
###############################################################################
header "H3 — SSH Key Setup & sshd Hardening"

if ! dpkg -l openssh-server &>/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server
fi

mkdir -p "$SSH_KEY_DIR"
chmod 700 "$SSH_KEY_DIR"
chown "${AEGIS_USER}:${AEGIS_USER}" "$SSH_KEY_DIR"

KEY_FILE="${SSH_KEY_DIR}/aegis_id_ed25519"

info "Generating ed25519 SSH keypair..."
ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "aegis-operator@$(hostname)" -q

cat "${KEY_FILE}.pub" >> "${SSH_KEY_DIR}/authorized_keys"
chmod 600 "${SSH_KEY_DIR}/authorized_keys"
chown -R "${AEGIS_USER}:${AEGIS_USER}" "$SSH_KEY_DIR"
ok "SSH keypair generated."

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.aegis-backup

cat > /etc/ssh/sshd_config << SSHD
# MTS Aegis — Hardened SSH Configuration
Port ${AEGIS_SSH_PORT}
AddressFamily inet
ListenAddress 0.0.0.0

PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes

AllowUsers ${AEGIS_USER}

MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30

X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no

PrintLastLog yes
PrintMotd no
Banner /etc/issue.net

ClientAliveInterval 60
ClientAliveCountMax 3

KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
SSHD

sshd -t || fail "sshd_config syntax error."
systemctl restart ssh
ok "SSH hardened and restarted."

# Print private key ONCE
echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${YELLOW}║  PRIVATE KEY — COPY THIS NOW — IT WILL BE DELETED       ║${RESET}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
cat "$KEY_FILE"
echo ""
echo -e "${BOLD}${YELLOW}  Save as: aegis_id_ed25519  (no extension)${RESET}"
echo -e "${BOLD}${YELLOW}  Connect: ssh -i aegis_id_ed25519 ${AEGIS_USER}@$(hostname -I | awk '{print $1}') -p ${AEGIS_SSH_PORT}${RESET}"
echo ""
echo -e "  ${BOLD}Press ENTER when you have saved the private key...${RESET}"
read -r

rm -f "$KEY_FILE"
ok "Private key deleted from machine."

###############################################################################
# H4. PHYSICAL TTY LOCKDOWN
###############################################################################
header "H4 — Physical TTY Lockdown"

for tty in tty1 tty2 tty3 tty4 tty5 tty6; do
    systemctl mask "getty@${tty}.service" 2>/dev/null || true
done
systemctl mask serial-getty@ttyS0.service 2>/dev/null || true
ok "All getty services masked."

cat > /etc/systemd/system/aegis-console.service << CONSOLESVC
[Unit]
Description=MTS Aegis — Locked Console Banner
After=systemd-user-sessions.service
ConditionPathExists=/dev/tty1

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do clear > /dev/tty1; printf "\\n\\n  MTS AEGIS APPLIANCE\\n  SSH access only\\n  Web UI: http://$(hostname -I | awk '"'"'{print \$1}'"'"'):${AEGIS_WEB_PORT}\\n" > /dev/tty1; sleep 60; done'
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Restart=always

[Install]
WantedBy=multi-user.target
CONSOLESVC

systemctl daemon-reload
systemctl enable aegis-console.service
ok "Console locked — SSH-only banner enabled."

###############################################################################
# H5. GRUB PASSWORD
###############################################################################
header "H5 — GRUB Password Protection"

info "Generating GRUB password hash..."
GRUB_HASH=$(printf '%s\n%s\n' "$GRUB_PASS" "$GRUB_PASS" \
    | grub-mkpasswd-pbkdf2 2>/dev/null \
    | grep -oP 'grub\.pbkdf2\.[^\s]+')

[ -z "$GRUB_HASH" ] && fail "Failed to generate GRUB hash. Is grub-common installed?"

cat > /etc/grub.d/42_aegis_password << GRUBPW
#!/bin/sh
cat << EOF
set superusers="aegis"
password_pbkdf2 aegis ${GRUB_HASH}
EOF
GRUBPW
chmod +x /etc/grub.d/42_aegis_password

if grep -q "GRUB_DISABLE_RECOVERY" /etc/default/grub; then
    sed -i 's/.*GRUB_DISABLE_RECOVERY.*/GRUB_DISABLE_RECOVERY="true"/' /etc/default/grub
else
    echo 'GRUB_DISABLE_RECOVERY="true"' >> /etc/default/grub
fi

# Mark default entry unrestricted so machine boots without password
sed -i 's/echo "menuentry/echo "menuentry --unrestricted/' /etc/grub.d/10_linux 2>/dev/null || true

update-grub 2>/dev/null
ok "GRUB password set. Recovery mode protected."

###############################################################################
# H6. USBGUARD
###############################################################################
header "H6 — USBGuard (Block HID, Allow Storage)"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq usbguard

cat > /etc/usbguard/rules.conf << 'USBGUARD_RULES'
# MTS Aegis — USBGuard Policy
# Allow USB hubs
allow with-interface equals { 09:00:00 }
# Allow Mass Storage — required for Aegis scanning
allow with-interface equals { 08:*:* }
# Block HID — keyboards, mice (physical lockdown)
block with-interface equals { 03:*:* }
# Block audio, video, wireless
block with-interface equals { 01:*:* }
block with-interface equals { 0e:*:* }
block with-interface equals { e0:*:* }
# Default deny
block
USBGUARD_RULES
chmod 600 /etc/usbguard/rules.conf

cat > /etc/usbguard/usbguard-daemon.conf << USBGUARD_DAEMON
RuleFile=/etc/usbguard/rules.conf
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=false
DeviceManagerBackend=uevent
IPCAllowedUsers=root ${AEGIS_USER}
IPCAllowedGroups=
DeviceRulesWithPort=false
AuditBackend=FileAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log
USBGUARD_DAEMON

mkdir -p /var/log/usbguard
systemctl enable usbguard
systemctl restart usbguard
ok "USBGuard enabled — HID blocked, storage allowed."

###############################################################################
# H7. FIREWALL
###############################################################################
header "H7 — Firewall (ufw)"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

ufw allow in on "${AEGIS_NIC}" to any port "${AEGIS_SSH_PORT}" proto tcp comment "Aegis SSH"
ufw allow in on "${AEGIS_NIC}" to any port "${AEGIS_WEB_PORT}" proto tcp comment "Aegis Web UI"

ufw --force enable
ok "Firewall enabled: allow ${AEGIS_SSH_PORT}+${AEGIS_WEB_PORT} on ${AEGIS_NIC}."

# Disable WiFi if present
if command -v nmcli &>/dev/null; then
    nmcli radio wifi off 2>/dev/null || true
fi
if command -v rfkill &>/dev/null; then
    rfkill block wifi 2>/dev/null || true
fi

cat > /etc/udev/rules.d/98-aegis-disable-wifi.rules << 'WIFIRULE'
SUBSYSTEM=="net", ACTION=="add", KERNEL=="wlo*", RUN+="/bin/ip link set %k down"
SUBSYSTEM=="net", ACTION=="add", KERNEL=="wlp*", RUN+="/bin/ip link set %k down"
WIFIRULE

if [ -d /etc/NetworkManager/conf.d ]; then
    cat > /etc/NetworkManager/conf.d/aegis-no-wifi.conf << 'NMCONF'
[device]
wifi.managed=false
NMCONF
fi
ok "WiFi permanently disabled."

###############################################################################
# H8. SERVICE MINIMIZATION
###############################################################################
header "H8 — Service Minimization"

SERVICES_TO_MASK=(
    avahi-daemon cups cups-browsed ModemManager bluetooth
    apport whoopsie snapd snapd.socket fwupd
    speech-dispatcher kerneloops thermald
)

for svc in "${SERVICES_TO_MASK[@]}"; do
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}"; then
        systemctl disable "${svc}.service" 2>/dev/null || true
        systemctl stop    "${svc}.service" 2>/dev/null || true
        systemctl mask    "${svc}.service" 2>/dev/null || true
        echo "  masked: ${svc}"
    fi
done

cat > /etc/security/limits.d/aegis-nodump.conf << 'NODUMP'
* hard core 0
* soft core 0
NODUMP

[ -f /etc/default/motd-news ] && sed -i 's/ENABLED=.*/ENABLED=0/' /etc/default/motd-news

for f in /etc/update-motd.d/10-help-text \
         /etc/update-motd.d/50-motd-news \
         /etc/update-motd.d/80-livepatch; do
    [ -f "$f" ] && chmod -x "$f" 2>/dev/null || true
done
ok "Unnecessary services disabled."

###############################################################################
# H9. KERNEL HARDENING
###############################################################################
header "H9 — Kernel Hardening"

cat > /etc/sysctl.d/99-aegis-hardening.conf << 'SYSCTL'
# MTS Aegis — Kernel Hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.unprivileged_bpf_disabled = 1
SYSCTL

sysctl --system 2>/dev/null || true
ok "Kernel hardening applied."

###############################################################################
# H10. DONE
###############################################################################
header "H10 — Hardening Complete"

# Save final config summary for reference
cat > "${STATE_DIR}/install-summary.txt" << SUMMARY
MTS Aegis — Hardening Summary
Generated: $(date)
Hostname:  $(hostname)
OS:        $(lsb_release -ds 2>/dev/null || echo "Unknown")

Operator user:  ${AEGIS_USER}
Network NIC:    ${AEGIS_NIC}
SSH port:       ${AEGIS_SSH_PORT}
Web UI port:    ${AEGIS_WEB_PORT}
SUMMARY

# Wipe the config file that contained the password
rm -f "$CONF_FILE"

IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║           AEGIS HOST HARDENING COMPLETE                      ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Connect after reboot:${RESET}"
echo -e "    ${CYAN}ssh -i aegis_id_ed25519 ${AEGIS_USER}@${IP} -p ${AEGIS_SSH_PORT}${RESET}"
echo ""
echo -e "  ${BOLD}Web UI:${RESET}  http://${IP}:${AEGIS_WEB_PORT}"
echo ""
echo -e "  ${BOLD}${YELLOW}Confirm you have saved the SSH private key before rebooting.${RESET}"
echo -e "  ${BOLD}After reboot, password login is DISABLED.${RESET}"
echo ""
ask "Reboot now? [Y/n]:"
read -r REBOOT_CONFIRM
case "${REBOOT_CONFIRM,,}" in
    n|no) warn "Reboot skipped. Some changes require reboot to take full effect." ;;
    *)    info "Rebooting in 5 seconds..."; sleep 5; systemctl reboot ;;
esac
