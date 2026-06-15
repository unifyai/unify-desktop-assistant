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
import tempfile
import shutil
import atexit
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
ASSETS_DIR = INSTALL_DIR / "assets"
SETUP_SCRIPT = TOOLS_DIR / "setup.sh"
ENV_FILE = AGENT_SERVICE_DIR / ".env"
SIGNAL_FILE = INSTALL_DIR / "uninstall.signal"
LOG_DIR = INSTALL_DIR / "logs"
LOGO_PATH = ASSETS_DIR / "unify_logo_only.png"

VNC_PORT = 5900
NOVNC_PORT = 6080
AGENT_PORT = 3000

STATUS_INTERVAL = 5  # seconds

# Emoji fallback used only when the composited logo icon can't be built.
STATUS_ICONS = {
    "running": "🟢",
    "partial": "🟡",
    "stopped": "🔴",
}

# Status dot colors (RGB), matching the Ubuntu tray palette.
STATUS_COLORS = {
    "running": (76, 175, 80),    # green
    "partial": (255, 193, 7),    # amber
    "stopped": (244, 67, 54),    # red
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


def _as_applescript_str(s: str) -> str:
    """Render a Python string as an AppleScript string literal.

    Escapes quotes/backslashes and converts newlines into `& return &` joins so
    multi-line messages render correctly inside osascript.
    """
    lines = []
    for line in s.split("\n"):
        line = line.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'"{line}"')
    return " & return & ".join(lines) if len(lines) > 1 else lines[0]


def make_status_icon(logo_path, status, out_path, size: int = 22, scale: int = 2) -> bool:
    """Composite the Unify logo with a colored status dot at the lower-right.

    Renders at `scale`x for retina crispness, then tags the PNG's point size as
    `size` so it fits the menu bar. Uses PyObjC's AppKit (a rumps dependency, so
    no extra install). Returns True on success, False on any failure (caller
    then falls back to the emoji title).
    """
    try:
        from AppKit import (
            NSImage, NSBitmapImageRep, NSColor, NSBezierPath,
            NSGraphicsContext, NSCalibratedRGBColorSpace,
            NSCompositingOperationSourceOver,
        )
        from Foundation import NSMakeRect, NSZeroRect
        try:
            from AppKit import NSBitmapImageFileTypePNG as PNG_TYPE
        except Exception:
            PNG_TYPE = 4  # NSPNGFileType
    except Exception:
        return False

    try:
        logo = NSImage.alloc().initWithContentsOfFile_(str(logo_path))
        if logo is None:
            return False

        px = int(size * scale)

        # Offscreen bitmap (no WindowServer needed, unlike NSImage.lockFocus).
        rep = NSBitmapImageRep.alloc().\
            initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
                None, px, px, 8, 4, True, False, NSCalibratedRGBColorSpace, 0, 0
            )
        if rep is None:
            return False
        ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
        if ctx is None:
            return False

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.setCurrentContext_(ctx)
        try:
            # Logo fills the canvas.
            logo.drawInRect_fromRect_operation_fraction_(
                NSMakeRect(0, 0, px, px), NSZeroRect,
                NSCompositingOperationSourceOver, 1.0,
            )

            # Status dot at the lower-right (AppKit origin is bottom-left).
            r, g, b = STATUS_COLORS.get(status, (158, 158, 158))
            diam = px * 0.46
            margin = px * 0.02
            ring = px * 0.07
            x = px - diam - margin
            y = margin

            # White ring for contrast against the (green) logo / menu bar.
            NSColor.whiteColor().set()
            NSBezierPath.bezierPathWithOvalInRect_(
                NSMakeRect(x - ring, y - ring, diam + 2 * ring, diam + 2 * ring)
            ).fill()

            # Colored dot.
            NSColor.colorWithCalibratedRed_green_blue_alpha_(
                r / 255.0, g / 255.0, b / 255.0, 1.0
            ).set()
            NSBezierPath.bezierPathWithOvalInRect_(
                NSMakeRect(x, y, diam, diam)
            ).fill()
        finally:
            NSGraphicsContext.restoreGraphicsState()

        rep.setSize_((size, size))  # point size = menu-bar height, 2x backing
        png = rep.representationUsingType_properties_(PNG_TYPE, {})
        png.writeToFile_atomically_(str(out_path), True)
        return True
    except Exception:
        return False


# =============================================================================
# Tray Application
# =============================================================================

class UnifyTrayApp(rumps.App):
    def __init__(self):
        super().__init__(
            APP_NAME,
            quit_button=None,
        )
        self.template = False  # colored icon (logo + status dot), not tinted

        # Pre-build the composited logo+dot icons (falls back to emoji if needed).
        self._icon_paths = {}
        self._icon_tmpdir = None
        self._build_status_icons()

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
            rumps.MenuItem("Uninstall...", callback=self._uninstall),
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

    def _build_status_icons(self):
        """Composite logo+dot PNGs for each status into a temp dir (cached)."""
        if not LOGO_PATH.exists():
            return
        try:
            tmpdir = Path(tempfile.mkdtemp(prefix="unify-tray-"))
            for status in ("running", "partial", "stopped"):
                out = tmpdir / f"unify-{status}.png"
                if make_status_icon(LOGO_PATH, status, out):
                    self._icon_paths[status] = str(out)
            if self._icon_paths:
                self._icon_tmpdir = tmpdir
                atexit.register(self._cleanup_icons)
            else:
                shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            self._icon_paths = {}

    def _cleanup_icons(self):
        """Remove the temp icon directory on exit."""
        if self._icon_tmpdir:
            shutil.rmtree(self._icon_tmpdir, ignore_errors=True)
            self._icon_tmpdir = None

    def _set_status_icon(self, status_key: str):
        """Set the menu-bar icon for a status; fall back to emoji if unavailable."""
        path = self._icon_paths.get(status_key)
        if path:
            self.icon = path
        else:
            self.title = STATUS_ICONS.get(status_key, "⚪")

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
                self._set_status_icon(status_key)

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
                self._enable_screen_sharing()
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

    def _enable_screen_sharing(self):
        """Enable Apple Screen Sharing (ARD) via an admin prompt.

        Enabling Screen Sharing requires root, which the tray (a user-context
        agent) lacks, so we elevate with a single native authentication dialog
        via osascript. The work lives in `setup.sh --enable-screen-sharing`,
        which turns on Apple Remote Desktop (the viewer signs in with the macOS
        account username + password).
        """
        if not SETUP_SCRIPT.exists():
            return
        shell_cmd = f"'{SETUP_SCRIPT}' --enable-screen-sharing"
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
        """Persist the key and (re)configure services, then enable Screen Sharing.

        Uses setup.sh --reconfigure (not --force): it re-applies the key, re-stops
        and restarts services, and re-registers the tunnel/desktop, but skips both
        dependency installs and setup_autostart. The latter is critical — a --force
        run would call setup_autostart, which does `launchctl bootout com.unify.tray`
        and kills this very menu-bar app (and the setup child) before it can reload.
        Kicked off in a background thread so the UI stays responsive.
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
            # --reconfigure does its own stop + restart with the new key, so the
            # agent picks up the new key instead of keeping the old one in memory.
            subprocess.run(
                ["bash", str(SETUP_SCRIPT), "--reconfigure", "--unify-key", key],
                capture_output=True,
            )
            # Screen Sharing uses the macOS account (ARD), not a key-derived VNC
            # password, so it does not need re-enabling when the key changes.
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

    def _prompt_secure(self, title: str, message: str):
        """Prompt for a secret via a masked (hidden-answer) native dialog.

        rumps.Window has no secure-field option, so we use osascript with
        `hidden answer` (characters render as dots). Returns the entered text,
        or None if the user cancelled.
        """
        script = (
            f'set r to display dialog {_as_applescript_str(message)} '
            f'default answer "" with hidden answer '
            f'with title {_as_applescript_str(title)} '
            f'buttons {{"Cancel", "OK"}} default button "OK"\n'
            f'text returned of r'
        )
        try:
            result = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True, text=True, timeout=300,
            )
        except Exception:
            return None
        if result.returncode != 0:
            return None  # cancelled / dismissed
        return result.stdout.rstrip("\n")

    def _show_first_run_settings(self):
        """Prompt for API key on first run when no key is configured (masked)."""
        key = self._prompt_secure(
            "Welcome to Unify Desktop Assistant",
            "Enter your Unify API Key to get started.\n"
            "(Input is hidden for security.)",
        )
        if key and key.strip():
            self._apply_key_and_setup(key.strip())

    def _show_settings(self, _sender):
        """Show the settings dialog (API key entry is fully masked)."""
        current_key = get_env_value("UNIFY_KEY")
        device_id = get_env_value("DEVICE_ID") or "(not registered)"
        tunnel_id = get_env_value("TUNNEL_ID") or "(not registered)"
        tunnel_url = get_env_value("TUNNEL_URL") or "(not available)"
        orchestra_url = get_env_value("ORCHESTRA_URL") or "https://api.unify.ai/v0"
        comms_url = (
            get_env_value("UNITY_COMMS_URL")
            or "https://unity-comms-app-000000000000.us-central1.run.app"
        )

        key_state = "configured" if current_key else "not set"
        message = (
            f"API key: {key_state}\n"
            f"Enter a new key to change it, or leave blank to keep the current one.\n"
            f"(Input is hidden for security.)\n"
            f"\n"
            f"Orchestra URL: {orchestra_url}\n"
            f"Comms URL: {comms_url}\n"
            f"\n"
            f"Device ID: {device_id}\n"
            f"Tunnel ID: {tunnel_id}\n"
            f"Public URL: {tunnel_url}"
        )

        new_key = self._prompt_secure("Settings", message)
        if new_key is None:
            return  # cancelled
        new_key = new_key.strip()
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

    def _uninstall(self, _sender):
        """Uninstall the app via an elevated setup.sh --uninstall, then quit.

        Uninstall needs root (disable Screen Sharing, pkgutil --forget, remove
        /usr/local/bin, delete /opt), so it's run through a single native admin
        prompt via osascript. The tray quits once cleanup finishes.
        """
        confirm = rumps.alert(
            title="Uninstall Unify Desktop Assistant?",
            message=(
                "This will stop all services, disable Screen Sharing, unregister "
                "this device, and remove Unify Desktop Assistant from your Mac.\n\n"
                "This cannot be undone."
            ),
            ok="Uninstall",
            cancel="Cancel",
        )
        if confirm != 1:
            return

        def worker():
            applescript = (
                f'do shell script "\'{SETUP_SCRIPT}\' --uninstall" '
                f"with administrator privileges"
            )
            subprocess.run(
                ["osascript", "-e", applescript],
                capture_output=True, timeout=300,
            )
            rumps.notification(
                APP_NAME, "Uninstalled",
                "Unify Desktop Assistant has been removed.",
            )
            rumps.quit_application()

        threading.Thread(target=worker, daemon=True).start()

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
