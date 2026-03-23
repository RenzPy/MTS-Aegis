#Requires -Version 5.1
<#
.SYNOPSIS
    MTS Aegis — Secure Dashboard Launcher
    Renato Oliveira / MT-Solutions
    MIT License

.DESCRIPTION
    On first run, asks for the Aegis appliance IP and saves it locally.
    Installs the SSH key into the current user's profile with correct
    permissions. Works for every user on any Windows machine.
#>

# ── Paths ─────────────────────────────────────────────────────────────────────
$SCRIPT_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SOURCE_KEY  = Join-Path $SCRIPT_DIR "Config\scanner_id"
$USER_KEY    = Join-Path $env:USERPROFILE ".ssh\aegis_scanner_id"
$LOCAL_CONF  = Join-Path $env:APPDATA "MTS_Aegis\launcher.conf"

# ── Defaults (overridden by saved config or first-run wizard) ─────────────────
$TARGET      = ""
$SSH_PORT    = 22
$WEB_PORT    = 8080
$SSH_USER    = "usbviruscheck"

# ── Colours ───────────────────────────────────────────────────────────────────
function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  =====================================================" -ForegroundColor Cyan
    Write-Host "    MTS AEGIS  ||  USB THREAT ANALYSIS SYSTEM"          -ForegroundColor Cyan
    Write-Host "  =====================================================" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Ok($msg)   { Write-Host "  [ OK ] $msg" -ForegroundColor Green  }
function Write-Info($msg) { Write-Host "  [....] $msg" -ForegroundColor Cyan   }
function Write-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red    }

Write-Header

# ── Load or create local config ───────────────────────────────────────────────
$confDir = Split-Path $LOCAL_CONF -Parent
if (-not (Test-Path $confDir)) {
    New-Item -ItemType Directory -Path $confDir -Force | Out-Null
}

if (Test-Path $LOCAL_CONF) {
    # Load saved config
    Get-Content $LOCAL_CONF | ForEach-Object {
        if ($_ -match '^\s*([^#=]+?)\s*=\s*"?([^"]*)"?\s*$') {
            Set-Variable -Name $matches[1].Trim() -Value $matches[2].Trim()
        }
    }
}

# ── First-run wizard — ask for IP if not configured ───────────────────────────
if (-not $TARGET) {
    Write-Host "  FIRST RUN SETUP" -ForegroundColor Yellow
    Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Enter the IP address of the Aegis appliance." -ForegroundColor White
    Write-Host "  This is saved locally and will not be asked again." -ForegroundColor Gray
    Write-Host ""
    $TARGET = Read-Host "  Appliance IP"

    if (-not $TARGET) {
        Write-Err "IP address is required."
        Read-Host "  Press Enter to exit"
        exit 1
    }

    # Optionally change ports
    Write-Host ""
    $portInput = Read-Host "  SSH port [default: 22]"
    if ($portInput) { $SSH_PORT = [int]$portInput }

    $webInput = Read-Host "  Web UI port [default: 8080]"
    if ($webInput) { $WEB_PORT = [int]$webInput }

    $userInput = Read-Host "  SSH username [default: usbviruscheck]"
    if ($userInput) { $SSH_USER = $userInput }

    # Save config
    @"
TARGET="$TARGET"
SSH_PORT="$SSH_PORT"
WEB_PORT="$WEB_PORT"
SSH_USER="$SSH_USER"
"@ | Set-Content $LOCAL_CONF

    Write-Ok "Configuration saved to $LOCAL_CONF"
    Write-Host ""
    Write-Host "  To change the appliance IP later, delete:" -ForegroundColor Gray
    Write-Host "  $LOCAL_CONF" -ForegroundColor Gray
    Write-Host ""
    Start-Sleep -Seconds 2
    Write-Header
}

$TUNNEL_URL = "http://127.0.0.1:$WEB_PORT"

Write-Info "Appliance : $TARGET"
Write-Info "Web UI    : $TUNNEL_URL"
Write-Host ""

# ── Check: SSH client ─────────────────────────────────────────────────────────
$sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $sshCmd) {
    Write-Err "OpenSSH client not found."
    Write-Host ""
    Write-Host "  Install: Settings > Apps > Optional Features > OpenSSH Client" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}
$sshPath = $sshCmd.Source

# ── Check: key file exists ────────────────────────────────────────────────────
if (-not (Test-Path $SOURCE_KEY)) {
    Write-Err "SSH key not found at:"
    Write-Host "  $SOURCE_KEY" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Place the scanner_id file in the Config\ subfolder." -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# ── Install key to user profile ───────────────────────────────────────────────
# Keys in the user's own .ssh folder are always accepted by SSH.
# We auto-update if the source key has changed (key rotation).
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

$needsUpdate = $false
if (-not (Test-Path $USER_KEY)) {
    $needsUpdate = $true
} else {
    $srcHash  = (Get-FileHash $SOURCE_KEY -Algorithm MD5).Hash
    $destHash = (Get-FileHash $USER_KEY   -Algorithm MD5).Hash
    if ($srcHash -ne $destHash) { $needsUpdate = $true }
}

if ($needsUpdate) {
    Write-Info "Installing key for $env:USERNAME..."
    try {
        Copy-Item -Path $SOURCE_KEY -Destination $USER_KEY -Force

        # Strip all ACLs, grant read-only to current user only
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "Read", "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $USER_KEY -AclObject $acl
        Write-Ok "Key installed for $env:USERNAME."
    }
    catch {
        Write-Err "Could not install key: $_"
        Read-Host "  Press Enter to exit"
        exit 1
    }
} else {
    Write-Ok "Key up to date."
}

# ── Check: port availability ──────────────────────────────────────────────────
$portInUse = Get-NetTCPConnection -LocalPort $WEB_PORT -State Listen -ErrorAction SilentlyContinue
if ($portInUse) {
    Write-Warn "Port $WEB_PORT already in use — session may already be running."
    $choice = Read-Host "  Open existing session in browser? [Y/N]"
    if ($choice -match '^[Yy]') { Start-Process $TUNNEL_URL }
    exit 0
}

# ── Kill leftover tunnels ─────────────────────────────────────────────────────
Get-Process -Name ssh -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq "MTS_AEGIS_TUNNEL" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# ── Establish tunnel ──────────────────────────────────────────────────────────
Write-Info "Connecting to $TARGET..."

$sshArgs = @(
    "-i", $USER_KEY,
    "-p", $SSH_PORT,
    "-N",
    "-L", "${WEB_PORT}:127.0.0.1:${WEB_PORT}",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "-o", "ExitOnForwardFailure=yes",
    "$SSH_USER@$TARGET"
)

$tunnel = Start-Process -FilePath $sshPath `
    -ArgumentList $sshArgs `
    -WindowStyle Hidden `
    -PassThru

# Poll for tunnel — up to 15 seconds
$attempts  = 0
$connected = $false
while ($attempts -lt 8) {
    Start-Sleep -Seconds 2
    $listening = Get-NetTCPConnection -LocalPort $WEB_PORT -State Listen -ErrorAction SilentlyContinue
    if ($listening) { $connected = $true; break }
    $attempts++
    Write-Info "Waiting for tunnel... ($attempts/8)"
}

if (-not $connected) {
    Write-Err "Could not connect to $TARGET."
    Write-Host ""
    Write-Host "  - Check the appliance is online and reachable"     -ForegroundColor Gray
    Write-Host "  - Verify the IP in: $LOCAL_CONF"                   -ForegroundColor Gray
    Write-Host "    (delete the file to re-run setup)"               -ForegroundColor Gray
    Write-Host ""
    $tunnel | Stop-Process -Force -ErrorAction SilentlyContinue
    Read-Host "  Press Enter to exit"
    exit 1
}

# ── Open browser ──────────────────────────────────────────────────────────────
Write-Ok "Tunnel established."
Start-Sleep -Milliseconds 500
Start-Process $TUNNEL_URL

# ── Session ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host "   AEGIS: CONNECTED  |  $TARGET  |  $TUNNEL_URL"        -ForegroundColor Green
Write-Host "  =====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Keep this window open. Press Enter to disconnect."     -ForegroundColor Gray
Write-Host ""
Read-Host "  Press Enter to disconnect"

# ── Shutdown ──────────────────────────────────────────────────────────────────
$tunnel | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Write-Ok "Session terminated."
Start-Sleep -Seconds 2
