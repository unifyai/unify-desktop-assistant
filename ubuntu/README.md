# Unify Desktop Assistant for Ubuntu/Linux

A Linux application that sets up your machine as a remote-controllable AI assistant workstation. Includes a system tray GUI for easy service management.

## Quick Start

1. Download `unify-desktop-assistant_x.x.x_amd64.deb` from the button below
2. Install:
   ```bash
   sudo apt install ./unify-desktop-assistant_x.x.x_amd64.deb
   ```
3. Enter your Unify API Key when prompted
4. Wait for the installation to complete (might take about 10 minutes)
5. The tray app will start automatically

## Using the Tray App

After installation, the **Unify Desktop Assistant** icon appears in your system tray.

**Right-click the icon for options:**
- **▶ Start Services** - Start all background services
- **■ Stop Services** - Stop all services
- **📋 Copy Public URL** - Copy the tunnel URL to clipboard
- **⚙ Settings** - Configure your API keys, view device/tunnel info
- **📄 View Logs** - Open agent service logs
- **❌ Exit** - Close the tray app

**Status colors:**
- 🟢 Green - All services running
- 🟡 Yellow - Some services running
- 🔴 Red - All services stopped
