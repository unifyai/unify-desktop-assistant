# Linux Remote Client

### Setup

1. Install the required package

`bash install.sh`

2. Start the remote client app.

`bash remote.sh $UNIFY_KEY`

3. Tunnel the service to HTTPS.

a. For testing

- Start the tunnel. A URL for testing will be provided.

`bash tunnel.sh`

b. For production - WIP

- Login to Cloudflare. This is a one time step.

`cloudflared tunnel login`

- Start the tunnel.

`TUNNEL_HOSTNAME=<prod_hostname> TUNNEL_NAME=<prod_appname> bash tunnel.sh`

### Troubleshooting

- Make sure `ANTHROPIC_API_KEY`, `UNIFY_BASE_URL` and `UNIFY_KEY` are in your `.env` file when starting the Docker container.
- When running with Actor, make sure `UNIFY_KEY` and at least `ASSISTANT_EMAIL=unity.agent@unity.ai` are present in your unity `.env` for the magnitude server auth to work.

## Debian package (.deb)

You can build a `.deb` that installs this client under `/opt/unify-desktop-assistant` and exposes a single CLI: `unify-desktop-assistant` with subcommands.

### Build (on Ubuntu/Debian)

```bash
sudo apt-get update && sudo apt-get install -y dpkg-dev
bash packaging/deb/build.sh
```

This produces `packaging/deb/unify-desktop-assistant_<version>_amd64.deb`.

### Install

```bash
cd packaging/deb
sudo apt install -y ./unify-desktop-assistant_*_amd64.deb
```

### CLI usage

```bash
unify-desktop-assistant install             # downloads and installs dependencies
unify-desktop-assistant start "$UNIFY_KEY" # starts the remote client app
unify-desktop-assistant tunnel              # starts HTTPS tunnel for the agent service (port 3000)
unify-desktop-assistant liveview            # starts HTTPS tunnel for live viewing (port 6080)
```

Notes:
- The `install` subcommand installs prerequisites (Node via NodeSource, x11vnc, websockify, noVNC, etc.).
- `start` serves the current X display via VNC at `http://localhost:6080/vnc.html` and starts the agent service.
- `tunnel` exposes the agent service over HTTPS via Cloudflare Tunnel (ad‑hoc URL by default).
- `liveview` exposes the live VNC view over HTTPS via Cloudflare Tunnel (ad‑hoc URL by default).
