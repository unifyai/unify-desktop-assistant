# Unify Desktop Assistant for Windows

A CLI tool to set up a Windows machine as a remote-controllable AI assistant workstation.

## Quick Start

### Prerequisites

- Windows 10/11 or Windows Server
- PowerShell (Run as Administrator)

### Option 1: Install via Chocolatey Package

```powershell
# Download the package
Invoke-WebRequest -Uri "https://github.com/unifyai/unify-desktop-assistant/releases/latest/download/unify-desktop-assistant.nupkg" -OutFile "unify-desktop-assistant.nupkg"

# Install
choco install unify-desktop-assistant -y -s . --force
refreshenv

# Setup and start (single command)
unify-desktop-assistant setup -UnifyKey <your-unify-key>
```

### Option 2: Run Directly from Source

```powershell
# Clone the repo
git clone https://github.com/unifyai/unify-desktop-assistant.git
cd unify-desktop-assistant/unify-desktop-assistant/tools

# Run setup
.\setup.ps1 -UnifyKey <your-unify-key>
```

## Usage

### Setup & Start Services

```powershell
# Install everything and start services
unify-desktop-assistant setup -UnifyKey <your-key>

# With custom Orchestra URL
unify-desktop-assistant setup -UnifyKey <your-key> -OrchestraUrl https://api.unify.ai/v0

# Force reinstall (bypasses fast mode)
unify-desktop-assistant setup -UnifyKey <your-key> -Force
```

### Stop Services

```powershell
unify-desktop-assistant stop
```

### Access URLs (Localhost)

After setup completes:

| Service | URL |
|---------|-----|
| Desktop (noVNC) | `http://localhost:6080/custom.html?password=<your-key>` |
| Agent Service API | `http://localhost:3000` |

## What Gets Installed

The `setup` command automatically installs and configures:

- **Chocolatey** - Package manager
- **Git** - For cloning repositories
- **Python 3.12** - For websockify
- **Node.js LTS** - For agent service
- **Bun** - For faster builds (optional)
- **TightVNC** - VNC server (port 5900)
- **noVNC** - Web-based VNC client (port 6080)
- **websockify** - WebSocket to VNC proxy
- **Magnitude** - Browser automation framework
- **Agent Service** - AI agent API service (port 3000)

## Configuration

The setup script creates a minimal `.env` file in `agent-service/`:

```
UNIFY_KEY=<your-key>
ORCHESTRA_URL=https://api.unify.ai/v0
```

## Services Auto-Start

The setup creates Windows scheduled tasks for auto-start on logon:
- `UnifyWebsockify` - Starts websockify
- `UnifyAgentService` - Starts agent service

## Optional: HTTPS Tunnels (Cloudflare)

For remote access without setting up your own domain:

```powershell
# Tunnel Agent Service (port 3000)
unify-desktop-assistant tunnel

# Tunnel VNC viewer (port 6080)
unify-desktop-assistant liveview
```

Access via the Cloudflare URL provided.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Windows Desktop                          │
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

## Troubleshooting

### TightVNC Password

When first installing TightVNC, a configuration dialog appears. Set the primary password to your Unify API key.

### Services Not Starting

Check if ports are already in use:
```powershell
Get-NetTCPConnection -LocalPort 5900,6080,3000 -State Listen
```

### View Logs

Agent service logs are saved to:
```
tools\agent-service\agent.log
```

### Manual Service Start

```powershell
# Start websockify manually
cd tools\novnc
.\start-websockify.bat

# Start agent service manually
cd tools\agent-service
npx ts-node src/index.ts
```

## Legacy Commands (Deprecated)

These commands still work but are superseded by `setup`:

```powershell
unify-desktop-assistant install    # Use 'setup' instead
unify-desktop-assistant start      # Use 'setup' instead
unify-desktop-assistant add-env    # Use 'setup -UnifyKey' instead
```
