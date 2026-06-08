#!/usr/bin/env python3
"""
Unify Desktop Assistant - System Tray GUI Application (macOS)

A rumps-based macOS status bar application that provides a menu bar icon
for managing Unify Desktop Assistant services.

Features:
- Menu bar icon with status indicators (green/yellow/red)
- Start/Stop services
- Settings window for API key configuration
- Quick links to desktop viewer and API
- Graceful shutdown via uninstall.signal file

Mirrors: ubuntu/gui/unify-assistant.py
"""

import os
import sys
import signal
import subprocess
import socket
import webbrowser
import threading
from pathlib import Path

import rumps


# =============================================================================
# Configuration
# =============================================================================

APP_NAME = "Unify Desktop Assistant"
APP_ID = "ai.unify.desktop-assistant"

INSTALL_DIR = Path(__file__).resolve().parent.parent
TOOLS_DIR = INSTALL_DIR / "tools"
AGENT_SERVICE_DIR = INSTALL_DIR / "agent-service"
SETUP_SCRIPT = TOOLS_DIR / "setup.sh"
ENV_FILE = AGENT_SERVICE_DIR / ".env"
SIGNAL_FILE = INSTALL_DIR / "uninstall.signal"
LOG_DIR = INSTALL_DIR / "logs"

VNC_PORT = 5900
NOVNC_PORT = 6080
AGENT_PORT = 3000

STATUS_INTERVAL = 5  # seconds

STATUS_ICONS = {
    "running": "🟢",
    "partial": "🟡",
    "stopped": "🔴",
}


# =============================================================================
# Helper Functions
# =============================================================================

def test_port_listening(port: int) -> bool:
    """Check if a port is listening (fast, no subprocess)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            result = s.connect_ex(("127.0.0.1", port))
            return result == 0
    except Exception:
        return False


def is_tunnel_running() -> bool:
    """Check if rathole tunnel process is running."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "rathole.*client\\.toml"],
            capture_output=True, timeout=2,
        )
        return result.returncode == 0
    except Exception:
        return False


def get_service_status() -> dict:
    """Get status of all services by checking ports."""
    vnc = test_port_listening(VNC_PORT)
    novnc = test_port_listening(NOVNC_PORT)
    agent = test_port_listening(AGENT_PORT)
    tunnel = is_tunnel_running()
    return {
        "vnc": vnc,
        "novnc": novnc,
        "agent": agent,
        "tunnel": tunnel,
        "all_running": vnc and novnc and agent,
        "any_running": vnc or novnc or agent,
    }


def get_env_value(key: str) -> str:
    """Read a value from the agent-service .env file."""
    if not ENV_FILE.exists():
        return ""
    try:
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line.startswith(f"{key}="):
                value = line[len(key) + 1:]
                return value.strip("\"'")
    except Exception:
        pass
    return ""


def set_env_value(key: str, value: str):
    """Set a value in the agent-service .env file."""
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)

    lines = []
    found = False

    if ENV_FILE.exists():
        lines = ENV_FILE.read_text().splitlines()

    new_lines = []
    for line in lines:
        if line.strip().startswith(f"{key}="):
            new_lines.append(f"{key}={value}")
            found = True
        else:
            new_lines.append(line)

    if not found:
        new_lines.append(f"{key}={value}")

    ENV_FILE.write_text("\n".join(new_lines) + "\n")


def copy_to_clipboard(text: str):
    """Copy text to macOS clipboard via pbcopy."""
    try:
        subprocess.run(
            ["pbcopy"], input=text.encode(), check=True, timeout=5,
        )
    except Exception:
        pass


# =============================================================================
# Tray Application
# =============================================================================

class UnifyTrayApp(rumps.App):
    def __init__(self):
        super().__init__(
            APP_NAME,
            title=STATUS_ICONS["stopped"],
            quit_button=None,
        )

        self.last_status_key = ""

        self.status_item = rumps.MenuItem("Status: Checking...", callback=None)
        self.status_item.set_callback(None)

        self.menu = [
            self.status_item,
            None,  # separator
            rumps.MenuItem("Start Services", callback=self._start_services),
            rumps.MenuItem("Stop Services", callback=self._stop_services),
            None,
            rumps.MenuItem("Open Desktop Viewer", callback=self._open_desktop),
            rumps.MenuItem("Open Agent API", callback=self._open_api),
            rumps.MenuItem("Copy Public URL", callback=self._copy_public_url),
            None,
            rumps.MenuItem("Settings...", callback=self._show_settings),
            rumps.MenuItem("View Logs...", callback=self._view_logs),
            None,
            rumps.MenuItem("Quit", callback=self._quit),
        ]

        self._status_timer = rumps.Timer(self._update_status, STATUS_INTERVAL)
        self._status_timer.start()

        # Trigger initial status check
        self._update_status(None)

        # Auto-start services if key is configured
        key = get_env_value("UNIFY_KEY")
        if key:
            self._start_services(None)

    def _update_status(self, _sender):
        """Periodic status update callback."""
        try:
            if SIGNAL_FILE.exists():
                try:
                    SIGNAL_FILE.unlink()
                except Exception:
                    pass
                rumps.quit_application()
                return

            status = get_service_status()

            if status["all_running"]:
                status_key = "running"
                status_text = "Running"
            elif status["any_running"]:
                status_key = "partial"
                status_text = "Partial"
            else:
                status_key = "stopped"
                status_text = "Stopped"

            tunnel_text = "Connected" if status["tunnel"] else "Disconnected"

            if self.last_status_key != status_key:
                self.last_status_key = status_key
                self.title = STATUS_ICONS.get(status_key, "⚪")

            self.status_item.title = f"Services: {status_text} | Tunnel: {tunnel_text}"

        except Exception:
            pass

    def _start_services(self, _sender):
        """Start all services via setup.sh --start.

        setup.sh --start runs unprivileged and cannot enable Screen Sharing, so
        if VNC (5900) is down we first re-enable it via an admin prompt — otherwise
        the status can never reach green. Screen Sharing normally persists, so this
        prompt only appears in edge cases (e.g. it was manually disabled).
        """
        key = get_env_value("UNIFY_KEY")
        if not key:
            self._show_first_run_settings()
            return

        def worker():
            if not test_port_listening(VNC_PORT):
                self._enable_screen_sharing(key)
            subprocess.run(
                ["bash", str(SETUP_SCRIPT), "--start"],
                capture_output=True,
            )

        threading.Thread(target=worker, daemon=True).start()

    def _stop_services(self, _sender):
        """Stop all services via setup.sh --stop."""
        threading.Thread(
            target=lambda: subprocess.run(
                ["bash", str(SETUP_SCRIPT), "--stop"],
                capture_output=True,
            ),
            daemon=True,
        ).start()

    def _enable_screen_sharing(self, key: str):
        """Enable Apple Screen Sharing (VNC) via an admin prompt.

        kickstart requires root, which the tray (a user-context agent) lacks,
        so we elevate with a single native authentication dialog via osascript.
        """
        kickstart = (
            "/System/Library/CoreServices/RemoteManagement/"
            "ARDAgent.app/Contents/Resources/kickstart"
        )
        if not os.path.exists(kickstart):
            return
        vnc_pw = key[:8]  # Apple VNC passwords are limited to 8 characters
        shell_cmd = (
            f"'{kickstart}' -activate -configure -access -on "
            f"-clientopts -setvnclegacy -vnclegacy yes "
            f"-clientopts -setvncpw -vncpw '{vnc_pw}' "
            f"-restart -agent -privs -all"
        )
        applescript = (
            f'do shell script "{shell_cmd}" with administrator privileges'
        )
        try:
            subprocess.run(
                ["osascript", "-e", applescript],
                capture_output=True, timeout=120,
            )
        except Exception:
            pass

    def _apply_key_and_setup(self, key: str):
        """Persist the key and complete full setup (config, registration, services).

        Runs the full keyed setup.sh as the current user (deps, tunnel + desktop
        registration, agent + websockify), then enables Screen Sharing with an
        admin prompt. Kicked off in a background thread so the UI stays responsive.
        """
        key = key.strip()
        if not key:
            return

        set_env_value("UNIFY_KEY", key)
        set_env_value("PORT", "3000")

        rumps.notification(
            APP_NAME, "Setting up",
            "Configuring services… this may take a minute.",
        )

        def worker():
            subprocess.run(
                ["bash", str(SETUP_SCRIPT), "--unify-key", key, "--force"],
                capture_output=True,
            )
            # kickstart needs root — elevate separately with a single admin prompt
            self._enable_screen_sharing(key)
            rumps.notification(
                APP_NAME, "Ready", "Unify Desktop Assistant is set up.",
            )

        threading.Thread(target=worker, daemon=True).start()

    def _open_desktop(self, _sender):
        """Open the noVNC desktop viewer in the default browser."""
        key = get_env_value("UNIFY_KEY")
        url = f"http://localhost:{NOVNC_PORT}/custom.html"
        if key:
            url += f"?password={key[:8]}"
        webbrowser.open(url)

    def _open_api(self, _sender):
        """Open the Agent API in the default browser."""
        webbrowser.open(f"http://localhost:{AGENT_PORT}")

    def _copy_public_url(self, _sender):
        """Copy the tunnel public URL to the clipboard."""
        tunnel_url = get_env_value("TUNNEL_URL")
        if tunnel_url:
            copy_to_clipboard(tunnel_url)
            rumps.notification(
                APP_NAME, "Copied", "Public URL copied to clipboard.",
            )
        else:
            rumps.alert(
                title="No Public URL",
                message="No public URL available. Run setup first to register a tunnel.",
            )

    def _show_first_run_settings(self):
        """Prompt for API key on first run when no key is configured."""
        response = rumps.Window(
            title="Welcome to Unify Desktop Assistant",
            message="Enter your Unify API Key to get started:",
            default_text="",
            ok="Save & Start",
            cancel="Cancel",
            dimensions=(320, 24),
        ).run()

        if response.clicked and response.text.strip():
            self._apply_key_and_setup(response.text.strip())

    def _show_settings(self, _sender):
        """Show the settings dialog."""
        current_key = get_env_value("UNIFY_KEY")
        device_id = get_env_value("DEVICE_ID") or "(not registered)"
        tunnel_id = get_env_value("TUNNEL_ID") or "(not registered)"
        tunnel_url = get_env_value("TUNNEL_URL") or "(not available)"
        orchestra_url = get_env_value("ORCHESTRA_URL") or "https://api.unify.ai/v0"
        comms_url = (
            get_env_value("UNITY_COMMS_URL")
            or "https://unity-comms-app-000000000000.us-central1.run.app"
        )

        info_text = (
            f"Orchestra URL: {orchestra_url}\n"
            f"Comms URL: {comms_url}\n"
            f"\n"
            f"Device ID: {device_id}\n"
            f"Tunnel ID: {tunnel_id}\n"
            f"Public URL: {tunnel_url}"
        )

        response = rumps.Window(
            title="Settings",
            message=f"Enter your Unify API Key:\n\n{info_text}",
            default_text=current_key,
            ok="Save",
            cancel="Cancel",
            dimensions=(360, 24),
        ).run()

        if response.clicked:
            new_key = response.text.strip()
            if new_key and new_key != current_key:
                self._apply_key_and_setup(new_key)

    def _view_logs(self, _sender):
        """Open the agent log file in the default editor."""
        log_file = LOG_DIR / "agent.log"
        if log_file.exists():
            subprocess.Popen(["open", str(log_file)])
        else:
            rumps.alert(
                title="Log Viewer",
                message=f"Log file not found:\n{log_file}",
            )

    def _quit(self, _sender):
        """Quit the tray application."""
        rumps.quit_application()


# =============================================================================
# Main
# =============================================================================

def main():
    signal.signal(signal.SIGINT, lambda *_: rumps.quit_application())
    signal.signal(signal.SIGTERM, lambda *_: rumps.quit_application())

    app = UnifyTrayApp()
    app.run()


if __name__ == "__main__":
    main()
