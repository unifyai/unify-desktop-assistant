# Unify Desktop Assistant for macOS

A macOS application that sets up your machine as a remote-controllable AI assistant workstation. Includes a menu bar tray app for easy service management.

## Quick Start

1. Download `unify-desktop-assistant_x.x.x_macos.pkg` from the latest GitHub Release
2. Double-click to install and follow the prompts
3. Enter your Unify API Key when prompted (or click **Skip** to add it later)
4. Approve the Screen Sharing permission prompt when asked
5. Wait for the installation to complete (might take about 10 minutes)
6. The tray app will start automatically

> If you clicked **Skip** in step 3, open the menu-bar icon, choose **Settings…**,
> and enter your API Key there — setup finishes automatically (you'll be asked to
> approve Screen Sharing once).

## Using the Tray App

After installation, the **Unify Desktop Assistant** icon appears in your menu bar.

**Click the icon for options:**
- **▶ Start Services** - Start all background services
- **■ Stop Services** - Stop all services
- **📋 Copy Public URL** - Copy the tunnel URL to clipboard
- **⚙ Settings** - Configure your API keys, view device/tunnel info
- **📄 View Logs** - Open agent service logs
- **❌ Quit** - Close the tray app

**Status colors:**
- 🟢 Green - All services running
- 🟡 Yellow - Some services running
- 🔴 Red - All services stopped
