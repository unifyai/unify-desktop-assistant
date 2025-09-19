# Windows Remote Client

### Prerequisites

1. PowerShell

2. Chocolatey

`winget install --id=Chocolatey.Chocolatey -e`

3. Git

`winget install --id=Git.Git -e --source winget`

4. Python 3 (for websockify)

`winget install --id=Python.Python.3 -e`

### Setup

Watch this video for [local setup](https://www.loom.com/share/61a230c7d7314a109e3fc64061d8e315?sid=b80b1f19-c080-4431-a667-6ee1a0c350f1).

1. Install the required package through PowerShell in "Run as Administrator" mode.

`unify-desktop-assistant add-env UNIFY_BASE_URL https://api.unify.ai/v0`

`unify-desktop-assistant add-env UNIFY_KEY <your-key-value>`

`unify-desktop-assistant add-env ANTHROPIC_API_KEY <your-key-value>`

`unify-desktop-assistant install`

- When prompted by a TightVNC popup window, set/change primary password to your Unify API key.

2. Start the remote client app.

`unify-desktop-assistant start`

3. Tunnel the service to HTTPS.

a. For testing

- Start the tunnel. A URL for testing will be provided.

`unify-desktop-assistant tunnel`

b. For production - WIP

- Login to Cloudflare. This is a one time step.

`cloudflared tunnel login`

- Start the tunnel - TODO

`unify-desktop-assistant tunnel -Hostname your.domain.com -TunnelName myapp -LocalPort 6080`

### Live Remote Viewing and Controls

1. Tunnel the remote view.

`unify-desktop-assistant liveview`

2. View and control the desktop through the URL below. When prompted for password, input your Unify API key.

`<cloudflared-url>/vnc.html?resize=scale&autoreconnect=1&autoconnect=1`

### Troubleshooting

- Make sure `ANTHROPIC_API_KEY`, `UNIFY_BASE_URL` and `UNIFY_KEY` are in your `.env` file when starting the Docker container.
- When running with Actor, make sure `UNIFY_KEY` and at least `ASSISTANT_EMAIL=unity.agent@unity.ai` are present in your unity `.env` for the magnitude server auth to work.
