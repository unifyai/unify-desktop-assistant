#!/usr/bin/env python3
"""
Unify Desktop Assistant - System Tray GUI Application (Ubuntu/Linux)

A GTK AppIndicator3 application that provides a system tray icon
for managing Unify Desktop Assistant services.

Features:
- System tray icon with status colors (green/yellow/red)
- Start/Stop services
- Settings dialog for API key configuration
- Quick links to desktop viewer and API
- Graceful shutdown via uninstall.signal file

Mirrors: windows/gui/UnifyAssistant.ps1
"""

import os
import sys
import signal
import subprocess
import socket
import webbrowser
import threading
import time
from pathlib import Path

import gi
gi.require_version("Gtk", "3.0")

# Try AyatanaAppIndicator3 first (modern Ubuntu), fall back to AppIndicator3
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
except (ValueError, ImportError):
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3
    except (ValueError, ImportError):
        print("ERROR: Neither AyatanaAppIndicator3 nor AppIndicator3 is available.", file=sys.stderr)
        print("Install: sudo apt install gir1.2-ayatanaappindicator3-0.1", file=sys.stderr)
        sys.exit(1)

from gi.repository import Gtk, GLib, Gdk, GdkPixbuf


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
SETTINGS_FILE = INSTALL_DIR / "settings.json"
SIGNAL_FILE = INSTALL_DIR / "uninstall.signal"
LOG_DIR = INSTALL_DIR / "logs"

VNC_PORT = 5900
NOVNC_PORT = 6080
AGENT_PORT = 3000

STATUS_INTERVAL_MS = 5000  # 5 seconds


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


def get_service_status() -> dict:
    """Get status of all services by checking ports."""
    vnc = test_port_listening(VNC_PORT)
    novnc = test_port_listening(NOVNC_PORT)
    agent = test_port_listening(AGENT_PORT)
    return {
        "vnc": vnc,
        "novnc": novnc,
        "agent": agent,
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


def create_status_icon(status: str, size: int = 22) -> GdkPixbuf.Pixbuf:
    """Create a colored circle icon for the given status."""
    colors = {
        "running": (76, 175, 80),    # Green
        "partial": (255, 193, 7),    # Yellow/Amber
        "stopped": (244, 67, 54),    # Red
    }
    r, g, b = colors.get(status, (158, 158, 158))

    # Create a simple colored circle using cairo
    import cairo

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    ctx = cairo.Context(surface)

    # Transparent background
    ctx.set_source_rgba(0, 0, 0, 0)
    ctx.paint()

    # Draw filled circle
    cx, cy = size / 2, size / 2
    radius = size / 2 - 2
    ctx.arc(cx, cy, radius, 0, 2 * 3.14159)
    ctx.set_source_rgb(r / 255, g / 255, b / 255)
    ctx.fill_preserve()

    # Draw border
    ctx.set_source_rgb(0.1, 0.1, 0.1)
    ctx.set_line_width(1)
    ctx.stroke()

    # Convert cairo surface to GdkPixbuf
    data = bytes(surface.get_data())
    pixbuf = GdkPixbuf.Pixbuf.new_from_data(
        data,
        GdkPixbuf.Colorspace.RGB,
        True,
        8,
        size,
        size,
        surface.get_stride(),
    )

    return pixbuf


# =============================================================================
# Tray Application
# =============================================================================

class UnifyTrayApp:
    def __init__(self):
        self.last_status_key = ""
        self._icon_paths = {}  # Cache for temporary icon files

        # Create temporary icon files for AppIndicator
        self._create_icon_files()

        # Create AppIndicator
        self.indicator = AppIndicator3.Indicator.new(
            APP_ID,
            self._icon_paths.get("stopped", "dialog-error"),
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)

        # Build menu
        self.menu = Gtk.Menu()
        self._build_menu()
        self.indicator.set_menu(self.menu)

        # Status update timer
        GLib.timeout_add(STATUS_INTERVAL_MS, self._update_status)

        # Initial status
        self._update_status()

        # Auto-start services if key is configured
        key = get_env_value("UNIFY_KEY")
        if key:
            self._start_services(None)

    def _create_icon_files(self):
        """Create temporary icon files for AppIndicator (requires file paths)."""
        import tempfile
        import cairo

        icon_dir = Path(tempfile.mkdtemp(prefix="unify-tray-"))

        for status, (r, g, b) in [
            ("running", (76, 175, 80)),
            ("partial", (255, 193, 7)),
            ("stopped", (244, 67, 54)),
        ]:
            size = 22
            surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
            ctx = cairo.Context(surface)

            ctx.set_source_rgba(0, 0, 0, 0)
            ctx.paint()

            cx, cy = size / 2, size / 2
            radius = size / 2 - 2
            ctx.arc(cx, cy, radius, 0, 2 * 3.14159)
            ctx.set_source_rgb(r / 255, g / 255, b / 255)
            ctx.fill_preserve()
            ctx.set_source_rgb(0.12, 0.12, 0.12)
            ctx.set_line_width(1)
            ctx.stroke()

            icon_path = icon_dir / f"unify-{status}.png"
            surface.write_to_png(str(icon_path))
            self._icon_paths[status] = str(icon_path)

    def _build_menu(self):
        """Build the context menu."""
        # Title (disabled)
        title_item = Gtk.MenuItem(label=APP_NAME)
        title_item.set_sensitive(False)
        self.menu.append(title_item)

        # Status
        self.status_item = Gtk.MenuItem(label="Status: Checking...")
        self.status_item.set_sensitive(False)
        self.menu.append(self.status_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        # Start Services
        start_item = Gtk.MenuItem(label="Start Services")
        start_item.connect("activate", self._start_services)
        self.menu.append(start_item)

        # Stop Services
        stop_item = Gtk.MenuItem(label="Stop Services")
        stop_item.connect("activate", self._stop_services)
        self.menu.append(stop_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        # Open Desktop Viewer
        desktop_item = Gtk.MenuItem(label="Open Desktop Viewer")
        desktop_item.connect("activate", self._open_desktop)
        self.menu.append(desktop_item)

        # Open Agent API
        api_item = Gtk.MenuItem(label="Open Agent API")
        api_item.connect("activate", self._open_api)
        self.menu.append(api_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        # Settings
        settings_item = Gtk.MenuItem(label="Settings...")
        settings_item.connect("activate", self._show_settings)
        self.menu.append(settings_item)

        # View Logs
        logs_item = Gtk.MenuItem(label="View Logs...")
        logs_item.connect("activate", self._view_logs)
        self.menu.append(logs_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        # Exit
        exit_item = Gtk.MenuItem(label="Exit")
        exit_item.connect("activate", self._quit)
        self.menu.append(exit_item)

        self.menu.show_all()

    def _update_status(self) -> bool:
        """Periodic status update callback."""
        try:
            # Check for shutdown signal (from uninstaller/upgrader)
            if SIGNAL_FILE.exists():
                try:
                    SIGNAL_FILE.unlink()
                except Exception:
                    pass
                Gtk.main_quit()
                return False

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

            # Only update icon when status changes (smarter updates)
            if self.last_status_key != status_key:
                self.last_status_key = status_key
                icon_path = self._icon_paths.get(status_key)
                if icon_path:
                    self.indicator.set_icon_full(icon_path, status_text)

            self.status_item.set_label(f"Status: {status_text}")

        except Exception:
            pass

        return True  # Keep timer running

    def _start_services(self, _widget):
        """Start all services via setup.sh --start."""
        key = get_env_value("UNIFY_KEY")
        if not key:
            dialog = Gtk.MessageDialog(
                message_type=Gtk.MessageType.WARNING,
                buttons=Gtk.ButtonsType.OK,
                text="Configuration Required",
            )
            dialog.format_secondary_text(
                "Please configure your Unify API Key in Settings first."
            )
            dialog.run()
            dialog.destroy()
            return

        threading.Thread(
            target=lambda: subprocess.run(
                [str(SETUP_SCRIPT), "--start"],
                capture_output=True,
            ),
            daemon=True,
        ).start()

    def _stop_services(self, _widget):
        """Stop all services via setup.sh --stop."""
        threading.Thread(
            target=lambda: subprocess.run(
                [str(SETUP_SCRIPT), "--stop"],
                capture_output=True,
            ),
            daemon=True,
        ).start()

    def _open_desktop(self, _widget):
        """Open the noVNC desktop viewer in the default browser."""
        key = get_env_value("UNIFY_KEY")
        url = f"http://localhost:{NOVNC_PORT}/custom.html"
        if key:
            url += f"?password={key}"
        webbrowser.open(url)

    def _open_api(self, _widget):
        """Open the Agent API in the default browser."""
        webbrowser.open(f"http://localhost:{AGENT_PORT}")

    def _show_settings(self, _widget):
        """Show the settings dialog."""
        dialog = SettingsDialog()
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            dialog.save()
        dialog.destroy()

    def _view_logs(self, _widget):
        """Open the agent log file in the default text editor."""
        log_file = LOG_DIR / "agent.log"
        if log_file.exists():
            subprocess.Popen(["xdg-open", str(log_file)])
        else:
            dialog = Gtk.MessageDialog(
                message_type=Gtk.MessageType.INFO,
                buttons=Gtk.ButtonsType.OK,
                text="Log Viewer",
            )
            dialog.format_secondary_text(f"Log file not found: {log_file}")
            dialog.run()
            dialog.destroy()

    def _quit(self, _widget):
        """Quit the tray application."""
        # Clean up temp icon files
        for path in self._icon_paths.values():
            try:
                os.unlink(path)
            except Exception:
                pass
        Gtk.main_quit()


# =============================================================================
# Settings Dialog
# =============================================================================

class SettingsDialog(Gtk.Dialog):
    def __init__(self):
        super().__init__(
            title="Settings",
            flags=Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
        )

        self.set_default_size(450, 300)
        self.set_resizable(False)

        self.add_buttons(
            "Cancel", Gtk.ResponseType.CANCEL,
            "Save", Gtk.ResponseType.OK,
        )

        box = self.get_content_area()
        box.set_margin_start(20)
        box.set_margin_end(20)
        box.set_margin_top(20)
        box.set_margin_bottom(10)
        box.set_spacing(8)

        # --- Unify API Key ---
        lbl_key = Gtk.Label(label="Unify API Key:", xalign=0)
        box.pack_start(lbl_key, False, False, 0)

        key_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.txt_key = Gtk.Entry()
        self.txt_key.set_visibility(False)  # Password mode
        self.txt_key.set_text(get_env_value("UNIFY_KEY"))
        self.txt_key.set_hexpand(True)
        key_box.pack_start(self.txt_key, True, True, 0)

        self.btn_show = Gtk.Button(label="Show")
        self.btn_show.connect("clicked", self._toggle_key_visibility)
        key_box.pack_start(self.btn_show, False, False, 0)

        box.pack_start(key_box, False, False, 0)

        # --- Orchestra URL ---
        lbl_url = Gtk.Label(label="Orchestra URL:", xalign=0)
        box.pack_start(lbl_url, False, False, 4)

        self.txt_url = Gtk.Entry()
        self.txt_url.set_text(get_env_value("ORCHESTRA_URL") or "https://api.unify.ai/v0")
        self.txt_url.set_sensitive(False)
        box.pack_start(self.txt_url, False, False, 0)

        # --- Unity Comms URL ---
        lbl_comms = Gtk.Label(label="Unity Comms URL:", xalign=0)
        box.pack_start(lbl_comms, False, False, 4)

        self.txt_comms = Gtk.Entry()
        self.txt_comms.set_text(
            get_env_value("UNITY_COMMS_URL")
            or "https://unity-comms-app-000000000000.us-central1.run.app"
        )
        self.txt_comms.set_sensitive(False)
        box.pack_start(self.txt_comms, False, False, 0)

        # --- Startup options (always enabled, informational) ---
        chk_startup = Gtk.CheckButton(label="Start on login")
        chk_startup.set_active(True)
        chk_startup.set_sensitive(False)
        box.pack_start(chk_startup, False, False, 8)

        chk_autostart = Gtk.CheckButton(label="Start services automatically")
        chk_autostart.set_active(True)
        chk_autostart.set_sensitive(False)
        box.pack_start(chk_autostart, False, False, 0)

        # --- Help text ---
        help_label = Gtk.Label(xalign=0)
        help_label.set_markup(
            '<small><i>You can change the API key later by re-opening this dialog.</i></small>'
        )
        box.pack_start(help_label, False, False, 8)

        self.show_all()

    def _toggle_key_visibility(self, _btn):
        visible = self.txt_key.get_visibility()
        self.txt_key.set_visibility(not visible)
        self.btn_show.set_label("Hide" if not visible else "Show")

    def save(self):
        """Save the settings to .env file."""
        set_env_value("UNIFY_KEY", self.txt_key.get_text())
        set_env_value("ORCHESTRA_URL", self.txt_url.get_text())
        set_env_value("UNITY_COMMS_URL", self.txt_comms.get_text())
        set_env_value("PORT", "3000")


# =============================================================================
# Main
# =============================================================================

def main():
    # Handle SIGINT/SIGTERM gracefully
    signal.signal(signal.SIGINT, lambda *_: Gtk.main_quit())
    signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())

    # Allow keyboard interrupt from terminal
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, Gtk.main_quit)

    app = UnifyTrayApp()
    Gtk.main()


if __name__ == "__main__":
    main()
