#!/usr/bin/env bash
# setup.sh - Consolidated Unify Desktop Assistant Setup Script (macOS)
#
# Single script to install, configure, and start all services for localhost use.
# Mirrors ubuntu/tools/setup.sh for feature parity.
#
# Usage:
#   sudo ./setup.sh --unify-key "your-key"
#   sudo ./setup.sh --unify-key "your-key" --orchestra-url "https://api.unify.ai/v0"
#   ./setup.sh --start         # Start services only (no install/config, no root needed)
#   ./setup.sh --stop          # Stop services
#   ./setup.sh --uninstall     # Stop services, remove launchd agents & cleanup
#   sudo ./setup.sh --unify-key "your-key" --force   # Force reinstall
#
# Services started:
#   - Apple Screen Sharing / VNC (port 5900)
#   - websockify + noVNC (port 6080)
#   - Agent Service (port 3000 cloud SaaS, 13000 when ~/.unity compose self-host)
#
# Access URLs:
#   - Desktop: http://localhost:6080/custom.html (sign in with macOS account)
#   - Agent API: http://localhost:3000 (or :13000 for Unity Docker self-host)

set -euo pipefail

START_TIME=$(date +%s)
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$TOOLS_DIR")"
NOVNC_DIR="$TOOLS_DIR/novnc"
MAGNITUDE_DIR="$INSTALL_DIR/magnitude"
AGENT_SERVICE_DIR="$INSTALL_DIR/agent-service"
LOG_DIR="$INSTALL_DIR/logs"
RATHOLE_DIR="$INSTALL_DIR/rathole"
RATHOLE_BIN="$RATHOLE_DIR/rathole"
RATHOLE_CONFIG="$RATHOLE_DIR/client.toml"
RCLONE_DIR="$INSTALL_DIR/rclone"
RCLONE_BIN="$RCLONE_DIR/rclone"
SSH_DIR="$INSTALL_DIR/ssh"
SSH_HOST_KEY="$SSH_DIR/host_ed25519"
SSH_AUTH_KEYS="$SSH_DIR/authorized_keys"
SFTP_LOCAL_PORT=2222
SFTP_RATHOLE_CONFIG="$RATHOLE_DIR/sftp-tunnel.toml"

# macOS Screen Sharing management
KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

# Default configuration
UNIFY_KEY=""
ORCHESTRA_URL="https://api.unify.ai/v0"
UNITY_COMMS_URL="https://service.a.run.app"
DO_START=false
DO_STOP=false
DO_UNINSTALL=false
DO_SYNC_KEYS=false
FORCE=false
SKIP_BREW=false
NO_START=false
PREREQS_ONLY=false
DEVICE_NAME=""
ENABLE_SS=false
RECONFIGURE=false
SELF_HOST_MODE=false
LINK_COORDINATOR=false
COORDINATOR_AGENT_ID=""
SELF_HOST_AGENT_PORT=13000
COMPOSE_SELF_HOST_ORCHESTRA_URL="http://127.0.0.1:8000/v0"
COMPOSE_SELF_HOST_COMMS_URL="http://127.0.0.1:8001"

# =============================================================================
# Argument Parsing
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --unify-key KEY       Unify API key (required for install)
  --orchestra-url URL   Orchestra URL (default: https://api.unify.ai/v0)
  --unity-comms-url URL Unity Comms URL
  --start               Start services only (no install/config, no root needed)
  --stop                Stop all services
  --uninstall           Stop services, remove launchd agents & cleanup
  --sync-keys           Reconcile SFTP authorized_keys + report tunnel coords, then exit
  --skip-brew           Skip Homebrew operations (assume deps are pre-installed)
  --no-start            Skip starting services at end (used by .pkg postinstall)
  --prereqs-only        Install prerequisites only (no key required, no config/registration)
  --reconfigure         Re-apply key + re-register + restart services (no deps, no autostart)
  --self-host           Unity Docker self-host mode (local Orchestra, no tunnel, port ${SELF_HOST_AGENT_PORT})
  --link-coordinator    Link registered desktop to the Coordinator assistant (self-host)
  --coordinator-agent-id ID  Coordinator agent id for --link-coordinator (optional)
  --enable-screen-sharing (root) Enable Apple Screen Sharing (ARD account auth)
  --device-name NAME    Friendly device name for registration (default: short hostname)
  --force               Force reinstall all components
  -h, --help            Show this help message

Examples:
  sudo ./setup.sh --unify-key "your-key"
  ./setup.sh --start
  ./setup.sh --stop
  sudo ./setup.sh --uninstall
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unify-key)
            UNIFY_KEY="$2"; shift 2 ;;
        --orchestra-url)
            ORCHESTRA_URL="$2"; shift 2 ;;
        --unity-comms-url)
            UNITY_COMMS_URL="$2"; shift 2 ;;
        --start)
            DO_START=true; shift ;;
        --stop)
            DO_STOP=true; shift ;;
        --uninstall)
            DO_UNINSTALL=true; shift ;;
        --sync-keys)
            DO_SYNC_KEYS=true; shift ;;
        --skip-brew)
            SKIP_BREW=true; shift ;;
        --no-start)
            NO_START=true; shift ;;
        --prereqs-only)
            PREREQS_ONLY=true; shift ;;
        --reconfigure)
            RECONFIGURE=true; shift ;;
        --self-host)
            SELF_HOST_MODE=true; shift ;;
        --link-coordinator)
            LINK_COORDINATOR=true; shift ;;
        --coordinator-agent-id)
            COORDINATOR_AGENT_ID="$2"; shift 2 ;;
        --enable-screen-sharing)
            ENABLE_SS=true; shift ;;
        --device-name)
            DEVICE_NAME="$2"; shift 2 ;;
        --force)
            FORCE=true; shift ;;
        -h|--help)
            usage ;;
        *)
            echo "Unknown option: $1" >&2
            usage ;;
    esac
done

echo ""
echo "=========================================="
echo "  Unify Desktop Assistant Setup (macOS)"
echo "=========================================="
echo ""

# Ensure Homebrew (and tools it installs: node/bun/npx/pip3) are on PATH.
# When invoked via `su - <user> -c ...` (e.g. from the .pkg postinstall), the
# shell is non-interactive and does NOT source ~/.zshrc, so a brew shellenv
# placed there is missed. Load it explicitly from the known locations.
for _brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$_brew_bin" ]]; then
        eval "$("$_brew_bin" shellenv)" 2>/dev/null || true
        break
    fi
done
# Make user-local bun visible too (curl-installer fallback target).
[[ -d "$HOME/.bun/bin" ]] && export PATH="$HOME/.bun/bin:$PATH"

# -----------------------------------------------------------------------------
# Resolve a single, deterministic Python interpreter.
#
# websockify/rumps are pip-installed into one interpreter; if a *different*
# python3 later starts them, `python3 -m websockify` fails and port 6080 never
# binds. This happens because the installer's start runs in a login shell (full
# PATH: pyenv/python.org/etc.) while the tray starts services from a non-login
# shell that only re-adds Homebrew — so bare `python3` resolves differently.
# Pin the interpreter once and reuse it for install, start, the prereq check,
# and the tray plist so they always match.
# -----------------------------------------------------------------------------
PYTHON_BIN_FILE="$TOOLS_DIR/.python-bin"

python_has_websockify() {
    local p="$1"
    [[ -n "$p" && -x "$p" ]] && "$p" -c 'import websockify' 2>/dev/null
}

python_pip_works() {
    local p="$1"
    [[ -n "$p" && -x "$p" ]] && "$p" -m pip --version &>/dev/null 2>&1
}

resolve_python_bin() {
    # 1. Honor a previously persisted interpreter when it is still usable.
    if [[ -f "$PYTHON_BIN_FILE" ]]; then
        local saved
        saved="$(head -n1 "$PYTHON_BIN_FILE" 2>/dev/null || true)"
        if python_has_websockify "$saved" || python_pip_works "$saved"; then
            echo "$saved"
            return 0
        fi
    fi
    # 2. Prefer an interpreter that already has websockify importable.
    local p
    for p in /usr/bin/python3 /opt/homebrew/opt/python@3.12/bin/python3 \
             /opt/homebrew/opt/python@3.11/bin/python3 \
             "$(command -v python3 2>/dev/null || true)" \
             /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if python_has_websockify "$p"; then
            echo "$p"
            return 0
        fi
    done
    # 3. Fall back to any Python with a working pip (skip broken Homebrew 3.14).
    for p in /usr/bin/python3 /opt/homebrew/opt/python@3.12/bin/python3 \
             /opt/homebrew/opt/python@3.11/bin/python3 \
             "$(command -v python3 2>/dev/null || true)" \
             /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if python_pip_works "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo /usr/bin/python3
}

PYTHON_BIN="$(resolve_python_bin)"

# =============================================================================
# Helper Functions
# =============================================================================

test_port_listening() {
    local port=$1
    lsof -iTCP:"$port" -sTCP:LISTEN -P >/dev/null 2>&1 && return 0
    # Apple Screen Sharing accepts TCP on 5900 without a user-visible LISTEN
    # socket in lsof. Fall back to a connect probe (same as unify-assistant.py).
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

get_package_json_hash() {
    local dir=$1
    local pkg_file="$dir/package.json"
    if [[ -f "$pkg_file" ]]; then
        md5 -q "$pkg_file" 2>/dev/null | cut -c1-8
    fi
}

test_dependencies_installed() {
    local dir=$1
    local node_modules="$dir/node_modules"
    local hash_file="$dir/.pkg-hash"

    [[ -d "$node_modules" ]] || return 1
    [[ -f "$hash_file" ]] || return 1

    local saved_hash
    saved_hash=$(cat "$hash_file" 2>/dev/null)
    local current_hash
    current_hash=$(get_package_json_hash "$dir")

    [[ "$saved_hash" == "$current_hash" ]]
}

save_dependencies_hash() {
    local dir=$1
    local hash
    hash=$(get_package_json_hash "$dir")
    if [[ -n "$hash" ]]; then
        printf '%s' "$hash" > "$dir/.pkg-hash"
    fi
}

get_env_value() {
    local key=$1
    local env_file="$AGENT_SERVICE_DIR/.env"
    if [[ -f "$env_file" ]]; then
        grep -E "^${key}=" "$env_file" 2>/dev/null | sed "s/^${key}=//;s/^[\"']//;s/[\"']$//" || true
    fi
}

# -----------------------------------------------------------------------------
# Screen Sharing (Apple Remote Management) management
#
# Remote access is password-only (no macOS username required). We enable legacy
# VNC password auth (`-setvnclegacy`/`-setvncpw`) and set the VNC password to the
# first 8 chars of UNIFY_KEY (legacy VNC passwords are capped at 8 chars). This
# is the toggle Apple exposes in System Settings as "VNC viewers may control
# screen with password" (VNCLegacyConnectionsEnabled=1); with it set, the server
# advertises RFB security type 2 (VNC auth) and completes the handshake. The
# bundled noVNC is patched (see install_novnc) to prefer type 2 over Apple ARD
# (type 30) so the browser client never prompts for a macOS username.
#
# The macOS session lock is a separate layer handled outside this script (Unify
# stores the account password as a secret); we do not touch screen-lock here.
# -----------------------------------------------------------------------------

# Root-only: enable macOS *basic* Screen Sharing (com.apple.screensharing) with
# password-only legacy VNC.
#
# IMPORTANT: we deliberately use basic Screen Sharing, NOT Remote Management
# (ARD). Both share the screensharingd binary and read the same VNC password
# (com.apple.VNCSettings.txt) + VNCLegacyConnectionsEnabled flag, but only the
# basic Screen Sharing service hands a legacy VNC (RFB type 2) connection off to
# AppleVNCServer/VNCPrivilegeProxy to produce the framebuffer. ARD's path
# authenticates the VNC password but then stalls before ServerInit (the client
# hangs on "Connecting…" forever). So we enable com.apple.screensharing and keep
# com.apple.remotemanagementd disabled.
do_enable_screen_sharing() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: --enable-screen-sharing requires root (use sudo)." >&2
        return 1
    fi
    if [[ ! -f "$KICKSTART" ]]; then
        echo "ERROR: kickstart not found — cannot manage Screen Sharing." >&2
        return 1
    fi
    echo "Enabling Screen Sharing..."

    local key
    key=$(get_env_value "UNIFY_KEY")

    enable_basic_screen_sharing "$key"
    echo "  Screen Sharing enabled."
}

# Shared helper: configure password-only legacy VNC and bring up the basic
# Screen Sharing service. $1 = UNIFY_KEY (VNC password derives from first 8
# chars). Must run as root.
enable_basic_screen_sharing() {
    local key="$1"
    local ss_plist="/System/Library/LaunchDaemons/com.apple.screensharing.plist"

    # Configure password-only legacy VNC. `kickstart -configure` only writes
    # settings (VNCSettings.txt + prefs); it does NOT activate ARD.
    if [[ -n "$key" ]]; then
        "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy yes 2>&1 || true
        "$KICKSTART" -configure -clientopts -setvncpw -vncpw "${key:0:8}" 2>&1 || true
    else
        echo "  WARNING: UNIFY_KEY not set — VNC password not configured." >&2
    fi
    defaults write /Library/Preferences/com.apple.RemoteManagement \
        VNCLegacyConnectionsEnabled -bool true 2>/dev/null || true
    # Don't require local approval for incoming connections (unattended).
    defaults write /Library/Preferences/com.apple.RemoteManagement \
        ScreenSharingReqPermEnabled -bool false 2>/dev/null || true

    # Keep Remote Management (ARD) OFF — its legacy-VNC path hangs at ServerInit.
    launchctl disable system/com.apple.remotemanagementd 2>/dev/null || true

    # Enable + start basic Screen Sharing (clears any persisted disable override
    # left by a previous uninstall, then bootstraps the socket-activated job).
    launchctl enable system/com.apple.screensharing 2>/dev/null || true
    launchctl bootstrap system "$ss_plist" 2>/dev/null \
        || launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true

    # The system daemon (above) only binds port 5900 + does VNC auth. The actual
    # screen capture is done by a PER-LOGIN-SESSION agent
    # (gui/$uid/com.apple.screensharing.agent) that must attach to the user's
    # WindowServer. If we don't (re)launch it inside the active GUI session, the
    # first connection authenticates but streams a BLACK framebuffer until the
    # user toggles Screen Sharing in System Settings. Kick it here to reproduce
    # what that toggle does.
    local _cuser _cuid
    _cuser="$(scutil <<< 'show State:/Users/ConsoleUser' 2>/dev/null | awk '/Name :/ { print $3 }')"
    if [[ -z "$_cuser" || "$_cuser" == "loginwindow" || "$_cuser" == "root" ]]; then
        _cuser="${SUDO_USER:-}"
    fi
    _cuid="$(id -u "$_cuser" 2>/dev/null || true)"
    if [[ -n "$_cuid" && "$_cuid" != "0" ]]; then
        local _agent="gui/$_cuid/com.apple.screensharing.agent"
        launchctl asuser "$_cuid" launchctl enable "$_agent" 2>/dev/null || true
        launchctl asuser "$_cuid" launchctl kickstart -k "$_agent" 2>/dev/null || true
    else
        echo "  WARNING: could not resolve GUI console user — screen capture" >&2
        echo "  agent not kicked; remote view may be black until you toggle" >&2
        echo "  Screen Sharing in System Settings once." >&2
    fi
}

set_env_value() {
    local key=$1
    local value=$2
    local env_file="$AGENT_SERVICE_DIR/.env"

    mkdir -p "$(dirname "$env_file")"

    if [[ -f "$env_file" ]] && grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# =============================================================================
# Unity Docker Compose self-host (local ~/.unity stack)
# =============================================================================

compose_self_host_present() {
    [[ -f "${HOME}/.unity/docker-compose.yml" ]]
}

apply_compose_self_host_mode() {
    if ! compose_self_host_present; then
        return 0
    fi
    SELF_HOST_MODE=true
    ORCHESTRA_URL="$COMPOSE_SELF_HOST_ORCHESTRA_URL"
    UNITY_COMMS_URL="$COMPOSE_SELF_HOST_COMMS_URL"
    LINK_COORDINATOR=true
}

explain_orchestra_connect_failure() {
    local action_description=$1
    local orchestra_url=$2
    local http_code=$3

    if [[ -n "$http_code" && "$http_code" != "000" ]]; then
        return 1
    fi

    echo "  ERROR: Could not connect to Orchestra at ${orchestra_url} while trying to ${action_description}." >&2
    if compose_self_host_present || [[ "$orchestra_url" == *127.0.0.1* || "$orchestra_url" == *localhost* ]]; then
        echo "  Orchestra is not reachable on this machine — the Unity Docker stack is probably stopped." >&2
        echo "  Start it first:" >&2
        echo "    unity stack up" >&2
        echo "  Wait until Orchestra responds on port 8000, then register again from tray Settings" >&2
        echo "  (paste your API key) or run:" >&2
        echo "    $TOOLS_DIR/setup.sh --reconfigure --unify-key YOUR_KEY" >&2
    else
        echo "  Check that Orchestra is reachable from this machine and your network is connected." >&2
    fi
    return 0
}

# =============================================================================
# Fast Mode Detection
# =============================================================================

test_fast_mode() {
    echo "Checking installation status..." >&2

    local all_ok=true

    if [[ -f "$MAGNITUDE_DIR/package.json" ]]; then
        echo "  [OK] Magnitude (pre-installed)" >&2
    else
        echo "  [ERR] Magnitude NOT FOUND" >&2
        echo "       Expected at: $MAGNITUDE_DIR/package.json" >&2
        echo "ERROR: Required component 'Magnitude' is missing from the installation." >&2
        return 1
    fi

    if [[ -f "$AGENT_SERVICE_DIR/package.json" ]]; then
        echo "  [OK] Agent Service (pre-installed)" >&2
    else
        echo "  [ERR] Agent Service NOT FOUND" >&2
        echo "       Expected at: $AGENT_SERVICE_DIR/package.json" >&2
        echo "ERROR: Required component 'Agent Service' is missing from the installation." >&2
        return 1
    fi

    if [[ -f "$NOVNC_DIR/vnc.html" ]]; then
        echo "  [OK] noVNC" >&2
    else
        echo "  [--] noVNC (will install)" >&2
        all_ok=false
    fi

    if python_has_websockify "$PYTHON_BIN" || command -v websockify &>/dev/null; then
        echo "  [OK] websockify" >&2
    else
        echo "  [--] websockify (will install)" >&2
        all_ok=false
    fi

    if command -v node &>/dev/null; then
        local node_major
        node_major=$(node --version | sed 's/v\([0-9]*\).*/\1/')
        if [[ "$node_major" -ge 22 ]]; then
            echo "  [OK] Node.js ($(node --version))" >&2
        else
            echo "  [--] Node.js $(node --version) < v22 (will upgrade)" >&2
            all_ok=false
        fi
    else
        echo "  [--] Node.js (will install)" >&2
        all_ok=false
    fi

    if [[ -x "$RATHOLE_BIN" ]]; then
        echo "  [OK] Rathole" >&2
    else
        echo "  [--] Rathole (will install)" >&2
        all_ok=false
    fi

    if [[ -x "$RCLONE_BIN" ]]; then
        echo "  [OK] rclone" >&2
    else
        echo "  [--] rclone (will install)" >&2
        all_ok=false
    fi

    if "$PYTHON_BIN" -c "import rumps" &>/dev/null; then
        echo "  [OK] rumps" >&2
    else
        echo "  [--] rumps (will install)" >&2
        all_ok=false
    fi

    $all_ok
}

# =============================================================================
# Stop Services
# =============================================================================

stop_all_services() {
    echo ""
    echo "=== Stopping Services ==="

    # Stop tunnel first
    stop_tunnel

    # Stop launchd host service agents (tray is intentionally left loaded).
    local domain="gui/$(id -u)"
    for label in com.unify.websockify com.unify.agent com.unify.sftp com.unify.sftp-tunnel com.unify.sftp-sync; do
        launchctl bootout "$domain/$label" 2>/dev/null || true
    done

    # Stop Agent Service. It runs as `npm exec ts-node src/index.ts`, whose child
    # (the port-3000 listener) is `node …/agent-service/node_modules/.bin/ts-node
    # src/index.ts`. Match on the trailing `ts-node src/index.ts` so BOTH the npm
    # parent and the node listener are caught — the old `ts-node.*agent-service`
    # pattern never matched (in the path "agent-service" precedes "ts-node").
    local pids
    pids=$(pgrep -f 'ts-node src/index.ts' 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        echo "  Stopped Agent Service"
    fi

    # Stop websockify
    pids=$(pgrep -f 'websockify.*6080' 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        echo "  Stopped websockify"
    fi

    # Note: macOS Screen Sharing (system service on 5900) is left running here.
    # It requires root to toggle and is only disabled on full uninstall.
    #
    # The tray launchd agent (com.unify.tray) is intentionally NOT unloaded here —
    # the tray itself calls --stop, so unloading it would kill the menu-bar app.
    # The tray agent is only removed on full uninstall.

    # Final sweep: kill processes on target ports. SIGTERM first, then escalate
    # to SIGKILL for anything still listening — the Node agent handles SIGTERM
    # (graceful shutdown / keep-alive sockets) and otherwise lingers.
    local agent_port
    agent_port="$(agent_service_port)"
    for port in 6080 "$agent_port"; do
        pids=$(lsof -ti TCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs kill -TERM 2>/dev/null || true
            echo "  Killed process on port $port"
        fi
    done
    sleep 2
    for port in 6080 "$agent_port"; do
        pids=$(lsof -ti TCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs kill -KILL 2>/dev/null || true
            echo "  Force-killed lingering process on port $port"
        fi
    done

    echo ""
    echo "All services stopped."
}

# =============================================================================
# Uninstall
# =============================================================================

uninstall_all() {
    echo ""
    echo "=== Uninstalling Unify Desktop Assistant ==="

    # Resolve the real (console) user up-front. Uninstall runs as root, so $USER
    # is "root" and $HOME is /var/root. SUDO_USER is set when invoked via `sudo`
    # (CLI), but NOT when invoked via the tray's `osascript … with administrator
    # privileges`, so we fall back to the logged-in console user. This is needed
    # both to reach the user's GUI session (Screen Sharing) and to find the user's
    # LaunchAgents.
    local tgt_user tgt_home tgt_uid
    tgt_user="${SUDO_USER:-}"
    # scutil is the canonical way to find the GUI console user. `stat -f '%Su'
    # /dev/console` is unreliable (on some macOS versions /dev/console is owned
    # by root even with a user logged in), which makes the tray-context uninstall
    # (where SUDO_USER is empty) resolve to "root" and fail to disable Screen
    # Sharing in the user's session.
    if [[ -z "$tgt_user" || "$tgt_user" == "root" ]]; then
        tgt_user="$(scutil <<< 'show State:/Users/ConsoleUser' 2>/dev/null | awk '/Name :/ { print $3 }')"
    fi
    if [[ -z "$tgt_user" || "$tgt_user" == "root" || "$tgt_user" == "loginwindow" ]]; then
        tgt_user="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
    fi
    [[ -z "$tgt_user" || "$tgt_user" == "root" ]] && tgt_user="$USER"
    tgt_uid="$(id -u "$tgt_user" 2>/dev/null || echo "")"
    tgt_home="$(eval echo "~$tgt_user")"

    # 1. Stop all services
    stop_all_services

    # 1b. Disable macOS Screen Sharing (system service — requires root)
    if [[ -f "$KICKSTART" ]]; then
        if [[ "$EUID" -eq 0 ]]; then
            echo ""
            echo "Disabling Screen Sharing / Remote Management..."
            # kickstart MUST run inside the user's GUI (Aqua) session. From the
            # tray's `do shell script with administrator privileges` context (root
            # but DETACHED from the GUI session), a bare `kickstart -deactivate`
            # does NOT stop remotemanagementd — which then re-asserts the master
            # flag back to "enabled" and the menu-bar icon returns. Wrapping it in
            # `launchctl asuser "$tgt_uid"` matches the working enable path (and a
            # session-attached `sudo` in Terminal). Fall back to bare root only if
            # we couldn't resolve the user.
            local _ks=("$KICKSTART")
            [[ -n "$tgt_uid" ]] && _ks=(launchctl asuser "$tgt_uid" "$KICKSTART")
            "${_ks[@]}" -deactivate -configure -access -off 2>/dev/null || true
            "${_ks[@]}" -configure -clientopts -setvnclegacy -vnclegacy no 2>/dev/null || true

            # Tear down the running user agents (menu-bar icon = screensharing.menuextra).
            if [[ -n "$tgt_uid" ]]; then
                for _label in com.apple.screensharing.menuextra \
                              com.apple.RemoteDesktop.agent \
                              com.apple.RemoteManagementAgent \
                              com.apple.screensharing.agent; do
                    launchctl bootout "gui/$tgt_uid/$_label" 2>/dev/null || true
                done
            fi

            # Persist-disable the on-demand system daemons FIRST, then bootout.
            # macOS launches com.apple.screensharing via socket activation (port
            # 5900) and com.apple.remotemanagementd via its Mach service, so a
            # plain `bootout`/`kickstart -deactivate` only kills the *running*
            # instance — the next TCP connection / Mach request respawns it, and
            # a respawned remotemanagementd re-asserts the master flag back to
            # "enabled" (the menu-bar icon returns "on its own"). `launchctl
            # disable` writes a persisted override (in disabled.plist) that
            # survives and prevents on-demand relaunch. The modern
            # disable/bootout API replaces the legacy, SIP-unreliable
            # `launchctl unload -w`.
            for _d in com.apple.screensharing com.apple.remotemanagementd; do
                launchctl disable "system/$_d" 2>/dev/null || true
            done
            for _d in com.apple.remotemanagementd \
                      com.apple.RemoteDesktop.PrivilegeProxy \
                      com.apple.screensharing; do
                launchctl bootout "system/$_d" 2>/dev/null || true
            done

            # Flip the master flag LAST, after the agents/daemons are down, so
            # nothing is left alive to re-assert "enabled" after us. (Lives under
            # /Library, not /System — root-writable, not SIP-locked.)
            RM_FLAG="/Library/Application Support/Apple/Remote Desktop/RemoteManagement.launchd"
            [[ -f "$RM_FLAG" ]] && printf 'disabled' > "$RM_FLAG" 2>/dev/null || true

            # Kill any stragglers so the menu-bar icon disappears immediately
            # instead of lingering until the next logout.
            killall SSMenuAgent ARDAgent screensharingd remotemanagementd 2>/dev/null || true

            # Remove the custom VNC password file kickstart wrote on enable.
            rm -f /Library/Preferences/com.apple.VNCSettings.txt 2>/dev/null || true
            echo "  Screen Sharing / Remote Management disabled"
        else
            echo ""
            echo "  WARNING: Screen Sharing requires root to disable. Run: sudo setup.sh --uninstall" >&2
        fi
    fi

    # 2. Unregister desktop and tunnel from server
    local unify_key orchestra_url comms_url
    unify_key=$(get_env_value "UNIFY_KEY")
    orchestra_url=$(get_env_value "ORCHESTRA_URL")
    comms_url=$(get_env_value "UNITY_COMMS_URL")

    if [[ -n "$unify_key" ]]; then
        echo ""
        echo "Cleaning up remote registrations..."
        [[ -n "$orchestra_url" ]] && unregister_desktop "$unify_key" "$orchestra_url"
        [[ -n "$comms_url" ]] && unregister_tunnel "$unify_key" "$comms_url"
        [[ -n "$comms_url" ]] && unregister_sftp_tunnel "$unify_key" "$comms_url"
    fi

    # 3. Remove rathole
    if [[ -d "$RATHOLE_DIR" ]]; then
        rm -rf "$RATHOLE_DIR"
        echo "  Removed rathole directory"
    fi

    # 3b. Remove rclone + SFTP host key / authorized_keys (local-only material).
    if [[ -d "$RCLONE_DIR" ]]; then
        rm -rf "$RCLONE_DIR"
        echo "  Removed rclone directory"
    fi
    if [[ -d "$SSH_DIR" ]]; then
        rm -rf "$SSH_DIR"
        echo "  Removed SFTP key directory"
    fi

    # 4. Remove launchd agents (tgt_user/tgt_home/tgt_uid resolved at top)
    echo ""
    echo "Removing launchd agents..."
    for agent in com.unify.tray com.unify.tunnel com.unify.websockify com.unify.agent com.unify.sftp com.unify.sftp-tunnel com.unify.sftp-sync; do
        local plist="$tgt_home/Library/LaunchAgents/${agent}.plist"
        if [[ -f "$plist" ]]; then
            if [[ -n "$tgt_uid" ]]; then
                launchctl bootout "gui/$tgt_uid/$agent" 2>/dev/null || \
                    launchctl unload "$plist" 2>/dev/null || true
            fi
            rm -f "$plist"
            echo "  Removed: $agent"
        fi
    done

    # 5. Remove macOS firewall exceptions (best-effort)
    if command -v /usr/libexec/ApplicationFirewall/socketfilterfw &>/dev/null; then
        echo ""
        echo "Removing firewall exceptions..."
        local websockify_path
        websockify_path=$(command -v websockify 2>/dev/null || true)
        if [[ -n "$websockify_path" ]]; then
            sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "$websockify_path" 2>/dev/null || true
        fi
    fi

    # 6. Forget the installer receipt and remove the CLI wrapper
    echo ""
    echo "Removing installer receipt and CLI wrapper..."
    if [[ "$EUID" -eq 0 ]]; then
        pkgutil --forget ai.unify.desktop-assistant 2>/dev/null || true
        rm -f /usr/local/bin/unify-desktop-assistant 2>/dev/null || true
        echo "  Done"
    else
        echo "  WARNING: run with sudo to remove the receipt and CLI wrapper." >&2
    fi

    # 7. Remove the install directory.
    # This script is executing from inside $INSTALL_DIR/tools, so a plain `rm`
    # could truncate the still-running script. We instead `exec` a tiny in-memory
    # shell (program text comes from -c, not a file in $INSTALL_DIR) as the LAST
    # step: exec replaces this process image, releasing the on-disk script, then
    # removes the directory synchronously. Doing it synchronously (rather than a
    # detached background job) is essential because the tray runs uninstall via
    # `osascript … with administrator privileges`, whose privileged context reaps
    # any backgrounded child before it can run — which is why the old deferred
    # delete worked from the CLI but left folders behind from the tray.
    # Guarded to the expected path so a misconfigured INSTALL_DIR can never
    # trigger a destructive delete.
    echo ""
    if [[ "$EUID" -eq 0 && "$INSTALL_DIR" == "/opt/unify-desktop-assistant" && -d "$INSTALL_DIR" ]]; then
        echo "Removing $INSTALL_DIR..."
        echo ""
        echo "Uninstall complete. Unify Desktop Assistant has been fully removed."
        exec /bin/bash -c "rm -rf '$INSTALL_DIR'"
    elif [[ -d "$INSTALL_DIR" ]]; then
        echo "To finish removal, run: sudo rm -rf $INSTALL_DIR" >&2
    fi

    echo ""
    echo "Uninstall complete. Unify Desktop Assistant has been fully removed."
}

# =============================================================================
# Installation Functions
# =============================================================================

install_system_deps() {
    echo ""
    echo "=== Installing System Dependencies ==="

    if $SKIP_BREW; then
        echo "  Skipping Homebrew installs (dependencies expected to be pre-installed)"
        return
    fi

    if ! command -v brew &>/dev/null; then
        echo "  ERROR: Homebrew not found. Install from https://brew.sh" >&2
        return 1
    fi

    local packages=(git python3 jq)
    local to_install=()

    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        echo "  Installing: ${to_install[*]}"
        brew install "${to_install[@]}"
    fi

    echo "  System dependencies OK"
}

install_nodejs() {
    if command -v node &>/dev/null; then
        local node_major
        node_major=$(node --version | sed 's/v\([0-9]*\).*/\1/')
        if [[ "$node_major" -ge 22 ]]; then
            echo "  Node.js already installed ($(node --version))"
            return
        fi
        echo "  Node.js $(node --version) found, but v22+ required. Upgrading..."
    fi

    echo ""
    echo "=== Installing Node.js 22 ==="

    if $SKIP_BREW; then
        echo "  WARNING: Cannot install Node.js (Homebrew skipped)." >&2
        echo "  Ensure Node.js v22+ is installed before running --start." >&2
        return
    fi

    if ! command -v brew &>/dev/null; then
        echo "  ERROR: Homebrew not found. Install Node.js v22 manually." >&2
        return 1
    fi

    brew install node@22
    brew link --overwrite node@22 2>/dev/null || true

    echo "  Node.js installed ($(node --version))"
}

install_bun() {
    if command -v bun &>/dev/null; then
        echo "  Bun already installed ($(bun --version))"
        return
    fi

    echo ""
    echo "=== Installing Bun ==="

    if command -v npm &>/dev/null; then
        echo "  Installing bun via npm (global)..."
        npm install -g bun && {
            echo "  Bun installed ($(bun --version))"
            return
        }
        echo "  npm global install failed, trying curl installer..." >&2
    fi

    curl -fsSL https://bun.sh/install | bash || {
        echo "  ERROR: Bun install failed" >&2
        return 1
    }

    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"

    echo "  Bun installed ($(bun --version 2>/dev/null || echo 'unknown'))"
}

install_websockify() {
    echo ""
    echo "=== Installing websockify ==="

    if python_has_websockify "$PYTHON_BIN"; then
        echo "  websockify already installed ($PYTHON_BIN)"
        echo "$PYTHON_BIN" > "$PYTHON_BIN_FILE" 2>/dev/null || true
        return 0
    fi

    if ! python_pip_works "$PYTHON_BIN"; then
        echo "ERROR: pip is not usable for $PYTHON_BIN — cannot install websockify." >&2
        echo "  Try: /usr/bin/python3 -m pip install --user websockify" >&2
        echo "  Then: echo /usr/bin/python3 > $PYTHON_BIN_FILE" >&2
        return 1
    fi

    "$PYTHON_BIN" -m pip install --break-system-packages websockify 2>/dev/null \
        || "$PYTHON_BIN" -m pip install websockify

    # Persist the interpreter so --start (run later from the tray's non-login
    # shell) uses the exact same Python that now has the websockify module.
    echo "$PYTHON_BIN" > "$PYTHON_BIN_FILE" 2>/dev/null || true

    echo "  websockify installed via pip ($PYTHON_BIN)"
}

install_rumps() {
    echo ""
    echo "=== Installing rumps (tray app) ==="

    if "$PYTHON_BIN" -c "import rumps" &>/dev/null 2>&1; then
        echo "  rumps already installed"
        return
    fi

    if ! python_pip_works "$PYTHON_BIN"; then
        echo "ERROR: pip is not usable for $PYTHON_BIN — cannot install rumps." >&2
        return 1
    fi

    "$PYTHON_BIN" -m pip install --break-system-packages rumps 2>/dev/null \
        || "$PYTHON_BIN" -m pip install rumps

    echo "  rumps installed via pip ($PYTHON_BIN)"
}

install_novnc() {
    echo ""
    echo "=== Installing noVNC ==="

    local vnc_html="$NOVNC_DIR/vnc.html"

    if [[ ! -f "$vnc_html" ]]; then
        if [[ -d "$NOVNC_DIR" ]]; then
            rm -rf "$NOVNC_DIR"
        fi

        echo "  Cloning noVNC repository..."
        git clone --depth 1 https://github.com/novnc/noVNC.git "$NOVNC_DIR"

        if [[ -f "$vnc_html" ]]; then
            echo "  noVNC cloned"
        else
            echo "ERROR: noVNC clone failed" >&2
            return 1
        fi
    fi

    echo "  Creating custom.html..."

    cat > "$NOVNC_DIR/custom.html" <<'CUSTOMHTML'
<!DOCTYPE html>
<html>
<head>
    <title>Desktop</title>
    <style>
        body, html { margin: 0; padding: 0; overflow: hidden; background: #000; }
        iframe { width: 100vw; height: 100vh; border: none; }
    </style>
</head>
<body>
    <iframe id="vnc" src=""></iframe>
    <script>
        const params = new URLSearchParams(window.location.search);
        params.set('resize', 'scale');
        params.set('autoconnect', '1');
        params.set('reconnect', '1');
        params.set('show_dot', '1');
        document.getElementById('vnc').src = `vnc.html?${params}`;

        document.getElementById('vnc').onload = function() {
            try {
                const style = this.contentDocument.createElement('style');
                style.textContent = `
                    #noVNC_control_bar,
                    #noVNC_control_bar_anchor,
                    #noVNC_control_bar_handle,
                    #noVNC_logo,
                    #noVNC_status { display: none !important; }
                    .noVNC_cursor { display: none !important; }
                `;
                this.contentDocument.head.appendChild(style);
            } catch (e) {
                console.warn('Could not inject CSS (cross-origin)', e);
            }
        };
    </script>
</body>
</html>
CUSTOMHTML

    cp "$NOVNC_DIR/custom.html" "$NOVNC_DIR/index.html"
    echo "  custom.html created"

    # Prefer password-only VNC auth (RFB security type 2) over Apple ARD (type
    # 30). macOS advertises both, with ARD first; stock noVNC picks the server's
    # first supported type, which would force a macOS username prompt. We reorder
    # the client's selection to use type 2 when offered so remote access is
    # password-only. Idempotent: skipped if the marker is already present.
    local rfb="$NOVNC_DIR/core/rfb.js"
    if [[ -f "$rfb" ]]; then
        if grep -q "Unify patch: prefer password-only" "$rfb"; then
            echo "  noVNC already patched for password-only VNC auth"
        else
            perl -0777 -pi -e 's/(this\._rfbAuthScheme = -1;\n)(\s*)for \(let type of types\) \{/${1}${2}\/\/ Unify patch: prefer password-only VNC auth (type 2) over Apple ARD (type 30)\n${2}const _unifyOrdered = Array.from(types).includes(2) ? [2] : Array.from(types);\n${2}for (let type of _unifyOrdered) {/' "$rfb"
            if grep -q "Unify patch: prefer password-only" "$rfb"; then
                echo "  noVNC patched: prefer password-only VNC auth (type 2)"
            else
                echo "  WARNING: noVNC rfb.js patch did not apply (upstream layout changed?)" >&2
            fi
        fi
    fi
}

install_magnitude() {
    echo ""
    echo "=== Setting up Magnitude ==="

    if [[ ! -f "$MAGNITUDE_DIR/package.json" ]]; then
        echo "  ERROR: magnitude not found at $MAGNITUDE_DIR" >&2
        echo "  This should be included in the installer package." >&2
        return 1
    fi

    local bun_exe=""
    if command -v bun &>/dev/null; then
        bun_exe="$(command -v bun)"
    else
        if [[ -x "$HOME/.bun/bin/bun" ]]; then
            bun_exe="$HOME/.bun/bin/bun"
            export BUN_INSTALL="$HOME/.bun"
            export PATH="$BUN_INSTALL/bin:$PATH"
        fi
    fi

    if test_dependencies_installed "$MAGNITUDE_DIR" && [[ "$FORCE" == "false" ]]; then
        echo "  Dependencies up-to-date"
    else
        echo "  Installing dependencies and building magnitude workspace..."

        pushd "$MAGNITUDE_DIR" >/dev/null

        if [[ -n "$bun_exe" ]]; then
            echo "  Running bun install (includes build via postinstall)..."
            echo "  Using: $bun_exe"
            "$bun_exe" install

            echo "  Installing Patchright + Chromium (this may take a few minutes)..."
            export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/browsers"
            mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
            npx -y patchright install chromium
            echo "  Patchright + Chromium installed"
        else
            echo "  ERROR: bun is required for magnitude (packageManager: bun)" >&2
            echo "  Try: npm install -g bun  OR  curl -fsSL https://bun.sh/install | bash" >&2
            popd >/dev/null
            return 1
        fi

        save_dependencies_hash "$MAGNITUDE_DIR"
        popd >/dev/null
    fi
}

install_agent_service() {
    echo ""
    echo "=== Installing Agent Service ==="

    local pkg_json="$AGENT_SERVICE_DIR/package.json"

    if [[ ! -f "$pkg_json" ]]; then
        echo "  ERROR: agent-service not found at $AGENT_SERVICE_DIR" >&2
        return 1
    fi

    if test_dependencies_installed "$AGENT_SERVICE_DIR" && [[ "$FORCE" == "false" ]]; then
        echo "  Dependencies up-to-date"
    else
        pushd "$AGENT_SERVICE_DIR" >/dev/null

        echo "  Installing npm dependencies..."
        npm install

        save_dependencies_hash "$AGENT_SERVICE_DIR"
        popd >/dev/null

        echo "  Dependencies installed"
    fi
}

# =============================================================================
# Tunnel & Device Functions
# =============================================================================

install_rathole() {
    echo ""
    echo "=== Installing Rathole ==="

    if [[ -x "$RATHOLE_BIN" ]]; then
        echo "  Rathole already installed"
        return
    fi

    mkdir -p "$RATHOLE_DIR"

    # Prefer Homebrew: it provides a native binary for both arm64 and x86_64.
    # (The GitHub release has no aarch64-apple-darwin build — only x86_64.)
    if ! $SKIP_BREW && command -v brew &>/dev/null; then
        echo "  Installing rathole via Homebrew..."
        if brew list rathole &>/dev/null || brew install rathole; then
            local brew_rathole
            brew_rathole="$(brew --prefix 2>/dev/null)/bin/rathole"
            if [[ -x "$brew_rathole" ]]; then
                ln -sf "$brew_rathole" "$RATHOLE_BIN"
                echo "  Rathole installed (Homebrew): $brew_rathole"
                return
            fi
        fi
        echo "  Homebrew rathole install failed, trying direct download..." >&2
    fi

    # Fallback: direct download. Only x86_64-apple-darwin is published for macOS,
    # so on Apple Silicon this relies on Rosetta 2.
    local rathole_version="0.5.0"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            arch="x86_64-apple-darwin" ;;
        arm64|aarch64)
            echo "  WARNING: no prebuilt arm64 rathole release; using x86_64 build (requires Rosetta 2)" >&2
            arch="x86_64-apple-darwin" ;;
        *)
            echo "  ERROR: Unsupported architecture: $arch" >&2; return 1 ;;
    esac

    local download_url="https://github.com/rapiz1/rathole/releases/download/v${rathole_version}/rathole-${arch}.zip"
    local zip_path="/tmp/rathole-${rathole_version}.zip"

    echo "  Downloading rathole v${rathole_version} (${arch})..."
    curl -fSL -o "$zip_path" "$download_url"

    echo "  Extracting..."
    unzip -o "$zip_path" -d "$RATHOLE_DIR"
    chmod +x "$RATHOLE_BIN"

    rm -f "$zip_path"

    if [[ -x "$RATHOLE_BIN" ]]; then
        echo "  Rathole installed"
    else
        echo "  ERROR: Rathole installation failed -- binary not found after extraction" >&2
        return 1
    fi
}

# Check whether a previously-registered backend resource still exists, so a
# resource deleted outside the app (e.g. in the console) can be safely
# re-created. Echo one of: present | missing | unknown.
#   present  -> still exists; keep the local id
#   missing  -> backend definitively reports it gone; safe to re-register
#   unknown  -> could not verify (offline / 5xx / bad key); KEEP the id so a
#               transient failure never wipes a good registration
#
# Desktop: GET /desktop lists this key's desktops; 200 + id absent = missing.
desktop_exists() {
    local unify_key=$1
    local orchestra_url=$2
    local device_id=$3

    command -v python3 >/dev/null 2>&1 || { echo "unknown"; return; }

    local resp_file="/tmp/unify_desktop_list.json"
    local http_code
    http_code=$(curl -sS --connect-timeout 5 --max-time 15 -o "$resp_file" -w "%{http_code}" \
        -H "Authorization: Bearer ${unify_key}" \
        "${orchestra_url%/}/desktop" 2>/dev/null || true)

    if [[ "$http_code" != "200" ]]; then
        rm -f "$resp_file"
        echo "unknown"
        return
    fi

    local result
    result=$(DEVICE_ID="$device_id" python3 - "$resp_file" <<'PY' 2>/dev/null || true
import json, os, sys
device_id = str(os.environ.get("DEVICE_ID", ""))
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    items = data.get("info", []) if isinstance(data, dict) else []
    print("present" if any(str(d.get("id")) == device_id for d in items) else "missing")
except Exception:
    print("unknown")
PY
)
    rm -f "$resp_file"
    case "$result" in
        present|missing) echo "$result" ;;
        *) echo "unknown" ;;
    esac
}

# Tunnel: GET /infra/tunnel/{id}; 200 = present, 404 = missing, else unknown.
tunnel_exists() {
    local unify_key=$1
    local comms_url=$2
    local tunnel_id=$3

    local http_code
    http_code=$(curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${unify_key}" \
        "${comms_url%/}/infra/tunnel/${tunnel_id}" 2>/dev/null || true)

    case "$http_code" in
        200) echo "present" ;;
        404) echo "missing" ;;
        *)   echo "unknown" ;;
    esac
}

install_rclone() {
    echo ""
    echo "=== Installing rclone ==="
    if [[ -x "$RCLONE_BIN" ]]; then
        echo "  rclone already installed"
        return
    fi
    mkdir -p "$RCLONE_DIR"

    # Prefer Homebrew when available; fall back to the official static build.
    if ! $SKIP_BREW && command -v brew &>/dev/null; then
        if brew list rclone &>/dev/null || brew install rclone; then
            ln -sf "$(brew --prefix 2>/dev/null)/bin/rclone" "$RCLONE_BIN" 2>/dev/null || true
            if [[ -x "$RCLONE_BIN" ]]; then
                echo "  rclone installed (Homebrew)"
                return
            fi
        fi
    fi

    local arch rc_arch
    arch=$(uname -m)
    rc_arch="osx-amd64"
    [[ "$arch" == "arm64" || "$arch" == "aarch64" ]] && rc_arch="osx-arm64"

    local url="https://downloads.rclone.org/rclone-current-${rc_arch}.zip"
    local zip="/tmp/rclone-${rc_arch}.zip"
    local extract="/tmp/rclone-extract-$$"

    echo "  Downloading rclone (${rc_arch})..."
    curl -fSL -o "$zip" "$url"

    rm -rf "$extract" && mkdir -p "$extract"
    unzip -oq "$zip" -d "$extract"
    local found
    found=$(find "$extract" -name rclone -type f | head -1)
    if [[ -z "$found" ]]; then
        echo "  ERROR: rclone binary not found after extraction" >&2
        rm -f "$zip"; rm -rf "$extract"; return 1
    fi
    cp "$found" "$RCLONE_BIN"
    chmod +x "$RCLONE_BIN"
    rm -f "$zip"; rm -rf "$extract"

    if [[ -x "$RCLONE_BIN" ]]; then
        echo "  rclone installed"
    else
        echo "  ERROR: rclone installation failed" >&2
        return 1
    fi
}

# Generate the local SFTP host key (server identity, stays local) and ensure the
# authorized_keys file exists, then pull the per-link client public keys from
# Orchestra. The client PRIVATE keys live in Orchestra, never on this machine.
setup_sftp_server() {
    echo ""
    echo "=== Configuring SFTP server (rclone) ==="
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    if [[ ! -f "$SSH_HOST_KEY" ]]; then
        ssh-keygen -t ed25519 -f "$SSH_HOST_KEY" -N "" -q -C "unify-desktop-sftp-host"
        echo "  Generated SFTP host key"
    fi

    if [[ ! -f "$SSH_AUTH_KEYS" ]]; then
        touch "$SSH_AUTH_KEYS"
        chmod 600 "$SSH_AUTH_KEYS"
    fi

    reconcile_sftp_links || echo "  WARNING: could not reconcile SFTP links yet (will retry on the sync timer)"
}

# Reconcile per-link SFTP state with Orchestra:
#   1. find this device's assistant links (GET /desktop -> assigned_to_assistant_ids)
#   2. report this device's SFTP tunnel id (POST /desktop/{device_id}/sftp-tunnel)
#   3. fetch each filesys-sync link's client public key (GET /desktop/link/{aid}/pubkey)
#   4. report this device's SFTP tunnel coords (POST /desktop/link/{aid}/sftp-tunnel)
#   5. atomically rewrite authorized_keys from the collected keys (prunes revoked)
# Client PRIVATE keys live in Orchestra; only public keys ever touch this machine.
reconcile_sftp_links() {
    local unify_key orchestra_url device_id sftp_host sftp_port sftp_id
    unify_key=$(get_env_value "UNIFY_KEY")
    orchestra_url=$(get_env_value "ORCHESTRA_URL")
    device_id=$(get_env_value "DEVICE_ID")
    sftp_host=$(get_env_value "SFTP_TUNNEL_HOST")
    sftp_port=$(get_env_value "SFTP_TUNNEL_PORT")
    sftp_id=$(get_env_value "SFTP_TUNNEL_ID")
    [[ -z "$unify_key" || -z "$orchestra_url" || -z "$device_id" ]] && return 0

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Pre-clear the change marker; the reconcile below recreates it only when it
    # actually rewrites authorized_keys, so we can kickstart the SFTP agent on a
    # real key change (rclone only loads keys at startup) without bouncing it on
    # every unchanged sync tick.
    local changed_flag="$SSH_DIR/.authorized_keys_changed"
    rm -f "$changed_flag" 2>/dev/null || true

    UNIFY_KEY="$unify_key" ORCHESTRA_URL="$orchestra_url" DEVICE_ID="$device_id" \
    SFTP_TUNNEL_HOST="$sftp_host" SFTP_TUNNEL_PORT="$sftp_port" SFTP_TUNNEL_ID="$sftp_id" \
    SSH_AUTH_KEYS="$SSH_AUTH_KEYS" CHANGED_FLAG="$changed_flag" python3 - <<'PY'
import json, os, sys, tempfile, urllib.error, urllib.request

base = os.environ["ORCHESTRA_URL"].rstrip("/")
key = os.environ["UNIFY_KEY"]
device_id = str(os.environ["DEVICE_ID"])
host = os.environ.get("SFTP_TUNNEL_HOST") or ""
port = os.environ.get("SFTP_TUNNEL_PORT") or ""
tunnel_id = os.environ.get("SFTP_TUNNEL_ID") or ""
auth_keys = os.environ["SSH_AUTH_KEYS"]


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(base + path, data=data, method=method)
    r.add_header("Authorization", "Bearer " + key)
    if data is not None:
        r.add_header("Content-Type", "application/json")
    return urllib.request.urlopen(r, timeout=30)


try:
    with req("GET", "/desktop") as resp:
        desktops = json.load(resp).get("info", [])
except Exception as e:  # noqa: BLE001
    print(f"  WARNING: could not list desktops: {e}", file=sys.stderr)
    sys.exit(1)

assistant_ids = []
device_found = False
for d in desktops:
    if str(d.get("id")) == device_id:
        device_found = True
        assistant_ids = d.get("assigned_to_assistant_ids") or []
        break

# Report this device's SFTP tunnel id once (per-device, used by Console to tear
# the tunnel down on desktop delete). Skips self-host (no tunnel id is set).
if device_found and tunnel_id and host and port:
    try:
        req(
            "POST",
            f"/desktop/{device_id}/sftp-tunnel",
            {"tunnel_id": tunnel_id, "host": host, "port": int(port)},
        ).close()
    except Exception as e:  # noqa: BLE001
        print(f"  WARNING: desktop tunnel report failed: {e}", file=sys.stderr)

pubkeys = []
for aid in assistant_ids:
    try:
        with req("GET", f"/desktop/link/{aid}/pubkey") as resp:
            pk = (json.load(resp).get("info") or {}).get("public_key")
    except urllib.error.HTTPError as e:
        if e.code != 404:  # 404 == link without filesys_sync; skip quietly
            print(f"  WARNING: pubkey fetch failed for {aid}: {e}", file=sys.stderr)
        continue
    except Exception as e:  # noqa: BLE001
        print(f"  WARNING: pubkey fetch error for {aid}: {e}", file=sys.stderr)
        continue
    if pk and pk.strip():
        pubkeys.append(pk.strip())
        if host and port:
            try:
                req(
                    "POST",
                    f"/desktop/link/{aid}/sftp-tunnel",
                    {"host": host, "port": int(port)},
                ).close()
            except Exception as e:  # noqa: BLE001
                print(f"  WARNING: tunnel report failed for {aid}: {e}", file=sys.stderr)

body = "".join(k + "\n" for k in pubkeys)
try:
    with open(auth_keys, encoding="utf-8") as fh:
        old_body = fh.read()
except FileNotFoundError:
    old_body = None
if old_body != body:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(auth_keys) or ".")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.chmod(tmp, 0o600)
    os.replace(tmp, auth_keys)
    flag = os.environ.get("CHANGED_FLAG")
    if flag:
        try:
            open(flag, "w").close()
        except OSError:
            pass
    # Only log on change — at a 1-minute cadence an unconditional line floods the log.
    print(f"  authorized_keys synced ({len(pubkeys)} key(s) across {len(assistant_ids)} link(s))")
PY
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$changed_flag" 2>/dev/null || true
        return "$rc"
    fi

    # rclone loads --authorized-keys only at startup, so a key change needs a
    # restart to take effect. Only act in a user session (the sync timer and
    # --reconfigure run as the user; a root install has no GUI domain and the
    # agent loads at next login) and only when the key set actually changed, so
    # live SFTP sessions aren't dropped on an unchanged tick.
    if [[ "$EUID" -ne 0 && -f "$changed_flag" ]]; then
        launchctl kickstart -k "gui/$(id -u)/com.unify.sftp" 2>/dev/null || true
    fi
    rm -f "$changed_flag" 2>/dev/null || true
}

# Cloud mode: register a raw-TCP rathole tunnel for the SFTP port and write its
# client config. Self-host mode: bind on all interfaces so the local Unity stack
# reaches the SFTP server directly (no tunnel).
# A stable, per-machine SFTP tunnel name so we can identify (and prune) the
# tunnels this device created without touching another device's tunnels. The
# hostname is always available (unlike DEVICE_ID, which isn't set yet the first
# time we register an SFTP tunnel) and stable across upgrades.
sftp_tunnel_name() {
    local hn
    hn=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    hn=$(printf '%s' "$hn" | tr -cd 'A-Za-z0-9._-')
    [[ -z "$hn" ]] && hn="unknown"
    printf 'sftp-%s' "$hn"
}

# Best-effort: delete SFTP tunnels on the server that belong to THIS device
# (matched by our device-scoped name) but aren't the one we're currently using.
# Bounded by the exact name match so it never removes another device's tunnels.
prune_stale_sftp_tunnels() {
    local unify_key=$1
    local comms_url=$2
    local name=$3
    local keep_id=$4

    local list
    list=$(curl -sS --connect-timeout 5 --max-time 15 \
        -H "Authorization: Bearer ${unify_key}" \
        "${comms_url%/}/infra/tunnels" 2>/dev/null || true)
    [[ -z "$list" ]] && return 0

    local stale
    stale=$(UNIFY_NAME="$name" KEEP_ID="$keep_id" python3 -c '
import json, os, sys
name = os.environ["UNIFY_NAME"]
keep = os.environ["KEEP_ID"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tunnels = data.get("tunnels", data) if isinstance(data, dict) else data
if not isinstance(tunnels, list):
    sys.exit(0)
for t in tunnels:
    if not isinstance(t, dict):
        continue
    tid = t.get("tunnel_id") or t.get("id")
    if t.get("name") == name and tid and tid != keep:
        print(tid)
' <<<"$list" 2>/dev/null || true)

    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        curl -sS --max-time 15 -o /dev/null -X DELETE \
            -H "Authorization: Bearer ${unify_key}" \
            "${comms_url%/}/infra/tunnel/${id}" 2>/dev/null || true
        echo "  Pruned stale SFTP tunnel $id"
    done <<<"$stale"
}

# Periodic, no-restart cleanup driven by the sftp-sync launchd job: prune this
# device's leftover SFTP tunnels without waiting for a service restart. Only acts
# when it can confirm our active tunnel is live, so it never deletes the wrong one.
auto_prune_sftp_tunnels() {
    [[ "$(get_env_value "SELF_HOST")" == "1" ]] && return 0

    local unify_key comms_url active_id
    unify_key=$(get_env_value "UNIFY_KEY")
    comms_url=$(get_env_value "UNITY_COMMS_URL")
    active_id=$(get_env_value "SFTP_TUNNEL_ID")
    [[ -z "$unify_key" || -z "$comms_url" || -z "$active_id" ]] && return 0

    # Only prune once we know which tunnel to keep; if it's missing/unreachable,
    # leave well alone and let the next boot re-register + self-heal.
    [[ "$(tunnel_exists "$unify_key" "$comms_url" "$active_id")" != "present" ]] && return 0

    prune_stale_sftp_tunnels "$unify_key" "$comms_url" "$(sftp_tunnel_name)" "$active_id"
}

register_sftp_tunnel() {
    local unify_key=$1
    local comms_url=$2

    if $SELF_HOST_MODE || [[ "$(get_env_value "SELF_HOST")" == "1" ]]; then
        set_env_value "SFTP_BIND_ADDR" "0.0.0.0"
        set_env_value "SFTP_TUNNEL_HOST" "host.docker.internal"
        set_env_value "SFTP_TUNNEL_PORT" "$SFTP_LOCAL_PORT"
        echo ""
        echo "=== SFTP (self-host) ==="
        echo "  Reachable at host.docker.internal:${SFTP_LOCAL_PORT}"
        return 0
    fi

    set_env_value "SFTP_BIND_ADDR" "127.0.0.1"

    local sftp_name active_id=""
    sftp_name=$(sftp_tunnel_name)

    local existing_sftp_id
    existing_sftp_id=$(get_env_value "SFTP_TUNNEL_ID")
    if [[ -n "$existing_sftp_id" ]]; then
        local status
        status=$(tunnel_exists "$unify_key" "$comms_url" "$existing_sftp_id")
        if [[ "$status" == "missing" ]]; then
            echo "  SFTP tunnel $existing_sftp_id no longer exists on server — re-registering"
            set_env_value "SFTP_TUNNEL_ID" ""
            set_env_value "SFTP_TUNNEL_HOST" ""
            set_env_value "SFTP_TUNNEL_PORT" ""
            rm -f "$SFTP_RATHOLE_CONFIG"
            # fall through to fresh registration below
        else
            echo ""
            echo "  SFTP tunnel already registered: $(get_env_value "SFTP_TUNNEL_HOST"):$(get_env_value "SFTP_TUNNEL_PORT")"
            [[ "$status" == "unknown" ]] && echo "  (could not verify with server; keeping existing registration)"
            active_id="$existing_sftp_id"
        fi
    fi

    if [[ -z "$active_id" ]]; then
        echo ""
        echo "=== Registering SFTP Tunnel ==="

        local resp_file="/tmp/unify_sftp_tunnel.json"
        local http_code
        http_code=$(curl -sS -o "$resp_file" -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${unify_key}" \
            -H "Content-Type: application/json" \
            -d "{\"local_port\": ${SFTP_LOCAL_PORT}, \"protocol\": \"tcp\", \"name\": \"${sftp_name}\"}" \
            "${comms_url}/infra/tunnel/register" || true)

        if [[ "$http_code" != "200" ]]; then
            echo "  ERROR: SFTP tunnel registration failed (HTTP ${http_code})" >&2
            [[ -f "$resp_file" ]] && cat "$resp_file" >&2
            rm -f "$resp_file"
            return 1
        fi

        local tunnel_id tcp_host tcp_port client_config
        tunnel_id=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('tunnel_id',''))" < "$resp_file" 2>/dev/null || true)
        tcp_host=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('tcp_host',''))" < "$resp_file" 2>/dev/null || true)
        tcp_port=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('tcp_port',''))" < "$resp_file" 2>/dev/null || true)
        client_config=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('client_config',''))" < "$resp_file" 2>/dev/null || true)
        rm -f "$resp_file"

        set_env_value "SFTP_TUNNEL_ID" "$tunnel_id"
        set_env_value "SFTP_TUNNEL_HOST" "$tcp_host"
        set_env_value "SFTP_TUNNEL_PORT" "$tcp_port"

        mkdir -p "$RATHOLE_DIR"
        if [[ -n "${client_config:-}" ]]; then
            printf '%s\n' "$client_config" > "$SFTP_RATHOLE_CONFIG"
        fi

        launchctl kickstart -k "gui/$(id -u)/com.unify.sftp-tunnel" 2>/dev/null || true

        active_id="$tunnel_id"
        echo "  SFTP tunnel registered: ${tcp_host}:${tcp_port}"
    fi

    # Clean up any older SFTP tunnels this device left behind (best-effort).
    [[ -n "$active_id" ]] && prune_stale_sftp_tunnels "$unify_key" "$comms_url" "$sftp_name" "$active_id"
}

unregister_sftp_tunnel() {
    local unify_key=$1
    local comms_url=$2

    local tunnel_id
    tunnel_id=$(get_env_value "SFTP_TUNNEL_ID")
    [[ -z "$tunnel_id" ]] && return

    echo "  Deleting SFTP tunnel $tunnel_id..."

    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -X DELETE \
        -H "Authorization: Bearer ${unify_key}" \
        "${comms_url}/infra/tunnel/${tunnel_id}" || true)

    if [[ "$http_code" == "200" ]]; then
        echo "  SFTP tunnel deleted from server"
    else
        echo "  WARNING: Could not delete SFTP tunnel from server (HTTP ${http_code})"
    fi

    set_env_value "SFTP_TUNNEL_ID" ""
    set_env_value "SFTP_TUNNEL_HOST" ""
    set_env_value "SFTP_TUNNEL_PORT" ""

    rm -f "$SFTP_RATHOLE_CONFIG"
}

register_tunnel() {
    local unify_key=$1
    local comms_url=$2
    local local_port=${3:-3000}
    local tunnel_name=${4:-}

    echo ""
    echo "=== Registering Tunnel ==="

    local existing_id
    existing_id=$(get_env_value "TUNNEL_ID")
    if [[ -n "$existing_id" ]]; then
        local status
        status=$(tunnel_exists "$unify_key" "$comms_url" "$existing_id")
        if [[ "$status" == "missing" ]]; then
            echo "  Tunnel $existing_id no longer exists on server — re-registering"
            set_env_value "TUNNEL_ID" ""
            set_env_value "TUNNEL_URL" ""
            set_env_value "TUNNEL_TOKEN" ""
            rm -f "$RATHOLE_CONFIG"
            # fall through to fresh registration below
        else
            echo "  Tunnel already registered: $existing_id"
            [[ "$status" == "unknown" ]] && echo "  (could not verify with server; keeping existing registration)"
            local existing_url
            existing_url=$(get_env_value "TUNNEL_URL")
            [[ -n "$existing_url" ]] && echo "  URL: $existing_url"
            return
        fi
    fi

    local body="{\"local_port\": ${local_port}}"
    if [[ -n "$tunnel_name" ]]; then
        body="{\"local_port\": ${local_port}, \"name\": \"${tunnel_name}\"}"
    fi

    local resp_file="/tmp/unify_tunnel_register.json"
    local http_code
    http_code=$(curl -sS -o "$resp_file" -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${unify_key}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${comms_url}/infra/tunnel/register" || true)

    if [[ "$http_code" != "200" ]]; then
        echo "  ERROR: Tunnel registration failed (HTTP ${http_code})" >&2
        [[ -f "$resp_file" ]] && cat "$resp_file" >&2
        rm -f "$resp_file"
        return 1
    fi

    local tunnel_id tunnel_url client_config client_token
    tunnel_id=$(grep -oE '"tunnel_id"\s*:\s*"[^"]+"' "$resp_file" | sed 's/.*"tunnel_id"\s*:\s*"//;s/"$//' || true)
    tunnel_url=$(grep -oE '"url"\s*:\s*"[^"]+"' "$resp_file" | sed 's/.*"url"\s*:\s*"//;s/"$//' || true)
    client_token=$(grep -oE '"client_token"\s*:\s*"[^"]+"' "$resp_file" | sed 's/.*"client_token"\s*:\s*"//;s/"$//' || true)

    if command -v python3 &>/dev/null; then
        client_config=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('client_config',''))" < "$resp_file" 2>/dev/null || true)
    elif command -v jq &>/dev/null; then
        client_config=$(jq -r '.client_config // ""' "$resp_file" 2>/dev/null || true)
    fi

    rm -f "$resp_file"

    set_env_value "TUNNEL_ID" "$tunnel_id"
    set_env_value "TUNNEL_URL" "$tunnel_url"
    set_env_value "TUNNEL_TOKEN" "$client_token"

    mkdir -p "$RATHOLE_DIR"
    if [[ -n "${client_config:-}" ]]; then
        printf '%s\n' "$client_config" > "$RATHOLE_CONFIG"
    fi

    # Kick the launchd tunnel agent so the fresh token/config is picked up now.
    # The agent is bootstrapped by setup_autostart (which runs before this in the
    # install flow); harmless no-op if it isn't loaded yet.
    launchctl kickstart -k "gui/$(id -u)/com.unify.tunnel" 2>/dev/null || true

    echo "  Tunnel registered: $tunnel_id"
    echo "  Public URL: $tunnel_url"
}

start_tunnel() {
    echo ""
    echo "=== Starting Tunnel ==="

    # rathole is run by the com.unify.tunnel launchd agent (KeepAlive PathState:
    # alive whenever client.toml exists). We just ensure the agent is loaded and
    # kick it so a freshly-written config/token is picked up immediately. This is
    # idempotent: `bootstrap` is a no-op if already loaded, and re-loads the agent
    # after an explicit --stop (which boots it out).
    local domain="gui/$(id -u)"
    local tunnel_plist="$HOME/Library/LaunchAgents/com.unify.tunnel.plist"

    if [[ ! -f "$tunnel_plist" ]]; then
        echo "  Tunnel agent not installed, skipping (run setup to install it)"
        return
    fi

    launchctl bootstrap "$domain" "$tunnel_plist" 2>/dev/null || true
    launchctl kickstart -k "$domain/com.unify.tunnel" 2>/dev/null || true

    sleep 2

    if pgrep -f "rathole.*client\.toml" &>/dev/null; then
        local tunnel_url
        tunnel_url=$(get_env_value "TUNNEL_URL")
        echo "  Tunnel running"
        [[ -n "$tunnel_url" ]] && echo "  Public URL: $tunnel_url"
    elif [[ ! -f "$RATHOLE_CONFIG" ]]; then
        echo "  No tunnel config yet — agent will start rathole once registered"
    else
        echo "  WARNING: Tunnel may not be running. Check log: $LOG_DIR/rathole.log"
        if [[ -f "$LOG_DIR/rathole.log" ]]; then
            tail -5 "$LOG_DIR/rathole.log" 2>/dev/null | sed 's/^/    /'
        fi
    fi
}

stop_tunnel() {
    # Boot out the launchd agent so an explicit --stop stays down for the session
    # (launchd would otherwise respawn rathole while client.toml exists). The
    # agent reloads at next login from the LaunchAgents plist.
    launchctl bootout "gui/$(id -u)/com.unify.tunnel" 2>/dev/null || true
    echo "  Stopped rathole tunnel"
}

unregister_tunnel() {
    local unify_key=$1
    local comms_url=$2

    local tunnel_id
    tunnel_id=$(get_env_value "TUNNEL_ID")
    [[ -z "$tunnel_id" ]] && return

    echo "  Deleting tunnel $tunnel_id..."

    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -X DELETE \
        -H "Authorization: Bearer ${unify_key}" \
        "${comms_url}/infra/tunnel/${tunnel_id}" || true)

    if [[ "$http_code" == "200" ]]; then
        echo "  Tunnel deleted from server"
    else
        echo "  WARNING: Could not delete tunnel from server (HTTP ${http_code})"
    fi

    set_env_value "TUNNEL_ID" ""
    set_env_value "TUNNEL_URL" ""
    set_env_value "TUNNEL_TOKEN" ""

    rm -f "$RATHOLE_CONFIG"
}

register_desktop() {
    local unify_key=$1
    local orchestra_url=$2
    local device_name=$3
    local tunnel_url=$4

    echo ""
    echo "=== Registering Desktop ==="

    local existing_id
    existing_id=$(get_env_value "DEVICE_ID")
    if [[ -n "$existing_id" ]]; then
        local status
        status=$(desktop_exists "$unify_key" "$orchestra_url" "$existing_id")
        if [[ "$status" == "missing" ]]; then
            echo "  Desktop $existing_id no longer exists on server — re-registering"
            set_env_value "DEVICE_ID" ""
            # fall through to fresh registration below
        else
            echo "  Desktop already registered: ID=$existing_id"
            [[ "$status" == "unknown" ]] && echo "  (could not verify with server; keeping existing registration)"
            if [[ -n "$tunnel_url" ]]; then
                echo "  Updating URL to: $tunnel_url"
                local http_code
                http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
                    -X PATCH \
                    -H "Authorization: Bearer ${unify_key}" \
                    -H "Content-Type: application/json" \
                    -d "{\"url\": \"${tunnel_url}\"}" \
                    "${orchestra_url}/desktop/${existing_id}" || true)
                if [[ "$http_code" == "200" ]]; then
                    echo "  URL updated"
                else
                    if explain_orchestra_connect_failure "update the desktop URL" "$orchestra_url" "$http_code"; then
                        echo "  WARNING: Could not update desktop URL (Orchestra unreachable)" >&2
                    else
                        echo "  WARNING: Could not update desktop URL (HTTP ${http_code})" >&2
                    fi
                fi
            fi
            return
        fi
    fi

    if [[ -z "$tunnel_url" ]]; then
        echo "  ERROR: No tunnel URL available for desktop registration" >&2
        return 1
    fi

    [[ -z "$device_name" ]] && device_name=$(scutil --get ComputerName 2>/dev/null || hostname -s)

    local body
    body=$(printf '{"name": "%s", "url": "%s", "os": "macos"}' "$device_name" "$tunnel_url")

    local resp_file="/tmp/unify_desktop_register.json"
    local http_code
    http_code=$(curl -sS -o "$resp_file" -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${unify_key}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${orchestra_url}/desktop" || true)

    if [[ "$http_code" != "200" ]]; then
        if explain_orchestra_connect_failure "register this Mac" "$orchestra_url" "$http_code"; then
            rm -f "$resp_file"
            return 1
        fi
        echo "  ERROR: Desktop registration failed (HTTP ${http_code})" >&2
        [[ -f "$resp_file" ]] && cat "$resp_file" >&2
        rm -f "$resp_file"
        return 1
    fi

    local device_id
    device_id=$(grep -oE '"id"\s*:\s*[^,}\s]+' "$resp_file" | head -1 | sed 's/.*:\s*//;s/"//g' || true)
    rm -f "$resp_file"

    set_env_value "DEVICE_ID" "$device_id"

    echo "  Desktop registered: ID=$device_id"
    echo "  Name: $device_name"
    echo "  URL: $tunnel_url"
}

agent_service_port() {
    local env_file="$AGENT_SERVICE_DIR/.env"
    if [[ -f "$env_file" ]]; then
        local port
        port="$(grep -E '^PORT=' "$env_file" 2>/dev/null | sed 's/^PORT=//' || true)"
        if [[ -n "$port" ]]; then
            echo "$port"
            return 0
        fi
    fi
    if $SELF_HOST_MODE || [[ "$(get_env_value "SELF_HOST")" == "1" ]]; then
        echo "$SELF_HOST_AGENT_PORT"
    else
        echo "3000"
    fi
}

self_host_registration_url() {
    echo "http://host.docker.internal:$(agent_service_port)"
}

resolve_coordinator_agent_id() {
    local unify_key=$1
    local orchestra_url=$2

    if [[ -n "$COORDINATOR_AGENT_ID" ]]; then
        echo "$COORDINATOR_AGENT_ID"
        return 0
    fi

    local runtime_file="$HOME/.unity/coordinator-runtime.json"
    if [[ -f "$runtime_file" ]]; then
        local from_file
        from_file="$(python3 - "$runtime_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(
    data.get("coordinatorAgentId")
    or data.get("coordinator_agent_id")
    or ""
)
PY
)"
        if [[ -n "$from_file" ]]; then
            echo "$from_file"
            return 0
        fi
    fi

    local resp_file="/tmp/unify_coordinator_lookup.json"
    local http_code
    http_code=$(curl -sS -o "$resp_file" -w "%{http_code}" \
        -H "Authorization: Bearer ${unify_key}" \
        "${orchestra_url%/}/assistant" || true)
    if [[ "$http_code" != "200" ]]; then
        rm -f "$resp_file"
        return 1
    fi
    python3 - "$resp_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    raw = json.load(fh)
items = raw.get("info") if isinstance(raw, dict) else raw
if not isinstance(items, list):
    raise SystemExit(1)
for item in items:
    if item.get("is_coordinator"):
        print(item.get("agent_id") or item.get("agentId") or "")
        raise SystemExit(0)
raise SystemExit(1)
PY
    rm -f "$resp_file"
}

link_desktop_to_coordinator() {
    local unify_key=$1
    local orchestra_url=$2
    local desktop_id=$3
    local coordinator_id=$4

    echo ""
    echo "=== Linking Desktop to Coordinator ==="

    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${unify_key}" \
        -H "Content-Type: application/json" \
        -d "$(python3 - "$coordinator_id" "$desktop_id" <<'PY'
import json
import sys

assistant_id, desktop_id = sys.argv[1], sys.argv[2]
print(
    json.dumps(
        {
            "assistant_id": int(assistant_id),
            "desktop_id": int(desktop_id),
            "filesys_sync": False,
        },
    ),
)
PY
)" \
        "${orchestra_url%/}/desktop/link" || true)

    if [[ "$http_code" != "200" ]]; then
        if explain_orchestra_connect_failure "link this Mac to the Coordinator" "$orchestra_url" "$http_code"; then
            return 1
        fi
        echo "  ERROR: Desktop link failed (HTTP ${http_code})" >&2
        return 1
    fi
    echo "  Linked desktop ${desktop_id} to Coordinator assistant ${coordinator_id}"
}

register_self_host_desktop() {
    local unify_key=$1
    local orchestra_url=$2
    local device_name=$3
    local reg_url
    reg_url="$(self_host_registration_url)"

    echo ""
    echo "=== Self-Host Desktop Registration ==="
    echo "  Orchestra: ${orchestra_url}"
    echo "  Agent URL for Unity CM: ${reg_url}"

    register_desktop "$unify_key" "$orchestra_url" "$device_name" "$reg_url" || return 1

    if $LINK_COORDINATOR; then
        local desktop_id coordinator_id
        desktop_id="$(get_env_value "DEVICE_ID")"
        coordinator_id="$(resolve_coordinator_agent_id "$unify_key" "$orchestra_url" || true)"
        if [[ -z "$desktop_id" || -z "$coordinator_id" ]]; then
            echo "  WARNING: Could not link desktop — missing device or coordinator id" >&2
            return 0
        fi
        link_desktop_to_coordinator "$unify_key" "$orchestra_url" "$desktop_id" "$coordinator_id" || true
        echo ""
        echo "  Restart the Unity stack so CM reloads linked desktops:"
        echo "    unity restart"
    fi
}

# Best-effort recovery run on --start (login/boot): if the tunnel or desktop was
# deleted on the backend while local ids persisted, re-register it. Safe by
# construction — register_tunnel/register_desktop only re-create on a definitive
# server "missing", never on a transient/auth failure. Gated on a configured key
# and guarded by a lock dir so it can't race a concurrent --reconfigure.
ensure_registration() {
    local unify_key orchestra_url comms_url tunnel_url lock_dir

    unify_key=$(get_env_value "UNIFY_KEY")
    orchestra_url=$(get_env_value "ORCHESTRA_URL")
    comms_url=$(get_env_value "UNITY_COMMS_URL")
    [[ -z "$unify_key" || -z "$orchestra_url" ]] && return 0

    lock_dir="$AGENT_SERVICE_DIR/.recover.lock"
    mkdir -p "$AGENT_SERVICE_DIR" 2>/dev/null || true
    # Clear a stale lock (>10 min) left behind by a crashed run.
    if [[ -d "$lock_dir" && -n "$(find "$lock_dir" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    mkdir "$lock_dir" 2>/dev/null || return 0

    echo ""
    echo "=== Verifying registration ==="
    if [[ "$(get_env_value "SELF_HOST")" == "1" ]]; then
        register_desktop "$unify_key" "$orchestra_url" "$DEVICE_NAME" "$(self_host_registration_url)" || true
    elif [[ -n "$comms_url" ]]; then
        register_tunnel "$unify_key" "$comms_url" 3000 "$DEVICE_NAME" || true
        register_sftp_tunnel "$unify_key" "$comms_url" || true
        tunnel_url=$(get_env_value "TUNNEL_URL")
        if [[ -n "$tunnel_url" ]]; then
            register_desktop "$unify_key" "$orchestra_url" "$DEVICE_NAME" "$tunnel_url" || true
        fi
    fi

    rmdir "$lock_dir" 2>/dev/null || true
}

bootstrap_launch_agent() {
    local label=$1
    local plist=$2
    local domain="gui/$(id -u)"

    launchctl bootout "$domain/$label" 2>/dev/null || true
    if launchctl bootstrap "$domain" "$plist" 2>/dev/null; then
        launchctl kickstart -k "$domain/$label" 2>/dev/null || true
        return 0
    fi
    return 1
}

start_launchd_host_services() {
    local domain="gui/$(id -u)"
    local target_dir="$HOME/Library/LaunchAgents"
    local started=false

    for label in com.unify.websockify com.unify.agent; do
        local plist="$target_dir/${label}.plist"
        if [[ -f "$plist" ]]; then
            bootstrap_launch_agent "$label" "$plist" && started=true
        fi
    done
    $started
}

unregister_desktop() {
    local unify_key=$1
    local orchestra_url=$2

    local device_id
    device_id=$(get_env_value "DEVICE_ID")
    [[ -z "$device_id" ]] && return

    echo "  Deleting desktop $device_id..."

    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -X DELETE \
        -H "Authorization: Bearer ${unify_key}" \
        "${orchestra_url}/desktop/${device_id}" || true)

    if [[ "$http_code" == "200" ]]; then
        echo "  Desktop deleted from server"
    else
        echo "  WARNING: Could not delete desktop from server (HTTP ${http_code})"
    fi

    set_env_value "DEVICE_ID" ""
}

# =============================================================================
# Configuration Functions
# =============================================================================

setup_agent_service_env() {
    echo ""
    echo "=== Configuring Agent Service ==="

    local env_file="$AGENT_SERVICE_DIR/.env"
    local agent_port
    agent_port="$(agent_service_port)"

    local existing_tunnel_id existing_tunnel_url existing_tunnel_token existing_device_id
    existing_tunnel_id=$(get_env_value "TUNNEL_ID")
    existing_tunnel_url=$(get_env_value "TUNNEL_URL")
    existing_tunnel_token=$(get_env_value "TUNNEL_TOKEN")
    existing_device_id=$(get_env_value "DEVICE_ID")

    # Capture SFTP values BEFORE the heredoc — the `cat >` redirection truncates
    # the .env before the here-document is expanded, so inline reads would be empty.
    local existing_sftp_user existing_sftp_bind existing_sftp_tunnel_id existing_sftp_host existing_sftp_port
    # Fixed contract with the cloud-side rclone client; not the OS account.
    existing_sftp_user="unity"
    existing_sftp_bind=$(get_env_value "SFTP_BIND_ADDR")
    existing_sftp_tunnel_id=$(get_env_value "SFTP_TUNNEL_ID")
    existing_sftp_host=$(get_env_value "SFTP_TUNNEL_HOST")
    existing_sftp_port=$(get_env_value "SFTP_TUNNEL_PORT")

    cat > "$env_file" <<ENVFILE
# Agent Service Environment Configuration
# Generated: $(date)

PORT=$agent_port
UNIFY_KEY=$UNIFY_KEY
ORCHESTRA_URL=$ORCHESTRA_URL
UNITY_COMMS_URL=$UNITY_COMMS_URL
SELF_HOST=$($SELF_HOST_MODE && echo 1 || echo 0)
PLAYWRIGHT_BROWSERS_PATH=$INSTALL_DIR/browsers

# Tunnel & Device (managed by setup/registration)
TUNNEL_ID=$existing_tunnel_id
TUNNEL_URL=$existing_tunnel_url
TUNNEL_TOKEN=$existing_tunnel_token
DEVICE_ID=$existing_device_id

# SFTP / Remote FS (managed by setup_sftp_server / register_sftp_tunnel)
SFTP_LOCAL_PORT=$SFTP_LOCAL_PORT
SFTP_USER=$existing_sftp_user
SFTP_BIND_ADDR=$existing_sftp_bind
SFTP_TUNNEL_ID=$existing_sftp_tunnel_id
SFTP_TUNNEL_HOST=$existing_sftp_host
SFTP_TUNNEL_PORT=$existing_sftp_port
ENVFILE

    echo "  .env created"
    echo "    UNIFY_KEY: $(if [[ -n "$UNIFY_KEY" ]]; then echo '(set)'; else echo '(not set)'; fi)"
    echo "    ORCHESTRA_URL: $ORCHESTRA_URL"
    echo "    UNITY_COMMS_URL: $UNITY_COMMS_URL"
    if [[ -n "$existing_device_id" ]]; then
        echo "    DEVICE_ID: $existing_device_id (preserved)"
    fi
    if [[ -n "$existing_tunnel_id" ]]; then
        echo "    TUNNEL_ID: $existing_tunnel_id (preserved)"
    fi
}

setup_autostart() {
    echo ""
    echo "=== Setting up autostart (tray app) ==="

    local template="$INSTALL_DIR/launchd/com.unify.tray.plist"
    local target_dir="$HOME/Library/LaunchAgents"
    local tray_plist="$target_dir/com.unify.tray.plist"

    mkdir -p "$target_dir"

    if [[ ! -f "$template" ]]; then
        echo "  WARNING: tray plist template not found at $template" >&2
        return
    fi

    # Use the pinned interpreter (has rumps + websockify) so the tray app and the
    # websockify it later launches via --start share the exact same Python.
    local python_bin="$PYTHON_BIN"

    sed \
        -e "s|%PYTHON%|$python_bin|g" \
        -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
        -e "s|%LOG_DIR%|$LOG_DIR|g" \
        "$template" > "$tray_plist"
    echo "  Autostart plist created: $tray_plist"

    # Render the tunnel agent plist (rathole runs whenever client.toml exists;
    # launchd owns its lifecycle via PathState KeepAlive).
    local tunnel_template="$INSTALL_DIR/launchd/com.unify.tunnel.plist"
    local tunnel_plist="$target_dir/com.unify.tunnel.plist"
    if [[ -f "$tunnel_template" ]]; then
        sed \
            -e "s|%RATHOLE_BIN%|$RATHOLE_BIN|g" \
            -e "s|%RATHOLE_CONFIG%|$RATHOLE_CONFIG|g" \
            -e "s|%LOG_DIR%|$LOG_DIR|g" \
            "$tunnel_template" > "$tunnel_plist"
        echo "  Tunnel plist created: $tunnel_plist"
    else
        echo "  WARNING: tunnel plist template not found at $tunnel_template" >&2
    fi

    # Render the SFTP server agent (rclone serve sftp; KeepAlive on authorized_keys).
    local sftp_template="$INSTALL_DIR/launchd/com.unify.sftp.plist"
    local sftp_plist="$target_dir/com.unify.sftp.plist"
    if [[ -f "$sftp_template" ]]; then
        sed \
            -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
            -e "s|%SSH_AUTH_KEYS%|$SSH_AUTH_KEYS|g" \
            -e "s|%LOG_DIR%|$LOG_DIR|g" \
            "$sftp_template" > "$sftp_plist"
        chmod +x "$INSTALL_DIR/tools/run-sftp.sh" 2>/dev/null || true
        echo "  SFTP plist created: $sftp_plist"
    else
        echo "  WARNING: SFTP plist template not found at $sftp_template" >&2
    fi

    # Render the SFTP tunnel agent (cloud mode; KeepAlive on sftp-client.toml).
    local sftp_tunnel_template="$INSTALL_DIR/launchd/com.unify.sftp-tunnel.plist"
    local sftp_tunnel_plist="$target_dir/com.unify.sftp-tunnel.plist"
    if [[ -f "$sftp_tunnel_template" ]]; then
        sed \
            -e "s|%RATHOLE_BIN%|$RATHOLE_BIN|g" \
            -e "s|%SFTP_RATHOLE_CONFIG%|$SFTP_RATHOLE_CONFIG|g" \
            -e "s|%LOG_DIR%|$LOG_DIR|g" \
            "$sftp_tunnel_template" > "$sftp_tunnel_plist"
        echo "  SFTP tunnel plist created: $sftp_tunnel_plist"
    else
        echo "  WARNING: SFTP tunnel plist template not found at $sftp_tunnel_template" >&2
    fi

    # Render the SFTP key-sync agent (periodic reconcile of authorized_keys +
    # tunnel coords for links enabled later in the console).
    local sftp_sync_template="$INSTALL_DIR/launchd/com.unify.sftp-sync.plist"
    local sftp_sync_plist="$target_dir/com.unify.sftp-sync.plist"
    if [[ -f "$sftp_sync_template" ]]; then
        sed \
            -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
            -e "s|%LOG_DIR%|$LOG_DIR|g" \
            "$sftp_sync_template" > "$sftp_sync_plist"
        echo "  SFTP sync plist created: $sftp_sync_plist"
    else
        echo "  WARNING: SFTP sync plist template not found at $sftp_sync_template" >&2
    fi

    # (Re)load the tray + tunnel agents so they start now and at every login.
    if [[ "$EUID" -ne 0 ]]; then
        local domain="gui/$(id -u)"
        launchctl bootout "$domain/com.unify.tray" 2>/dev/null || true
        if launchctl bootstrap "$domain" "$tray_plist" 2>/dev/null; then
            echo "  Tray agent loaded (will start at login)"
        else
            echo "  Tray agent will load at next login"
        fi

        if [[ -f "$tunnel_plist" ]]; then
            launchctl bootout "$domain/com.unify.tunnel" 2>/dev/null || true
            if launchctl bootstrap "$domain" "$tunnel_plist" 2>/dev/null; then
                echo "  Tunnel agent loaded"
            else
                echo "  Tunnel agent will load at next login"
            fi
        fi

        for svc_label in com.unify.websockify com.unify.agent; do
            local svc_template="$INSTALL_DIR/launchd/${svc_label}.plist"
            local svc_plist="$target_dir/${svc_label}.plist"
            if [[ -f "$svc_template" ]]; then
                sed \
                    -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
                    -e "s|%LOG_DIR%|$LOG_DIR|g" \
                    "$svc_template" > "$svc_plist"
                chmod +x "$INSTALL_DIR/tools/run-websockify.sh" "$INSTALL_DIR/tools/run-agent-service.sh" 2>/dev/null || true
                bootstrap_launch_agent "$svc_label" "$svc_plist" && \
                    echo "  ${svc_label} agent loaded (will restart on crash and at login)" || \
                    echo "  ${svc_label} agent will load at next login"
            fi
        done

        for sftp_label in com.unify.sftp com.unify.sftp-tunnel com.unify.sftp-sync; do
            local sftp_agent_plist="$target_dir/${sftp_label}.plist"
            if [[ -f "$sftp_agent_plist" ]]; then
                bootstrap_launch_agent "$sftp_label" "$sftp_agent_plist" && \
                    echo "  ${sftp_label} agent loaded" || \
                    echo "  ${sftp_label} agent will load at next login"
            fi
        done
    else
        echo "  Skipping launchctl load (running as root) — agents load at next user login"
    fi
}

# =============================================================================
# Start Services
# =============================================================================

start_all_services() {
    echo ""
    echo "=== Starting Services ==="

    mkdir -p "$LOG_DIR"

    # Start Screen Sharing (Apple VNC on 5900)
    if ! test_port_listening 5900; then
        # Only enable Screen Sharing once the assistant is configured.
        local configured="$UNIFY_KEY"
        if [[ -z "$configured" && -f "$AGENT_SERVICE_DIR/.env" ]]; then
            configured=$(get_env_value "UNIFY_KEY")
        fi

        if [[ -z "$configured" ]]; then
            echo "  Skipping Screen Sharing — not configured (UNIFY_KEY not set)"
            echo "  Configure via: sudo setup.sh --unify-key YOUR_KEY" >&2
        elif [[ ! -f "$KICKSTART" ]]; then
            echo "  ERROR: kickstart not found — cannot manage Screen Sharing" >&2
        elif [[ "$EUID" -ne 0 ]]; then
            echo "  WARNING: Screen Sharing requires root to enable. Run with sudo or enable manually." >&2
            echo "  Skipping VNC — other services will still start." >&2
        else
            echo "  Enabling Screen Sharing..."
            # Enable password-only basic Screen Sharing (com.apple.screensharing),
            # NOT Remote Management (ARD) — ARD's legacy-VNC path authenticates
            # but stalls before ServerInit. See enable_basic_screen_sharing.
            enable_basic_screen_sharing "$configured" \
                > "$LOG_DIR/screensharing.log" 2>&1 || true
        fi
    else
        echo "  Screen Sharing already running on port 5900"
    fi

    # Prefer launchd for websockify + agent when plists are installed.
    if start_launchd_host_services; then
        echo "  Host service agents started via launchd"
    fi

    # Start websockify (only if not already running on 6080).
    if ! test_port_listening 6080; then
        if ! "$PYTHON_BIN" -c 'import websockify' 2>/dev/null; then
            echo "  websockify module missing for $PYTHON_BIN — installing..."
            "$PYTHON_BIN" -m pip install --break-system-packages websockify 2>/dev/null \
                || "$PYTHON_BIN" -m pip install websockify 2>/dev/null || true
            echo "$PYTHON_BIN" > "$PYTHON_BIN_FILE" 2>/dev/null || true
        fi
        echo "  Starting websockify ($PYTHON_BIN)..."
        nohup "$PYTHON_BIN" -m websockify --web="$NOVNC_DIR" 6080 localhost:5900 \
            > "$LOG_DIR/websockify.log" 2>&1 &
    else
        echo "  websockify already running on port 6080"
    fi

    # Start Agent Service (only if not already running on configured PORT).
    local agent_port
    agent_port="$(agent_service_port)"
    if ! test_port_listening "$agent_port"; then
        echo "  Starting Agent Service on port ${agent_port}..."
        (
            cd "$AGENT_SERVICE_DIR"
            export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/browsers"
            nohup npx -y ts-node src/index.ts > "$LOG_DIR/agent.log" 2>&1 &
        )
    else
        echo "  Agent Service already running on port ${agent_port}"
    fi

    # Poll for services to come up (up to 20 seconds)
    echo ""
    echo "  Waiting for services to start..."

    local max_wait=20
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        sleep 2
        waited=$((waited + 2))

        local vnc_up=false ws_up=false agent_up=false
        test_port_listening 5900 && vnc_up=true
        test_port_listening 6080 && ws_up=true
        test_port_listening "$agent_port" && agent_up=true

        if $vnc_up && $ws_up && $agent_up; then break; fi

        local status=""
        $vnc_up || status="${status}VNC "
        $ws_up || status="${status}websockify "
        $agent_up || status="${status}agent "
        echo "  Waiting (${waited}s): ${status}..."
    done

    # Final status report
    echo ""
    echo "Service Status:"

    local all_ok=true

    if test_port_listening 5900; then
        echo "  [OK] Screen Sharing (port 5900)"
    else
        echo "  [FAIL] Screen Sharing (port 5900)"
        all_ok=false
    fi

    if test_port_listening 6080; then
        echo "  [OK] websockify (port 6080)"
    else
        echo "  [FAIL] websockify (port 6080)"
        all_ok=false
        if [[ -f "$LOG_DIR/websockify.log" ]]; then
            echo "  Log ($LOG_DIR/websockify.log):"
            tail -5 "$LOG_DIR/websockify.log" 2>/dev/null | sed 's/^/    /'
        fi
    fi

    if test_port_listening "$agent_port"; then
        echo "  [OK] Agent Service (port ${agent_port})"
    else
        echo "  [FAIL] Agent Service (port ${agent_port})"
        all_ok=false
        if [[ -f "$LOG_DIR/agent.log" ]]; then
            echo "  Log ($LOG_DIR/agent.log):"
            tail -5 "$LOG_DIR/agent.log" 2>/dev/null | sed 's/^/    /'
        fi
    fi

    if ! $all_ok; then
        echo ""
        echo "  Some services failed to start. Check the log files above for details."
    fi

    # The tunnel forwards the agent port to the cloud; skip it in self-host mode.
    if ! $SELF_HOST_MODE && [[ "$(get_env_value "SELF_HOST")" != "1" ]]; then
        start_tunnel
    fi

    # SFTP server (rclone) runs in both modes; its tunnel only in cloud mode.
    # launchd owns lifecycles via PathState (authorized_keys / sftp-client.toml);
    # kick them so freshly-written config/keys are picked up immediately.
    local sftp_domain="gui/$(id -u)"
    if [[ -f "$HOME/Library/LaunchAgents/com.unify.sftp.plist" ]]; then
        launchctl bootstrap "$sftp_domain" "$HOME/Library/LaunchAgents/com.unify.sftp.plist" 2>/dev/null || true
        launchctl kickstart -k "$sftp_domain/com.unify.sftp" 2>/dev/null || true
    fi
    if ! $SELF_HOST_MODE && [[ "$(get_env_value "SELF_HOST")" != "1" ]]; then
        if [[ -f "$HOME/Library/LaunchAgents/com.unify.sftp-tunnel.plist" ]]; then
            launchctl bootstrap "$sftp_domain" "$HOME/Library/LaunchAgents/com.unify.sftp-tunnel.plist" 2>/dev/null || true
            launchctl kickstart -k "$sftp_domain/com.unify.sftp-tunnel" 2>/dev/null || true
        fi
    fi
    # Periodic key-sync agent (runs in both modes).
    if [[ -f "$HOME/Library/LaunchAgents/com.unify.sftp-sync.plist" ]]; then
        launchctl bootstrap "$sftp_domain" "$HOME/Library/LaunchAgents/com.unify.sftp-sync.plist" 2>/dev/null || true
        launchctl kickstart -k "$sftp_domain/com.unify.sftp-sync" 2>/dev/null || true
    fi
}

# =============================================================================
# Summary
# =============================================================================

show_summary() {
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))

    echo ""
    echo "=========================================="
    echo "  Setup Complete!"
    echo "=========================================="
    echo ""
    echo "Local URLs:"

    local agent_port
    agent_port="$(agent_service_port)"

    local vnc_url="http://localhost:6080/"
    if $SELF_HOST_MODE || [[ "$(get_env_value "SELF_HOST")" == "1" ]]; then
        vnc_url="${vnc_url}vnc.html"
        if [[ -n "$UNIFY_KEY" ]]; then
            vnc_url="${vnc_url}?password=${UNIFY_KEY:0:8}&autoconnect=1&resize=scale"
        else
            vnc_url="${vnc_url}?autoconnect=1&resize=scale"
        fi
    else
        vnc_url="${vnc_url}custom.html"
        if [[ -n "$UNIFY_KEY" ]]; then
            vnc_url="${vnc_url}?password=${UNIFY_KEY:0:8}"
        fi
    fi

    echo "  Desktop:       $vnc_url"
    echo "  Agent Service: http://localhost:${agent_port}"

    local tunnel_url tunnel_id device_id
    tunnel_url=$(get_env_value "TUNNEL_URL")
    tunnel_id=$(get_env_value "TUNNEL_ID")
    device_id=$(get_env_value "DEVICE_ID")

    if [[ -n "$tunnel_url" ]] && ! $SELF_HOST_MODE && [[ "$(get_env_value "SELF_HOST")" != "1" ]]; then
        echo ""
        echo "Public Access:"
        echo "  Tunnel URL:  $tunnel_url"
        echo "  Tunnel ID:   $tunnel_id"
    fi

    if [[ -n "$device_id" ]]; then
        echo ""
        echo "Device Registration:"
        echo "  Device ID:   $device_id"
    fi

    echo ""
    echo "Time elapsed: ${elapsed} seconds"
    echo ""
}

# =============================================================================
# Main Execution
# =============================================================================

# Handle enable-screen-sharing (root-only; used by the installer/tray to enable
# Apple Screen Sharing). Dispatched first, before the root-refusal checks, since
# this operation REQUIRES root.
if $ENABLE_SS; then
    do_enable_screen_sharing
    exit $?
fi

# Handle reconfigure (lightweight key update: re-apply key + re-register +
# restart services). Used by the tray when the API key changes. It deliberately
# skips dependency installs AND setup_autostart — touching the tray launchd agent
# from inside the tray's own job would bootout (kill) the running menu-bar app.
if $RECONFIGURE; then
    echo ""
    echo "Reconfigure mode"

    if [[ -z "$UNIFY_KEY" ]]; then
        echo "ERROR: --reconfigure requires --unify-key" >&2
        exit 1
    fi

    # Run as the regular user (registration writes the user-owned .env; matches --start).
    if [[ "$EUID" -eq 0 ]]; then
        echo "ERROR: Do not run --reconfigure as root." >&2
        exit 1
    fi

    # Settings changes the API key. For cloud installs, preserve URLs baked at
    # install so staging/custom Orchestra/Comms endpoints are not overwritten.
    apply_compose_self_host_mode
    if ! compose_self_host_present; then
        existing_orch="$(get_env_value "ORCHESTRA_URL")"
        existing_comms="$(get_env_value "UNITY_COMMS_URL")"
        [[ -n "$existing_orch" ]]  && ORCHESTRA_URL="$existing_orch"
        [[ -n "$existing_comms" ]] && UNITY_COMMS_URL="$existing_comms"
        if [[ "$(get_env_value "SELF_HOST")" == "1" ]]; then
            SELF_HOST_MODE=true
            ORCHESTRA_URL="${ORCHESTRA_URL:-http://127.0.0.1:8000/v0}"
            UNITY_COMMS_URL="${UNITY_COMMS_URL:-http://127.0.0.1:8001}"
            LINK_COORDINATOR=true
        fi
    fi

    # Rewrite .env with the new key (preserves TUNNEL_*/DEVICE_ID and URLs).
    setup_agent_service_env

    # Stop running services so they restart with the new key in memory.
    stop_all_services

    mkdir -p "$LOG_DIR"

    # Re-register tunnel + desktop with the new key.
    if $SELF_HOST_MODE; then
        ORCHESTRA_URL="${ORCHESTRA_URL:-http://127.0.0.1:8000/v0}"
        register_self_host_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" || true
    else
        register_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" 3000 "$DEVICE_NAME" || true
        tunnel_url=$(get_env_value "TUNNEL_URL")
        if [[ -n "$tunnel_url" ]]; then
            register_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" "$tunnel_url" || true
        fi
    fi

    # Re-provision the SFTP server + tunnel and persist the SFTP_* values.
    register_sftp_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" || true
    setup_sftp_server || true
    setup_agent_service_env

    start_all_services
    exit 0
fi

# Handle start command (just start services, no install/config - no root needed)
if $DO_START; then
    # Self-heal: re-register tunnel/desktop if they were deleted on the backend
    # while local ids persisted. Best-effort and offline-safe (never blocks start).
    ensure_registration || true
    start_all_services
    exit 0
fi

# Handle stop command
if $DO_STOP; then
    stop_all_services
    exit 0
fi

# Handle sync-keys (lightweight reconcile run by the com.unify.sftp-sync timer:
# refresh authorized_keys + report tunnel coords for links enabled in the console
# after install). Runs as the regular user; no root, no install, no registration.
if $DO_SYNC_KEYS; then
    reconcile_sftp_links
    auto_prune_sftp_tunnels || true
    exit 0
fi

# Handle uninstall command
if $DO_UNINSTALL; then
    uninstall_all
    exit 0
fi

# Handle prereqs-only (install dependencies without requiring a key)
if $PREREQS_ONLY; then
    echo ""
    echo "Prerequisites-only mode"

    # macOS: install must run as the regular user — Homebrew/npm/bun refuse to run as root.
    if [[ "$EUID" -eq 0 ]]; then
        echo "ERROR: Do not run the install as root — Homebrew cannot run as root." >&2
        echo "Run as your normal user (the .pkg installer handles this automatically)." >&2
        exit 1
    fi

    install_system_deps
    install_nodejs
    install_bun
    install_websockify
    install_rumps
    install_novnc
    install_magnitude
    install_agent_service
    install_rathole
    install_rclone

    # Install + launch the tray so the user can enter their API key via its
    # first-run dialog (the tray runs without a key — shows "stopped").
    setup_autostart

    echo ""
    echo "Prerequisites installed. Run with --unify-key to complete configuration."
    exit 0
fi

# Validate required parameters
if [[ -z "$UNIFY_KEY" ]]; then
    echo "ERROR: --unify-key is required" >&2
    echo ""
    echo "Usage:"
    echo "  sudo ./setup.sh --unify-key 'your-key'"
    echo "  ./setup.sh --start"
    echo "  ./setup.sh --stop"
    echo "  sudo ./setup.sh --uninstall"
    echo ""
    exit 1
fi

# Detect fast mode
fast_mode=false
if test_fast_mode && [[ "$FORCE" == "false" ]]; then
    fast_mode=true
fi

if $fast_mode; then
    echo ""
    echo "Fast mode: All components installed, skipping installations"
else
    echo ""
    echo "Full install mode"

    # macOS: install must run as the regular user — Homebrew/npm/bun refuse to run as root.
    if [[ "$EUID" -eq 0 ]]; then
        echo "ERROR: Do not run the install as root — Homebrew cannot run as root." >&2
        echo "Run as your normal user (the .pkg installer handles this automatically)." >&2
        exit 1
    fi

    # Install prerequisites
    install_system_deps
    install_nodejs
    install_bun
    install_websockify
    install_rumps

    # Install main components
    install_novnc
    install_magnitude
    install_agent_service
    install_rathole
    install_rclone
fi

# Always run configuration
apply_compose_self_host_mode
if $SELF_HOST_MODE; then
    ORCHESTRA_URL="${ORCHESTRA_URL:-http://127.0.0.1:8000/v0}"
    UNITY_COMMS_URL="${UNITY_COMMS_URL:-http://127.0.0.1:8001}"
    LINK_COORDINATOR=true
fi
setup_agent_service_env
setup_autostart

# Create log directory
mkdir -p "$LOG_DIR"

# Register desktop for Unity control.
if $SELF_HOST_MODE; then
    register_self_host_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" || true
else
    register_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" 3000 "$DEVICE_NAME" || true
    tunnel_url=$(get_env_value "TUNNEL_URL")
    if [[ -n "$tunnel_url" ]]; then
        register_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" "$tunnel_url" || true
    fi
fi

# Provision the app-owned SFTP server + (cloud) its raw-TCP tunnel. Rewrite the
# .env afterwards so the freshly-resolved SFTP_* values are persisted for the
# launchd agents (run-sftp.sh reads them).
register_sftp_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" || true
setup_sftp_server || true
setup_agent_service_env

# Start services (unless --no-start, e.g. when called from .pkg postinstall)
if $NO_START; then
    echo ""
    echo "Setup complete (services not started — use --start or the installer will handle it)."
else
    start_all_services
    show_summary
fi
