# Unify Desktop Assistant for Ubuntu/Linux

A Linux application that sets up your machine as a remote-controllable AI assistant workstation. Includes a system tray GUI for easy service management.

## Quick Start

### Option 1: .deb Installer (Recommended)

1. Download `unify-desktop-assistant_x.x.x_amd64.deb` from [Releases](https://github.com/unifyai/unify-desktop-assistant/releases)
2. Install (resolves all dependencies automatically):
   ```bash
   sudo apt install ./unify-desktop-assistant_x.x.x_amd64.deb
   ```
3. Enter your Unify API Key when prompted
4. The tray app will start automatically on next login

> **Headless VM?** Run `sudo ./tools/start-display.sh` first to create a virtual display, then `export DISPLAY=:0` before running setup.

### Option 2: Run from Source

```bash
# Clone the repo
git clone https://github.com/unifyai/unify-desktop-assistant.git
cd unify-desktop-assistant/ubuntu/tools

# Run setup (requires sudo for dependency installation)
sudo ./setup.sh --unify-key <your-unify-key>
```

## Using the Tray App

After installation, the **Unify Desktop Assistant** icon appears in your system tray.

**Right-click the icon for options:**
- **▶ Start Services** - Start all background services
- **■ Stop Services** - Stop all services
- **🖥 Open Desktop Viewer** - Opens the VNC web viewer
- **🔗 Open Agent API** - Opens the Agent Service endpoint
- **⚙ Settings** - Configure your API keys
- **❌ Exit** - Close the tray app

**Status colors:**
- 🟢 Green - All services running
- 🟡 Yellow - Some services running
- 🔴 Red - All services stopped

## Access URLs

After starting services:

| Service | URL |
|---------|-----|
| Desktop (noVNC) | `http://localhost:6080/custom.html?password=<your-key>` |
| Agent Service API | `http://localhost:3000` |

## What Gets Installed

The installer includes:

- **Magnitude** - Browser automation framework (pre-packaged)
- **Agent Service** - AI agent API service (pre-packaged)

The setup script installs these dependencies on first run:
- **x11vnc** - VNC server (port 5900)
- **noVNC** - Web-based VNC client (port 6080)
- **websockify** - WebSocket to VNC proxy
- **Python 3** - For websockify and tray app
- **Node.js 22** - For agent service
- **Bun** - Package manager for Magnitude
- **GTK/AppIndicator** - For system tray app
- **Playwright + Chromium** - For browser automation

## Configuration

Settings are stored in the agent-service `.env` file:

```
UNIFY_KEY=<your-key>
ORCHESTRA_URL=https://api.unify.ai/v0
UNITY_COMMS_URL=https://unity-comms-app-000000000000.us-central1.run.app
PORT=3000
```

You can configure these via **Settings** in the tray menu, or by re-running:
```bash
sudo dpkg-reconfigure unify-desktop-assistant
```

## Command Line Usage

The CLI wrapper provides convenient access:

```bash
# Full setup and start services
sudo unify-desktop-assistant setup --unify-key <your-key>

# Start services only (no root needed)
unify-desktop-assistant start

# Stop all services
unify-desktop-assistant stop

# Check service status
unify-desktop-assistant status

# Force reinstall dependencies
sudo unify-desktop-assistant setup --unify-key <your-key> --force

# Uninstall cleanup
sudo unify-desktop-assistant uninstall
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Ubuntu Desktop                           │
│                                                              │
│  ┌─────────────────┐   (Tray App)                           │
│  │ unify-assistant  │◀─ Start/Stop/Settings                  │
│  │   (Python/GTK)   │                                        │
│  └─────────────────┘                                        │
│                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌───────────────┐  │
│  │   x11vnc    │────▶│ websockify  │────▶│ noVNC (6080)  │  │
│  │   (5900)    │     │             │     │ HTML5 Viewer  │  │
│  └─────────────┘     └─────────────┘     └───────────────┘  │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │            Agent Service (Express, port 3000)           ││
│  │   ┌───────────────────────────────────────────────────┐ ││
│  │   │  Magnitude BrowserAgent (Playwright + LLM)        │ ││
│  │   └───────────────────────────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Optional: HTTPS Tunnels (Cloudflare)

For remote access without setting up your own domain:

```bash
# Tunnel Agent Service (port 3000)
unify-desktop-assistant tunnel

# Tunnel VNC viewer (port 6080)
unify-desktop-assistant liveview
```

## Building the .deb Package

To build the installer yourself:

```bash
cd ubuntu/installer
./build.sh
```

Options:
```bash
./build.sh --staging        # Build with staging URLs
./build.sh --version 1.2.0  # Custom version
./build.sh --clean          # Clean output first
```

The `.deb` will be created in `ubuntu/installer/output/`.

## Directory Structure

```
ubuntu/
├── agent-service/              # AI agent API (pre-packaged)
│   ├── src/index.ts
│   ├── package.json
│   └── .env                    # Created on setup
├── magnitude/                  # Browser automation (pre-packaged)
│   └── packages/magnitude-core/
├── gui/
│   └── unify-assistant.py      # System tray app (Python/GTK)
├── tools/
│   ├── setup.sh                # Main setup script
│   ├── start-display.sh        # Start virtual display (headless VMs)
│   ├── tunnel.sh               # Cloudflare tunnel (optional)
│   ├── liveview.sh             # Cloudflare VNC tunnel (optional)
│   └── novnc/                  # Cloned on first run
├── systemd/
│   ├── unify-vnc.service       # x11vnc systemd unit
│   ├── unify-websockify.service
│   ├── unify-agent.service
│   └── unify-tray.service
├── installer/
│   ├── build.sh                # Build automation
│   ├── DEBIAN/
│   │   ├── control             # Package metadata
│   │   ├── templates           # debconf templates (API key prompt)
│   │   ├── config              # debconf config script
│   │   ├── postinst            # Post-install script
│   │   ├── prerm               # Pre-removal script
│   │   └── postrm              # Post-removal script
│   └── output/                 # Generated .deb files
├── usr/
│   └── bin/
│       └── unify-desktop-assistant  # CLI wrapper
├── logs/                       # Service log files
└── README.md
```

## Uninstalling

Via package manager:
```bash
sudo apt remove unify-desktop-assistant     # Remove (keep config)
sudo apt purge unify-desktop-assistant      # Remove everything
```

Or via CLI:
```bash
sudo unify-desktop-assistant uninstall
```

## Troubleshooting

### Services Not Starting

Check if ports are already in use:
```bash
ss -tlnp 'sport = :5900 or sport = :6080 or sport = :3000'
```

### View Logs

Service logs are saved to the `logs/` directory:
```bash
# Agent service
cat /opt/unify-desktop-assistant/logs/agent.log

# websockify
cat /opt/unify-desktop-assistant/logs/websockify.log

# x11vnc
cat /opt/unify-desktop-assistant/logs/x11vnc.log
```

Or use **View Logs** from the tray menu.

### Tray Icon Not Showing

Make sure AppIndicator support is installed:
```bash
sudo apt install gir1.2-ayatanaappindicator3-0.1
```

For GNOME, you may also need the AppIndicator extension:
```bash
sudo apt install gnome-shell-extension-appindicator
```

### Manual Service Start

```bash
# Start x11vnc manually
x11vnc -display :0 -nopw -forever -shared -rfbport 5900

# Start websockify manually
python3 -m websockify --web=/opt/unify-desktop-assistant/tools/novnc 6080 localhost:5900

# Start agent service manually
cd /opt/unify-desktop-assistant/agent-service
npx ts-node src/index.ts
```

### Headless VM (No Display)

If x11vnc fails with "XOpenDisplay failed", you need a virtual display:
```bash
sudo ./tools/start-display.sh         # Start Xvfb + Fluxbox on :0
export DISPLAY=:0
sudo -E ./tools/setup.sh --unify-key "your-key"
```

To stop the virtual display later:
```bash
sudo ./tools/start-display.sh --stop
```

### Reconfigure API Key

```bash
sudo dpkg-reconfigure unify-desktop-assistant
```
