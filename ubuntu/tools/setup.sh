#!/usr/bin/env bash
# setup.sh - Consolidated Unify Desktop Assistant Setup Script (Ubuntu/Linux)
#
# Single script to install, configure, and start all services for localhost use.
# Mirrors windows/tools/setup.ps1 for feature parity.
#
# Usage:
#   sudo ./setup.sh --unify-key "your-key"
#   sudo ./setup.sh --unify-key "your-key" --orchestra-url "https://api.unify.ai/v0"
#   ./setup.sh --start         # Start services only (no install/config, no root needed)
#   ./setup.sh --stop          # Stop services
#   ./setup.sh --uninstall     # Stop services, remove systemd units & firewall rules
#   sudo ./setup.sh --unify-key "your-key" --force   # Force reinstall
#
# Services started:
#   - x11vnc (port 5900)
#   - websockify + noVNC (port 6080)
#   - Agent Service (port 3000 cloud SaaS, 13000 when ~/.unity compose self-host)
#
# Access URLs:
#   - Desktop: http://localhost:6080/custom.html?password=<vnc-password>
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

# Default configuration
UNIFY_KEY=""
ORCHESTRA_URL="https://api.unify.ai/v0"
UNITY_COMMS_URL="https://service.a.run.app"
DO_START=false
DO_STOP=false
DO_UNINSTALL=false
DO_SYNC_KEYS=false
RECONFIGURE=false
FORCE=false
SKIP_APT=false
NO_START=false
PREREQS_ONLY=false
DEVICE_NAME=""
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
  --uninstall           Stop services, remove systemd units & firewall rules
  --sync-keys           Reconcile SFTP authorized_keys + report tunnel coords, then exit
  --prereqs-only        Install prerequisites only (no key required, no config/registration)
  --reconfigure         Re-apply key + re-register + restart services (no deps, no root)
  --self-host           Unity Docker self-host mode (local Orchestra, no tunnel, port ${SELF_HOST_AGENT_PORT})
  --link-coordinator    Link registered desktop to the Coordinator assistant (self-host)
  --coordinator-agent-id ID  Coordinator agent id for --link-coordinator (optional)
  --skip-apt            Skip apt-get operations (used by .deb postinst)
  --no-start            Skip starting services at end (used by .deb postinst)
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
        --reconfigure)
            RECONFIGURE=true; shift ;;
        --self-host)
            SELF_HOST_MODE=true; shift ;;
        --link-coordinator)
            LINK_COORDINATOR=true; shift ;;
        --coordinator-agent-id)
            COORDINATOR_AGENT_ID="$2"; shift 2 ;;
        --prereqs-only)
            PREREQS_ONLY=true; shift ;;
        --skip-apt)
            SKIP_APT=true; shift ;;
        --no-start)
            NO_START=true; shift ;;
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

# Auto-detect dpkg context: if running inside a dpkg maintainer script,
# apt-get calls would deadlock (dpkg holds its own lock).
if [[ -n "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]]; then
    SKIP_APT=true
fi

echo ""
echo "=========================================="
echo "  Unify Desktop Assistant Setup (Ubuntu)"
echo "=========================================="
echo ""

# =============================================================================
# Helper Functions
# =============================================================================

test_port_listening() {
    local port=$1
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q "LISTEN" 2>/dev/null && return 0
    return 1
}

get_package_json_hash() {
    local dir=$1
    local pkg_file="$dir/package.json"
    if [[ -f "$pkg_file" ]]; then
        md5sum "$pkg_file" 2>/dev/null | cut -c1-8
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
        grep -oP "^${key}=\K.*" "$env_file" 2>/dev/null | sed "s/^[\"']//;s/[\"']$//" || true
    fi
}

set_env_value() {
    local key=$1
    local value=$2
    local env_file="$AGENT_SERVICE_DIR/.env"

    mkdir -p "$(dirname "$env_file")"

    if [[ -f "$env_file" ]] && grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# =============================================================================
# Unity Docker Compose self-host (local ~/.unity stack)
# =============================================================================

compose_self_host_user_home() {
    if [[ -n "${SUDO_USER:-}" && "$EUID" -eq 0 ]]; then
        eval echo "~$SUDO_USER"
        return 0
    fi
    echo "$HOME"
}

compose_self_host_present() {
    [[ -f "$(compose_self_host_user_home)/.unity/docker-compose.yml" ]]
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

    local runtime_file
    runtime_file="$(compose_self_host_user_home)/.unity/coordinator-runtime.json"
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
        if explain_orchestra_connect_failure "link this desktop to the Coordinator" "$orchestra_url" "$http_code"; then
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

# =============================================================================
# Fast Mode Detection
# =============================================================================

test_fast_mode() {
    echo "Checking installation status..." >&2

    # Pre-provided packages (should always exist after installation)
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

    # Components that need installation
    if command -v x11vnc &>/dev/null; then
        echo "  [OK] x11vnc" >&2
    else
        echo "  [--] x11vnc (will install)" >&2
        all_ok=false
    fi

    if [[ -f "$NOVNC_DIR/vnc.html" ]]; then
        echo "  [OK] noVNC" >&2
    else
        echo "  [--] noVNC (will install)" >&2
        all_ok=false
    fi

    if command -v websockify &>/dev/null || python3 -m websockify --help &>/dev/null 2>&1; then
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

    # Stop Agent Service (node running agent-service)
    local pids
    pids=$(pgrep -f 'ts-node.*agent-service' 2>/dev/null || true)
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

    # Stop SFTP tunnel (rathole) and SFTP server (rclone)
    pids=$(pgrep -f 'rathole.*sftp-tunnel\.toml' 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        echo "  Stopped SFTP tunnel"
    fi
    pids=$(pgrep -f 'rclone serve sftp' 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        echo "  Stopped SFTP server"
    fi

    # Stop x11vnc
    pids=$(pgrep -x x11vnc 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        echo "  Stopped x11vnc"
    fi

    # Stop systemd user services if they exist
    if systemctl --user is-active unify-agent.service &>/dev/null 2>&1; then
        systemctl --user stop unify-agent.service 2>/dev/null || true
        echo "  Stopped unify-agent.service"
    fi
    if systemctl --user is-active unify-websockify.service &>/dev/null 2>&1; then
        systemctl --user stop unify-websockify.service 2>/dev/null || true
        echo "  Stopped unify-websockify.service"
    fi
    if systemctl --user is-active unify-vnc.service &>/dev/null 2>&1; then
        systemctl --user stop unify-vnc.service 2>/dev/null || true
        echo "  Stopped unify-vnc.service"
    fi
    if systemctl --user is-active unify-sftp.service &>/dev/null 2>&1; then
        systemctl --user stop unify-sftp.service 2>/dev/null || true
        echo "  Stopped unify-sftp.service"
    fi
    systemctl --user stop unify-sftp-sync.timer 2>/dev/null || true

    # Final sweep: kill processes on target ports
    local agent_port
    agent_port="$(agent_service_port)"
    for port in 5900 6080 "$agent_port" "$SFTP_LOCAL_PORT"; do
        pids=$(ss -tlnpH "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs kill -TERM 2>/dev/null || true
            echo "  Killed process on port $port"
        fi
    done

    echo ""
    echo "All services stopped."
}

uninstall_all() {
    echo ""
    echo "=== Uninstalling Unify Desktop Assistant ==="

    # 1. Stop all services
    stop_all_services

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

    # 4. Remove systemd user services
    echo ""
    echo "Removing systemd user services..."
    for svc in unify-vnc unify-websockify unify-agent unify-tray unify-sftp; do
        local svc_file="$HOME/.config/systemd/user/${svc}.service"
        if [[ -f "$svc_file" ]]; then
            systemctl --user disable "${svc}.service" 2>/dev/null || true
            rm -f "$svc_file"
            echo "  Removed: ${svc}.service"
        fi
    done
    # SFTP key-sync timer + its backing oneshot service
    systemctl --user stop unify-sftp-sync.timer 2>/dev/null || true
    systemctl --user disable unify-sftp-sync.timer 2>/dev/null || true
    for unit in unify-sftp-sync.timer unify-sftp-sync.service; do
        local unit_file="$HOME/.config/systemd/user/${unit}"
        if [[ -f "$unit_file" ]]; then
            rm -f "$unit_file"
            echo "  Removed: ${unit}"
        fi
    done
    systemctl --user daemon-reload 2>/dev/null || true

    # 5. Remove UFW firewall rules (if ufw is available)
    if command -v ufw &>/dev/null; then
        echo ""
        echo "Removing firewall rules..."
        ufw delete allow 6080/tcp 2>/dev/null && echo "  Removed: port 6080 (noVNC)" || true
        ufw delete allow 3000/tcp 2>/dev/null && echo "  Removed: port 3000 (Agent Service)" || true
        ufw delete allow "${SFTP_LOCAL_PORT}/tcp" 2>/dev/null && echo "  Removed: port ${SFTP_LOCAL_PORT} (SFTP)" || true
    fi

    # 6. Remove autostart desktop entry
    local autostart_file="$HOME/.config/autostart/unify-desktop-assistant.desktop"
    if [[ -f "$autostart_file" ]]; then
        rm -f "$autostart_file"
        echo "  Removed autostart entry"
    fi

    echo ""
    echo "Uninstall cleanup complete."
}

# =============================================================================
# Installation Functions
# =============================================================================

install_system_deps() {
    echo ""
    echo "=== Installing System Dependencies ==="

    if $SKIP_APT; then
        echo "  Skipping apt-get (dependencies provided by .deb package)"
        return
    fi

    apt-get update -qq

    local packages=(
        x11vnc
        python3
        python3-pip
        python3-venv
        git
        curl
        wget
        ca-certificates
        gnupg
    )

    # For GTK tray app
    packages+=(
        python3-gi
        gir1.2-gtk-3.0
        gir1.2-ayatanaappindicator3-0.1
    )

    apt-get install -y "${packages[@]}"

    echo "  System dependencies installed"
}

install_nodejs() {
    if command -v node &>/dev/null && command -v npx &>/dev/null; then
        local node_major
        node_major=$(node --version | sed 's/v\([0-9]*\).*/\1/')
        if [[ "$node_major" -ge 22 ]]; then
            echo "  Node.js already installed ($(node --version), npx present)"
            return
        fi
        echo "  Node.js $(node --version) found, but v22+ required. Upgrading..."
    elif command -v node &>/dev/null; then
        echo "  Node.js $(node --version) found, but npx is missing. Reinstalling..."
    fi

    echo ""
    echo "=== Installing Node.js 22 ==="

    if $SKIP_APT; then
        echo "  WARNING: Cannot install Node.js v22 (apt unavailable in this context)." >&2
        echo "  Node.js will be installed in the deferred setup phase." >&2
        return
    fi

    # NOTE: `curl ... | bash -` silently swallows curl failures (empty stdin →
    # bash exits 0), which leaves the distro Node (no npm/npx). Download first,
    # abort on a bad fetch, then run.
    local ns_script="/tmp/nodesource_setup_22.sh"
    if curl -fsSL https://deb.nodesource.com/setup_22.x -o "$ns_script"; then
        bash "$ns_script"
        apt-get install -y nodejs
        rm -f "$ns_script"
    else
        echo "  WARNING: Failed to fetch NodeSource setup script." >&2
    fi

    # Verify npm/npx actually exist — distro Node ships them in a separate `npm`
    # package, so fall back to it if NodeSource didn't provide them.
    if ! command -v npx &>/dev/null; then
        echo "  npx still missing after Node install; installing distro npm as fallback..." >&2
        apt-get install -y npm || true
    fi

    if ! command -v npx &>/dev/null; then
        echo "  ERROR: Node.js installed but npx is unavailable. Cannot continue." >&2
        return 1
    fi

    echo "  Node.js installed ($(node --version), npx $(npx --version 2>/dev/null || echo '?'))"
}

install_bun() {
    if command -v bun &>/dev/null; then
        echo "  Bun already installed ($(bun --version))"
        return
    fi

    echo ""
    echo "=== Installing Bun ==="

    # Prefer npm global install (works reliably under sudo, system-wide PATH)
    if command -v npm &>/dev/null; then
        echo "  Installing bun via npm (global)..."
        npm install -g bun && {
            echo "  Bun installed ($(bun --version))"
            return
        }
        echo "  npm global install failed, trying curl installer..." >&2
    fi

    # Fallback: curl installer for the real user
    local target_user="${SUDO_USER:-$USER}"
    local target_home
    target_home=$(eval echo "~$target_user")

    if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        su - "$SUDO_USER" -c 'curl -fsSL https://bun.sh/install | bash' || {
            echo "  ERROR: Bun install failed" >&2
            return 1
        }
    else
        curl -fsSL https://bun.sh/install | bash || {
            echo "  ERROR: Bun install failed" >&2
            return 1
        }
    fi

    # Add user-local bun to PATH for current session
    export BUN_INSTALL="$target_home/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"

    echo "  Bun installed ($(bun --version 2>/dev/null || echo 'unknown'))"
}

install_websockify() {
    echo ""
    echo "=== Installing websockify ==="

    pip3 install --break-system-packages websockify 2>/dev/null \
        || pip3 install websockify

    echo "  websockify installed via pip"
}

install_novnc() {
    echo ""
    echo "=== Installing noVNC ==="

    local vnc_html="$NOVNC_DIR/vnc.html"

    if [[ ! -f "$vnc_html" ]]; then
        # Clean up any partial/failed previous clone
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

    # Create custom.html - iframe wrapper that hides noVNC controls
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

        // Inject CSS to hide control bar, logo, and remote cursor
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
}

install_magnitude() {
    echo ""
    echo "=== Setting up Magnitude ==="

    if [[ ! -f "$MAGNITUDE_DIR/package.json" ]]; then
        echo "  ERROR: magnitude not found at $MAGNITUDE_DIR" >&2
        echo "  This should be included in the installer package." >&2
        return 1
    fi

    # Find bun binary — check PATH, npm global, and user-local install
    local bun_exe=""
    if command -v bun &>/dev/null; then
        bun_exe="$(command -v bun)"
    else
        # Check user-local install (may not be in sudo's PATH)
        local target_home
        target_home=$(eval echo "~${SUDO_USER:-$USER}")
        if [[ -x "$target_home/.bun/bin/bun" ]]; then
            bun_exe="$target_home/.bun/bin/bun"
            export BUN_INSTALL="$target_home/.bun"
            export PATH="$BUN_INSTALL/bin:$PATH"
        fi
    fi

    # Check if deps need install
    if test_dependencies_installed "$MAGNITUDE_DIR" && [[ "$FORCE" == "false" ]]; then
        echo "  Dependencies up-to-date"
    else
        echo "  Installing dependencies and building magnitude workspace..."

        pushd "$MAGNITUDE_DIR" >/dev/null

        # Magnitude declares "packageManager": "bun@..." so turbo requires bun
        if [[ -n "$bun_exe" ]]; then
            echo "  Running bun install (includes build via postinstall)..."
            echo "  Using: $bun_exe"
            "$bun_exe" install

            echo "  Installing Patchright + Chromium (this may take a few minutes)..."
            export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/browsers"
            mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
            if $SKIP_APT; then
                npx -y patchright install chromium
            else
                npx -y patchright install --with-deps chromium
            fi
            echo "  Patchright + Chromium installed"
        else
            echo "  ERROR: bun is required for magnitude (packageManager: bun)" >&2
            echo "  Checked: command -v bun, ~/.bun/bin/bun" >&2
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

    # Check if deps need install
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

    local rathole_version="0.5.0"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x86_64-unknown-linux-gnu" ;;
        aarch64) arch="aarch64-unknown-linux-gnu" ;;
        *)       echo "  ERROR: Unsupported architecture: $arch" >&2; return 1 ;;
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

    local arch rc_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  rc_arch="linux-amd64" ;;
        aarch64) rc_arch="linux-arm64" ;;
        *)       echo "  ERROR: Unsupported architecture: $arch" >&2; return 1 ;;
    esac

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

    # Full install runs as root; the rclone systemd unit runs as the user, so the
    # key dir must be owned by them (700 root-owned would be unreadable).
    if [[ "$EUID" -eq 0 ]]; then
        local tgt
        tgt="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
        if [[ -n "$tgt" && "$tgt" != "root" ]]; then
            chown -R "$tgt":"$(id -gn "$tgt")" "$SSH_DIR" 2>/dev/null || true
        fi
    fi
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
    # actually rewrites authorized_keys, so we can restart the SFTP unit on a real
    # key change without bouncing it (and any live transfer) on every sync tick.
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
print(f"  authorized_keys synced ({len(pubkeys)} key(s) across {len(assistant_ids)} link(s))")
PY
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$changed_flag" 2>/dev/null || true
        return "$rc"
    fi

    # Bring the managed SFTP unit in line with the keys we just synced. Only acts
    # in a user session: the sync timer, --reconfigure and --start all run as the
    # user, while a root install has no user bus (the unit starts at next login).
    # The unit's ConditionPathExists gate keeps start/restart a no-op until
    # authorized_keys exists. Start it if it is down (e.g. first key arrival or a
    # prior crash); restart it only when the key set actually changed, so live
    # SFTP sessions aren't dropped on an unchanged 5-minute reconcile tick.
    if [[ "$EUID" -ne 0 ]] && systemctl --user cat unify-sftp.service >/dev/null 2>&1; then
        systemctl --user reset-failed unify-sftp.service 2>/dev/null || true
        if ! systemctl --user is-active --quiet unify-sftp.service; then
            systemctl --user start unify-sftp.service 2>/dev/null || true
        elif [[ -f "$changed_flag" ]]; then
            systemctl --user restart unify-sftp.service 2>/dev/null || true
        fi
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
        if [[ -n "$client_config" ]]; then
            printf '%s\n' "$client_config" > "$SFTP_RATHOLE_CONFIG"
        fi

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

start_sftp_server() {
    [[ -x "$RCLONE_BIN" ]] || return 0
    if [[ ! -f "$SSH_AUTH_KEYS" ]]; then
        echo "  SFTP server: no authorized_keys yet, skipping"
        return 0
    fi
    if test_port_listening "$SFTP_LOCAL_PORT"; then
        echo "  SFTP server already running on port $SFTP_LOCAL_PORT"
        return 0
    fi
    local bind user
    bind=$(get_env_value "SFTP_BIND_ADDR"); [[ -z "$bind" ]] && bind="127.0.0.1"
    # Fixed contract with the cloud-side rclone client; not the OS account.
    user=$(get_env_value "SFTP_USER"); [[ -z "$user" ]] && user="unity"
    echo "  Starting SFTP server (rclone)..."
    nohup "$RCLONE_BIN" serve sftp "$HOME" \
        --addr "${bind}:${SFTP_LOCAL_PORT}" \
        --user "$user" \
        --authorized-keys "$SSH_AUTH_KEYS" \
        --key "$SSH_HOST_KEY" \
        > "$LOG_DIR/sftp.log" 2>&1 &
}

start_sftp_tunnel() {
    [[ -x "$RATHOLE_BIN" ]] || return 0
    if [[ ! -f "$SFTP_RATHOLE_CONFIG" ]]; then
        echo "  No SFTP tunnel config yet, skipping SFTP tunnel start"
        return 0
    fi
    if pgrep -f "rathole.*sftp-tunnel\.toml" &>/dev/null; then
        echo "  SFTP tunnel already running"
        return 0
    fi
    echo "  Starting SFTP tunnel..."
    nohup "$RATHOLE_BIN" "$SFTP_RATHOLE_CONFIG" > "$LOG_DIR/sftp-tunnel.log" 2>&1 &
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
    tunnel_id=$(grep -oP '"tunnel_id"\s*:\s*"\K[^"]+' "$resp_file" || true)
    tunnel_url=$(grep -oP '"url"\s*:\s*"\K[^"]+' "$resp_file" || true)
    client_token=$(grep -oP '"client_token"\s*:\s*"\K[^"]+' "$resp_file" || true)

    # client_config is a multi-line TOML string; extract with python/jq if available
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
    if [[ -n "$client_config" ]]; then
        printf '%s\n' "$client_config" > "$RATHOLE_CONFIG"
    fi

    echo "  Tunnel registered: $tunnel_id"
    echo "  Public URL: $tunnel_url"
}

start_tunnel() {
    echo ""
    echo "=== Starting Tunnel ==="

    if [[ ! -x "$RATHOLE_BIN" ]]; then
        echo "  Rathole not installed, skipping tunnel start"
        return
    fi

    if [[ ! -f "$RATHOLE_CONFIG" ]]; then
        echo "  No tunnel config found, skipping tunnel start"
        return
    fi

    if pgrep -f "rathole.*client\.toml" &>/dev/null; then
        echo "  Tunnel already running (PID $(pgrep -f 'rathole.*client\.toml' | head -1))"
        return
    fi

    echo "  Starting rathole tunnel client..."
    nohup "$RATHOLE_BIN" "$RATHOLE_CONFIG" > "$LOG_DIR/rathole.log" 2>&1 &

    sleep 2

    if pgrep -f "rathole.*client\.toml" &>/dev/null; then
        local pid
        pid=$(pgrep -f 'rathole.*client\.toml' | head -1)
        local tunnel_url
        tunnel_url=$(get_env_value "TUNNEL_URL")
        echo "  Tunnel running (PID $pid)"
        [[ -n "$tunnel_url" ]] && echo "  Public URL: $tunnel_url"
    else
        echo "  WARNING: Tunnel may have failed to start. Check log: $LOG_DIR/rathole.log"
        if [[ -f "$LOG_DIR/rathole.log" ]]; then
            tail -5 "$LOG_DIR/rathole.log" 2>/dev/null | sed 's/^/    /'
        fi
    fi
}

stop_tunnel() {
    local pids
    pids=$(pgrep -f "rathole.*client\.toml" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        echo "  Stopped rathole tunnel"
    fi
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
        echo "  ERROR: No desktop URL available for registration" >&2
        return 1
    fi

    [[ -z "$device_name" ]] && device_name=$(hostname -s)

    local body
    body=$(printf '{"name": "%s", "url": "%s", "os": "ubuntu"}' "$device_name" "$tunnel_url")

    local resp_file="/tmp/unify_desktop_register.json"
    local http_code
    http_code=$(curl -sS -o "$resp_file" -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${unify_key}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${orchestra_url}/desktop" || true)

    if [[ "$http_code" != "200" ]]; then
        if explain_orchestra_connect_failure "register this desktop" "$orchestra_url" "$http_code"; then
            rm -f "$resp_file"
            return 1
        fi
        echo "  ERROR: Desktop registration failed (HTTP ${http_code})" >&2
        [[ -f "$resp_file" ]] && cat "$resp_file" >&2
        rm -f "$resp_file"
        return 1
    fi

    local device_id
    device_id=$(grep -oP '"id"\s*:\s*\K[^,}\s]+' "$resp_file" | head -1 | tr -d '"' || true)
    rm -f "$resp_file"

    set_env_value "DEVICE_ID" "$device_id"

    echo "  Desktop registered: ID=$device_id"
    echo "  Name: $device_name"
    echo "  URL: $tunnel_url"
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

    # Preserve existing tunnel/device values if .env already exists
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
    existing_sftp_bind=$(get_env_value "SFTP_BIND_ADDR"); [[ -z "$existing_sftp_bind" ]] && existing_sftp_bind="127.0.0.1"
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

setup_systemd_services() {
    echo ""
    echo "=== Setting up systemd user services ==="

    local systemd_dir="$INSTALL_DIR/systemd"

    # Determine the actual user (handle sudo)
    local target_user="${SUDO_USER:-$USER}"
    local target_home
    target_home=$(eval echo "~$target_user")
    local target_group
    target_group=$(id -gn "$target_user")
    local target_systemd_dir="$target_home/.config/systemd/user"
    install -d -o "$target_user" -g "$target_group" \
        "$target_home/.config" \
        "$target_home/.config/systemd" \
        "$target_systemd_dir"

    # Install systemd unit files (services + timers) from the systemd/ directory
    if [[ -d "$systemd_dir" ]]; then
        for unit_file in "$systemd_dir"/*.service "$systemd_dir"/*.timer; do
            if [[ -f "$unit_file" ]]; then
                local unit_name
                unit_name=$(basename "$unit_file")
                # Substitute template variables
                local display="${DISPLAY:-:0}"
                sed \
                    -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
                    -e "s|%NOVNC_DIR%|$NOVNC_DIR|g" \
                    -e "s|%AGENT_SERVICE_DIR%|$AGENT_SERVICE_DIR|g" \
                    -e "s|%LOG_DIR%|$LOG_DIR|g" \
                    -e "s|%DISPLAY%|$display|g" \
                    "$unit_file" > "$target_systemd_dir/$unit_name"
                echo "  Installed: $unit_name"
            fi
        done
    fi

    # Reload systemd for the target user. The sftp-sync TIMER is enabled (it
    # drives the oneshot reconcile); its backing service is not enabled directly.
    if [[ -n "${SUDO_USER:-}" ]]; then
        su - "$SUDO_USER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER") systemctl --user daemon-reload" 2>/dev/null || true
        su - "$SUDO_USER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER") systemctl --user enable unify-vnc.service unify-websockify.service unify-agent.service unify-sftp.service unify-sftp-sync.timer" 2>/dev/null || true
        # Apply the (possibly corrected) sftp unit immediately on upgrade: clear a
        # prior crash-loop and restart. ConditionPathExists keeps this a no-op
        # until authorized_keys exists, so it never force-runs a keyless server.
        su - "$SUDO_USER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER") systemctl --user reset-failed unify-sftp.service" 2>/dev/null || true
        su - "$SUDO_USER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER") systemctl --user restart unify-sftp.service" 2>/dev/null || true
    else
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable unify-vnc.service unify-websockify.service unify-agent.service unify-sftp.service unify-sftp-sync.timer 2>/dev/null || true
        systemctl --user reset-failed unify-sftp.service 2>/dev/null || true
        systemctl --user restart unify-sftp.service 2>/dev/null || true
    fi

    echo "  systemd user services configured"
}

setup_autostart() {
    echo ""
    echo "=== Setting up autostart ==="

    local target_user="${SUDO_USER:-$USER}"
    local target_home
    target_home=$(eval echo "~$target_user")
    local target_group
    target_group=$(id -gn "$target_user")
    local autostart_dir="$target_home/.config/autostart"
    install -d -o "$target_user" -g "$target_group" \
        "$target_home/.config" \
        "$autostart_dir"

    cat > "$autostart_dir/unify-desktop-assistant.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Unify Desktop Assistant
Comment=System tray for Unify Desktop Assistant
Exec=python3 $INSTALL_DIR/gui/unify-assistant.py
Icon=$INSTALL_DIR/assets/unify_logo_only.png
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
StartupNotify=false
DESKTOP

    # Fix ownership if running as sudo
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$target_user":"$target_group" "$autostart_dir/unify-desktop-assistant.desktop"
    fi

    echo "  Autostart entry created"
}

configure_firewall() {
    echo ""
    echo "=== Configuring Firewall ==="

    if ! command -v ufw &>/dev/null; then
        echo "  UFW not installed, skipping firewall configuration"
        return
    fi

    # Only configure if ufw is active
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "  UFW not active, skipping firewall configuration"
        return
    fi

    local agent_port
    agent_port="$(agent_service_port)"

    local fw_ports=("6080/tcp:noVNC" "${agent_port}/tcp:Agent Service")
    # Self-host binds SFTP on all interfaces so the local Unity containers can
    # reach it; cloud mode binds loopback only (tunnel), so no rule is needed.
    if $SELF_HOST_MODE || [[ "$(get_env_value "SELF_HOST")" == "1" ]]; then
        fw_ports+=("${SFTP_LOCAL_PORT}/tcp:SFTP")
    fi

    for port_desc in "${fw_ports[@]}"; do
        local port="${port_desc%%:*}"
        local desc="${port_desc##*:}"
        if ! ufw status | grep -q "$port.*ALLOW"; then
            ufw allow "$port" comment "Unify $desc" 2>/dev/null || true
            echo "  Created rule: $desc (port $port)"
        else
            echo "  Rule exists: $desc (port $port)"
        fi
    done
}

# =============================================================================
# Start Services
# =============================================================================

start_all_services() {
    echo ""
    echo "=== Starting Services ==="

    mkdir -p "$LOG_DIR"

    local agent_port
    agent_port="$(agent_service_port)"

    # Determine DISPLAY
    local display="${DISPLAY:-:0}"

    # Start x11vnc (only if not already running on 5900)
    if ! test_port_listening 5900; then
        if command -v x11vnc &>/dev/null; then
            local vnc_password="$UNIFY_KEY"
            # Try reading from .env if not set
            if [[ -z "$vnc_password" && -f "$AGENT_SERVICE_DIR/.env" ]]; then
                vnc_password=$(grep -oP '^UNIFY_KEY=\K.*' "$AGENT_SERVICE_DIR/.env" 2>/dev/null || true)
            fi

            if [[ -z "$vnc_password" ]]; then
                echo "  ERROR: Cannot start x11vnc — no VNC password (UNIFY_KEY not set)" >&2
                echo "  Configure via: sudo setup.sh --unify-key YOUR_KEY" >&2
            else
                echo "  Starting x11vnc..."
                x11vnc -display "$display" -forever -shared -rfbport 5900 \
                       -passwd "$vnc_password" \
                       -rfbportv6 -1 -noxdamage -nowf -nocursorshape -cursor arrow -nodpms \
                       -o "$LOG_DIR/x11vnc.log" \
                       -bg 2>/dev/null || true
            fi
        else
            echo "  ERROR: x11vnc not found" >&2
        fi
    else
        echo "  x11vnc already running on port 5900"
    fi

    # Start websockify (only if not already running on 6080)
    if ! test_port_listening 6080; then
        echo "  Starting websockify..."
        nohup python3 -m websockify --web="$NOVNC_DIR" 6080 localhost:5900 \
            > "$LOG_DIR/websockify.log" 2>&1 &
    else
        echo "  websockify already running on port 6080"
    fi

    # Start Agent Service (only if not already running on configured PORT)
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
        echo "  [OK] x11vnc (port 5900)"
    else
        echo "  [FAIL] x11vnc (port 5900)"
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
    if $all_ok && ! $SELF_HOST_MODE && [[ "$(get_env_value "SELF_HOST")" != "1" ]]; then
        start_tunnel
    fi

    # SFTP server (rclone) runs in both modes; its tunnel only in cloud mode.
    start_sftp_server
    if ! $SELF_HOST_MODE && [[ "$(get_env_value "SELF_HOST")" != "1" ]]; then
        start_sftp_tunnel
    fi

    # Periodic key-sync timer (runs in both modes); ignore if units aren't loaded.
    systemctl --user start unify-sftp-sync.timer 2>/dev/null || true
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

    local vnc_url="http://localhost:6080/custom.html"
    if [[ -n "$UNIFY_KEY" ]]; then
        vnc_url="${vnc_url}?password=${UNIFY_KEY}"
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

# Handle sync-keys (lightweight reconcile run by the unify-sftp-sync.timer:
# refresh authorized_keys + report tunnel coords for links enabled in the console
# after install). Runs as the regular user; no root, no install, no registration.
if $DO_SYNC_KEYS; then
    reconcile_sftp_links
    exit 0
fi

# Handle uninstall command
if $DO_UNINSTALL; then
    uninstall_all
    exit 0
fi

# Handle reconfigure (lightweight key update: re-apply key + re-register +
# restart services). Used by the tray when the API key changes. It deliberately
# skips dependency installs AND setup_autostart: services run in the user
# session, .env is user-owned, and the tray itself has no port, so a plain
# user-context stop/start is safe and never kills the menu-bar app.
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

    # Settings only changes the API key — preserve the URLs baked at install.
    # Otherwise setup_agent_service_env would overwrite them with setup.sh's
    # hardcoded production defaults, breaking a staging/custom install.
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

    # Stop running services so they restart with the new key (x11vnc password +
    # agent both read UNIFY_KEY at process start).
    stop_all_services

    mkdir -p "$LOG_DIR"

    # Re-register tunnel + desktop with the new key.
    if $SELF_HOST_MODE; then
        ORCHESTRA_URL="${ORCHESTRA_URL:-http://127.0.0.1:8000/v0}"
        register_self_host_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" || true
    else
        register_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" "$(agent_service_port)" "$DEVICE_NAME" || true
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

# Handle prereqs-only (install dependencies without requiring a key).
# Used by the .deb postinst deferred phase so the tray launches and the user
# can enter their key via the tray Settings dialog on first run.
if $PREREQS_ONLY; then
    echo ""
    echo "Prerequisites-only mode"

    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: Prerequisites install requires root. Run with sudo." >&2
        exit 1
    fi

    install_system_deps
    install_nodejs
    install_bun
    install_websockify
    install_novnc
    install_magnitude
    install_agent_service
    install_rathole
    install_rclone

    setup_systemd_services
    setup_autostart
    configure_firewall

    # Fix ownership
    target_user="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        chown -R "$target_user":"$(id -gn "$target_user")" "$INSTALL_DIR" 2>/dev/null || true
    fi

    echo ""
    echo "Prerequisites installed. Open the tray icon to enter your API key and start services."
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

    # Check root for installation
    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: Installation requires root. Run with sudo." >&2
        exit 1
    fi

    # Install prerequisites
    install_system_deps
    install_nodejs
    install_bun
    install_websockify

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
setup_systemd_services
setup_autostart
configure_firewall

# Create log directory
mkdir -p "$LOG_DIR"

# Fix ownership — detect real user even when SUDO_USER isn't set (e.g. dpkg postinst)
target_user="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    chown -R "$target_user":"$(id -gn "$target_user")" "$INSTALL_DIR" 2>/dev/null || true
fi

# Register desktop for Unity control.
if $SELF_HOST_MODE; then
    register_self_host_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" || true
else
    register_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" "$(agent_service_port)" "$DEVICE_NAME" || true
    tunnel_url=$(get_env_value "TUNNEL_URL")
    if [[ -n "$tunnel_url" ]]; then
        register_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" "$tunnel_url" || true
    fi
fi

# Provision the app-owned SFTP server + (cloud) its raw-TCP tunnel, then re-write
# the .env so the resolved SFTP_* values are persisted for the systemd unit.
register_sftp_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" || true
setup_sftp_server || true
setup_agent_service_env

# Start services (unless --no-start, e.g. when called from .deb postinst)
if $NO_START; then
    echo ""
    echo "Setup complete (services not started — use --start or the installer will handle it)."
else
    start_all_services
    show_summary
fi
