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
#   - Agent Service (port 3000)
#
# Access URLs:
#   - Desktop: http://localhost:6080/custom.html?password=<vnc-password>
#   - Agent API: http://localhost:3000

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

# macOS Screen Sharing management
KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

# Default configuration
UNIFY_KEY=""
ORCHESTRA_URL="https://api.unify.ai/v0"
UNITY_COMMS_URL="https://unity-comms-app-000000000000.us-central1.run.app"
DO_START=false
DO_STOP=false
DO_UNINSTALL=false
FORCE=false
SKIP_BREW=false
NO_START=false
PREREQS_ONLY=false
DEVICE_NAME=""

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
  --skip-brew           Skip Homebrew operations (used by .pkg postinstall)
  --no-start            Skip starting services at end (used by .pkg postinstall)
  --prereqs-only        Install prerequisites only (no key required, no config/registration)
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
        --skip-brew)
            SKIP_BREW=true; shift ;;
        --no-start)
            NO_START=true; shift ;;
        --prereqs-only)
            PREREQS_ONLY=true; shift ;;
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

# =============================================================================
# Helper Functions
# =============================================================================

test_port_listening() {
    local port=$1
    lsof -iTCP:"$port" -sTCP:LISTEN -P >/dev/null 2>&1 && return 0
    return 1
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

    if python3 -c "import rumps" &>/dev/null; then
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

    # Note: macOS Screen Sharing (system service on 5900) is left running here.
    # It requires root to toggle and is only disabled on full uninstall.
    #
    # The tray launchd agent (com.unify.tray) is intentionally NOT unloaded here —
    # the tray itself calls --stop, so unloading it would kill the menu-bar app.
    # The tray agent is only removed on full uninstall.

    # Final sweep: kill processes on target ports
    for port in 6080 3000; do
        pids=$(lsof -ti TCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs kill -TERM 2>/dev/null || true
            echo "  Killed process on port $port"
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

    # 1. Stop all services
    stop_all_services

    # 1b. Disable macOS Screen Sharing (system service — requires root)
    if [[ -f "$KICKSTART" ]]; then
        if [[ "$EUID" -eq 0 ]]; then
            echo ""
            echo "Disabling Screen Sharing..."
            "$KICKSTART" -deactivate -stop 2>/dev/null || true
            "$KICKSTART" -configure -access -off 2>/dev/null || true
            "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy no 2>/dev/null || true
            launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
            echo "  Screen Sharing disabled"
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
    fi

    # 3. Remove rathole
    if [[ -d "$RATHOLE_DIR" ]]; then
        rm -rf "$RATHOLE_DIR"
        echo "  Removed rathole directory"
    fi

    # 4. Remove launchd agents
    echo ""
    echo "Removing launchd agents..."
    # Resolve the real user (uninstall is run via sudo, so $HOME/id -u are root's)
    local tgt_user tgt_home tgt_uid
    tgt_user="${SUDO_USER:-$USER}"
    tgt_home=$(eval echo "~$tgt_user")
    tgt_uid=$(id -u "$tgt_user" 2>/dev/null || echo "")

    for agent in com.unify.tray; do
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

    echo ""
    echo "Uninstall cleanup complete."
    echo "To fully remove, delete $INSTALL_DIR and /usr/local/bin/unify-desktop-assistant"
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

    pip3 install --break-system-packages websockify 2>/dev/null \
        || pip3 install websockify

    echo "  websockify installed via pip"
}

install_rumps() {
    echo ""
    echo "=== Installing rumps (tray app) ==="

    if python3 -c "import rumps" &>/dev/null 2>&1; then
        echo "  rumps already installed"
        return
    fi

    pip3 install --break-system-packages rumps 2>/dev/null \
        || pip3 install rumps

    echo "  rumps installed via pip"
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

    local rathole_version="0.5.0"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)     arch="x86_64-apple-darwin" ;;
        arm64)      arch="aarch64-apple-darwin" ;;
        aarch64)    arch="aarch64-apple-darwin" ;;
        *)          echo "  ERROR: Unsupported architecture: $arch" >&2; return 1 ;;
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
        echo "  Tunnel already registered: $existing_id"
        local existing_url
        existing_url=$(get_env_value "TUNNEL_URL")
        [[ -n "$existing_url" ]] && echo "  URL: $existing_url"
        return
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
        echo "  Desktop already registered: ID=$existing_id"
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
                echo "  WARNING: Could not update desktop URL (HTTP ${http_code})"
            fi
        fi
        return
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

    local existing_tunnel_id existing_tunnel_url existing_tunnel_token existing_device_id
    existing_tunnel_id=$(get_env_value "TUNNEL_ID")
    existing_tunnel_url=$(get_env_value "TUNNEL_URL")
    existing_tunnel_token=$(get_env_value "TUNNEL_TOKEN")
    existing_device_id=$(get_env_value "DEVICE_ID")

    cat > "$env_file" <<ENVFILE
# Agent Service Environment Configuration
# Generated: $(date)

PORT=3000
UNIFY_KEY=$UNIFY_KEY
ORCHESTRA_URL=$ORCHESTRA_URL
UNITY_COMMS_URL=$UNITY_COMMS_URL
PLAYWRIGHT_BROWSERS_PATH=$INSTALL_DIR/browsers

# Tunnel & Device (managed by setup/registration)
TUNNEL_ID=$existing_tunnel_id
TUNNEL_URL=$existing_tunnel_url
TUNNEL_TOKEN=$existing_tunnel_token
DEVICE_ID=$existing_device_id
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

    # Resolve the user's python3 (has rumps installed); fall back to system python.
    local python_bin
    python_bin=$(command -v python3 || echo /usr/bin/python3)

    sed \
        -e "s|%PYTHON%|$python_bin|g" \
        -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
        -e "s|%LOG_DIR%|$LOG_DIR|g" \
        "$template" > "$tray_plist"
    echo "  Autostart plist created: $tray_plist"

    # (Re)load the tray agent so it starts now and at every login.
    if [[ "$EUID" -ne 0 ]]; then
        local domain="gui/$(id -u)"
        launchctl bootout "$domain/com.unify.tray" 2>/dev/null || true
        if launchctl bootstrap "$domain" "$tray_plist" 2>/dev/null; then
            echo "  Tray agent loaded (will start at login)"
        else
            echo "  Tray agent will load at next login"
        fi
    else
        echo "  Skipping launchctl load (running as root) — tray loads at next user login"
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
        local vnc_password="$UNIFY_KEY"
        if [[ -z "$vnc_password" && -f "$AGENT_SERVICE_DIR/.env" ]]; then
            vnc_password=$(get_env_value "UNIFY_KEY")
        fi

        if [[ -z "$vnc_password" ]]; then
            echo "  ERROR: Cannot start Screen Sharing — no VNC password (UNIFY_KEY not set)" >&2
            echo "  Configure via: sudo setup.sh --unify-key YOUR_KEY" >&2
        elif [[ ! -f "$KICKSTART" ]]; then
            echo "  ERROR: kickstart not found — cannot manage Screen Sharing" >&2
        elif [[ "$EUID" -ne 0 ]]; then
            echo "  WARNING: Screen Sharing requires root to enable. Run with sudo or enable manually." >&2
            echo "  Skipping VNC — other services will still start." >&2
        else
            # Apple VNC passwords are limited to 8 characters
            local vnc_pw_short="${vnc_password:0:8}"
            echo "  Enabling Screen Sharing..."
            "$KICKSTART" \
                -activate -configure -access -on \
                -clientopts -setvnclegacy -vnclegacy yes \
                -clientopts -setvncpw -vncpw "$vnc_pw_short" \
                -restart -agent -privs -all > "$LOG_DIR/screensharing.log" 2>&1 || true
        fi
    else
        echo "  Screen Sharing already running on port 5900"
    fi

    # Start websockify (only if not already running on 6080)
    if ! test_port_listening 6080; then
        echo "  Starting websockify..."
        nohup python3 -m websockify --web="$NOVNC_DIR" 6080 localhost:5900 \
            > "$LOG_DIR/websockify.log" 2>&1 &
    else
        echo "  websockify already running on port 6080"
    fi

    # Start Agent Service (only if not already running on 3000)
    if ! test_port_listening 3000; then
        echo "  Starting Agent Service..."
        (
            cd "$AGENT_SERVICE_DIR"
            export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/browsers"
            nohup npx -y ts-node src/index.ts > "$LOG_DIR/agent.log" 2>&1 &
        )
    else
        echo "  Agent Service already running on port 3000"
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
        test_port_listening 3000 && agent_up=true

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

    if test_port_listening 3000; then
        echo "  [OK] Agent Service (port 3000)"
    else
        echo "  [FAIL] Agent Service (port 3000)"
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

    # Start tunnel after local services are confirmed up
    if $all_ok; then
        start_tunnel
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

    local vnc_url="http://localhost:6080/custom.html"
    if [[ -n "$UNIFY_KEY" ]]; then
        vnc_url="${vnc_url}?password=${UNIFY_KEY:0:8}"
    fi

    echo "  Desktop:       $vnc_url"
    echo "  Agent Service: http://localhost:3000"

    local tunnel_url tunnel_id device_id
    tunnel_url=$(get_env_value "TUNNEL_URL")
    tunnel_id=$(get_env_value "TUNNEL_ID")
    device_id=$(get_env_value "DEVICE_ID")

    if [[ -n "$tunnel_url" ]]; then
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
    start_all_services
    exit 0
fi

# Handle stop command
if $DO_STOP; then
    stop_all_services
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
fi

# Always run configuration
setup_agent_service_env
setup_autostart

# Create log directory
mkdir -p "$LOG_DIR"

# Register tunnel and desktop (always, so config is ready for --start)
register_tunnel "$UNIFY_KEY" "$UNITY_COMMS_URL" 3000 "$DEVICE_NAME" || true

tunnel_url=$(get_env_value "TUNNEL_URL")
if [[ -n "$tunnel_url" ]]; then
    register_desktop "$UNIFY_KEY" "$ORCHESTRA_URL" "$DEVICE_NAME" "$tunnel_url" || true
fi

# Start services (unless --no-start, e.g. when called from .pkg postinstall)
if $NO_START; then
    echo ""
    echo "Setup complete (services not started — use --start or the installer will handle it)."
else
    start_all_services
    show_summary
fi
