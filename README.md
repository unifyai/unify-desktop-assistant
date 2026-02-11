# Unify Desktop Assistant for Windows

A Windows application that sets up your machine as a remote-controllable AI assistant workstation. Includes a system tray GUI for easy service management.

## Quick Start

### Option 1: Windows Installer (Recommended)

1. Download `UnifyDesktopAssistant-Setup-x.x.x.exe` from [Releases](https://github.com/unifyai/unify-desktop-assistant/releases)
2. Run the installer
3. Enter your Unify API Key when prompted
4. The tray app will start automatically

### Option 2: Run from Source

```powershell
# Clone the repo (PowerShell as Administrator)
git clone https://github.com/unifyai/unify-desktop-assistant.git
cd unify-desktop-assistant/unify-desktop-assistant/tools

# Run setup
.\setup.ps1 -UnifyKey <your-unify-key>
```

## Using the Tray App

After installation, the **Unify Desktop Assistant** icon appears in your system tray.

**Right-click the icon for options:**
- **▶ Start Services** - Start all background services
- **■ Stop Services** - Stop all services
- **🖥 Open Desktop Viewer** - Opens the VNC web viewer
- **🔗 Open API** - Opens the Agent Service endpoint
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
- **TightVNC** - VNC server (port 5900)
- **noVNC** - Web-based VNC client (port 6080)
- **websockify** - WebSocket to VNC proxy
- **Python 3.12** - For websockify
- **Node.js LTS** - For agent service
- **Chocolatey** - Package manager
- **Git** - For cloning noVNC

## Configuration

Settings are stored in two places:

**Agent Service (.env):**
```
UNIFY_KEY=<your-key>
ORCHESTRA_URL=https://api.unify.ai/v0
```

**GUI Settings (settings.json):**
```json
{"AutoStartServices": false}
```

Both can be configured via **Settings** in the tray menu.

## Command Line Usage

The setup script can also be run directly:

```powershell
# Setup and start services
.\tools\setup.ps1 -UnifyKey <your-key>

# With custom Orchestra URL
.\tools\setup.ps1 -UnifyKey <your-key> -OrchestraUrl https://api.unify.ai/v0

# Stop all services
.\tools\setup.ps1 -Stop

# Force reinstall dependencies
.\tools\setup.ps1 -UnifyKey <your-key> -Force
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Windows Desktop                          │
│                                                              │
│  ┌─────────────────┐   (Tray App)                           │
│  │ UnifyAssistant  │◀─ Start/Stop/Settings                  │
│  └─────────────────┘                                        │
│                                                              │
│  ┌─────────────┐     ┌─────────────┐     ┌───────────────┐  │
│  │  TightVNC   │────▶│ websockify  │────▶│ noVNC (6080)  │  │
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

```powershell
# Tunnel Agent Service (port 3000)
.\tools\tunnel.ps1

# Tunnel VNC viewer (port 6080)
.\tools\liveview.ps1
```

## Building the Installer

To build the installer yourself:

```powershell
# Install Inno Setup
choco install innosetup -y

# Build
cd unify-desktop-assistant/installer
.\build.ps1
```

The installer will be created in `installer/output/`.

## Directory Structure

```
unify-desktop-assistant/
├── agent-service/          # AI agent API (pre-packaged)
│   ├── src/index.ts
│   ├── package.json
│   └── .env               # Created on setup
├── magnitude/              # Browser automation (pre-packaged)
│   └── packages/magnitude-core/
├── gui/
│   └── UnifyAssistant.ps1  # Tray app
├── tools/
│   ├── setup.ps1           # Main setup script
│   ├── tunnel.ps1          # Cloudflare tunnel (optional)
│   ├── liveview.ps1        # Cloudflare VNC tunnel (optional)
│   └── novnc/              # Cloned on first run
└── installer/
    ├── setup.iss           # Inno Setup script
    ├── build.ps1           # Build automation
    └── output/             # Generated installers
```

## Troubleshooting

### TightVNC Password

The VNC password is automatically set to your **Unify API Key** during installation. No manual configuration is needed.

If you need to change the password manually:
```powershell
& 'C:\Program Files\TightVNC\tvnserver.exe' -configapp
```

### Services Not Starting

Check if ports are already in use:
```powershell
Get-NetTCPConnection -LocalPort 5900,6080,3000 -State Listen
```

### View Logs

Agent service logs are saved to:
```
agent-service\agent.log
```

Or use **View Logs** from the tray menu.

### Manual Service Start

```powershell
# Start websockify manually
cd tools\novnc
.\start-websockify.bat

# Start agent service manually
cd agent-service
npx ts-node src/index.ts
```
