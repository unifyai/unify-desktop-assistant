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

# Default configuration
UNIFY_KEY=""
ORCHESTRA_URL="https://api.unify.ai/v0"
UNITY_COMMS_URL="https://unity-comms-app-000000000000.us-central1.run.app"
DO_START=false
DO_STOP=false
DO_UNINSTALL=false
FORCE=false
SKIP_APT=false
NO_START=false

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
  --skip-apt            Skip apt-get operations (used by .deb postinst)
  --no-start            Skip starting services at end (used by .deb postinst)
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
        --skip-apt)
            SKIP_APT=true; shift ;;
        --no-start)
            NO_START=true; shift ;;
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

    $all_ok
}

# =============================================================================
# Stop Services
# =============================================================================

stop_all_services() {
    echo ""
    echo "=== Stopping Services ==="

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

    # Final sweep: kill processes on target ports
    for port in 5900 6080 3000; do
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

    # 2. Remove systemd user services
    echo ""
    echo "Removing systemd user services..."
    for svc in unify-vnc unify-websockify unify-agent unify-tray; do
        local svc_file="$HOME/.config/systemd/user/${svc}.service"
        if [[ -f "$svc_file" ]]; then
            systemctl --user disable "${svc}.service" 2>/dev/null || true
            rm -f "$svc_file"
            echo "  Removed: ${svc}.service"
        fi
    done
    systemctl --user daemon-reload 2>/dev/null || true

    # 3. Remove UFW firewall rules (if ufw is available)
    if command -v ufw &>/dev/null; then
        echo ""
        echo "Removing firewall rules..."
        ufw delete allow 6080/tcp 2>/dev/null && echo "  Removed: port 6080 (noVNC)" || true
        ufw delete allow 3000/tcp 2>/dev/null && echo "  Removed: port 3000 (Agent Service)" || true
    fi

    # 4. Remove autostart desktop entry
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

    if $SKIP_APT; then
        echo "  WARNING: Cannot install Node.js v22 (apt unavailable in this context)." >&2
        echo "  Node.js will be installed in the deferred setup phase." >&2
        return
    fi

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs

    echo "  Node.js installed ($(node --version))"
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

        echo "  Installing Patchright + Chromium (this may take a few minutes)..."
        if $SKIP_APT; then
            # Download browser only — system deps come from .deb Depends or manual install
            npx -y patchright@1.52.0 install chromium
        else
            # Download browser + install system libraries via apt
            npx -y patchright@1.52.0 install --with-deps chromium
        fi

        save_dependencies_hash "$AGENT_SERVICE_DIR"
        popd >/dev/null

        echo "  Dependencies installed"
    fi
}

# =============================================================================
# Configuration Functions
# =============================================================================

setup_agent_service_env() {
    echo ""
    echo "=== Configuring Agent Service ==="

    local env_file="$AGENT_SERVICE_DIR/.env"

    cat > "$env_file" <<ENVFILE
# Agent Service Environment Configuration
# Generated: $(date)

PORT=3000
UNIFY_KEY=$UNIFY_KEY
ORCHESTRA_URL=$ORCHESTRA_URL
UNITY_COMMS_URL=$UNITY_COMMS_URL
ENVFILE

    echo "  .env created"
    echo "    UNIFY_KEY: $(if [[ -n "$UNIFY_KEY" ]]; then echo '(set)'; else echo '(not set)'; fi)"
    echo "    ORCHESTRA_URL: $ORCHESTRA_URL"
    echo "    UNITY_COMMS_URL: $UNITY_COMMS_URL"
}

setup_systemd_services() {
    echo ""
    echo "=== Setting up systemd user services ==="

    local systemd_dir="$INSTALL_DIR/systemd"
    local user_systemd_dir="$HOME/.config/systemd/user"
    mkdir -p "$user_systemd_dir"

    # Determine the actual user (handle sudo)
    local target_user="${SUDO_USER:-$USER}"
    local target_home
    target_home=$(eval echo "~$target_user")
    local target_systemd_dir="$target_home/.config/systemd/user"
    mkdir -p "$target_systemd_dir"

    # Install systemd unit files from the systemd/ directory
    if [[ -d "$systemd_dir" ]]; then
        for unit_file in "$systemd_dir"/*.service; do
            if [[ -f "$unit_file" ]]; then
                local unit_name
                unit_name=$(basename "$unit_file")
                # Substitute template variables
                sed \
                    -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
                    -e "s|%NOVNC_DIR%|$NOVNC_DIR|g" \
                    -e "s|%AGENT_SERVICE_DIR%|$AGENT_SERVICE_DIR|g" \
                    -e "s|%LOG_DIR%|$LOG_DIR|g" \
                    "$unit_file" > "$target_systemd_dir/$unit_name"
                echo "  Installed: $unit_name"
            fi
        done
    fi

    # Reload systemd for the target user
    if [[ -n "${SUDO_USER:-}" ]]; then
        su - "$SUDO_USER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER") systemctl --user daemon-reload" 2>/dev/null || true
        su - "$SUDO_USER" -c "XDG_RUNTIME_DIR=/run/user/$(id -u "$SUDO_USER") systemctl --user enable unify-vnc.service unify-websockify.service unify-agent.service" 2>/dev/null || true
    else
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable unify-vnc.service unify-websockify.service unify-agent.service 2>/dev/null || true
    fi

    echo "  systemd user services configured"
}

setup_autostart() {
    echo ""
    echo "=== Setting up autostart ==="

    local target_user="${SUDO_USER:-$USER}"
    local target_home
    target_home=$(eval echo "~$target_user")
    local autostart_dir="$target_home/.config/autostart"
    mkdir -p "$autostart_dir"

    cat > "$autostart_dir/unify-desktop-assistant.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Unify Desktop Assistant
Comment=System tray for Unify Desktop Assistant
Exec=python3 $INSTALL_DIR/gui/unify-assistant.py
Icon=$INSTALL_DIR/assets/icon.png
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
StartupNotify=false
DESKTOP

    # Fix ownership if running as sudo
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$autostart_dir/unify-desktop-assistant.desktop"
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

    for port_desc in "6080/tcp:noVNC" "3000/tcp:Agent Service"; do
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

            echo "  Starting x11vnc..."
            x11vnc -display "$display" -nopw -forever -shared -rfbport 5900 \
                   ${vnc_password:+-passwd "$vnc_password"} \
                   -rfbportv6 -1 -noxdamage -nowf -nocursorshape -cursor arrow -nodpms \
                   -o "$LOG_DIR/x11vnc.log" \
                   -bg 2>/dev/null || true
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

    # Start Agent Service (only if not already running on 3000)
    if ! test_port_listening 3000; then
        echo "  Starting Agent Service..."
        (
            cd "$AGENT_SERVICE_DIR"
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
    echo "Access URLs:"

    local vnc_url="http://localhost:6080/custom.html"
    if [[ -n "$UNIFY_KEY" ]]; then
        vnc_url="${vnc_url}?password=${UNIFY_KEY}"
    fi

    echo "  Desktop:       $vnc_url"
    echo "  Agent Service: http://localhost:3000"
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
fi

# Always run configuration
setup_agent_service_env
setup_systemd_services
setup_autostart
configure_firewall

# Create log directory
mkdir -p "$LOG_DIR"

# Fix ownership if running as sudo
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$INSTALL_DIR" 2>/dev/null || true
fi

# Start services (unless --no-start, e.g. when called from .deb postinst)
if $NO_START; then
    echo ""
    echo "Setup complete (services not started — use --start or the installer will handle it)."
else
    start_all_services
    show_summary
fi
