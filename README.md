# Linux Remote Client

## Installations

### Download Debian Package

1. [Download](https://github.com/unifyai/unify-desktop-assistant/releases/latest/download/unify-desktop-assistant.deb) the `.deb` binary from GitHub.

`https://github.com/unifyai/unify-desktop-assistant/releases/latest/download/unify-desktop-assistant.deb`

2. Locate the download and install the Debian package.

`sudo dpkg -i unify-desktop-assistant.deb`

3. Proceed to local setup for starting the remote client.

### Local Setup

Watch this video for [local setup](https://www.loom.com/share/c3ad55e541634b478f50e0660d4e1017?sid=c1653138-dc7e-476a-b31a-5d4908e2a029).

1. Add the required environment variables, then install the required package

`unify-desktop-assistant add-env UNIFY_BASE_URL https://api.unify.ai/v0`

`unify-desktop-assistant add-env UNIFY_KEY <your-key-value>`

`unify-desktop-assistant add-env ANTHROPIC_API_KEY <your-key-value>`

`unify-desktop-assistant install`

2. Start the remote client app.

`unify-desktop-assistant start "$UNIFY_KEY"`

3. Tunnel the service to HTTPS.

a. For testing

- Start the tunnel. A URL for testing will be provided.

`export UNIFY_BASE_URL=https://api.unify.ai/v0`

`export UNIFY_KEY=<your-key-value>`

`export ANTHROPIC_API_KEY=<your-key-value>`

`unify-desktop-assistant tunnel`

b. For production - WIP

- Login to Cloudflare. This is a one time step.

`cloudflared tunnel login`

- Start the tunnel.

`TUNNEL_HOSTNAME=<prod_hostname> TUNNEL_NAME=<prod_appname> unify-desktop-assistant tunnel`

### Troubleshooting

- Make sure `ANTHROPIC_API_KEY`, `UNIFY_BASE_URL` and `UNIFY_KEY` are in your `.env` file when starting the Docker container.
- When running with Actor, make sure `UNIFY_KEY` and at least `ASSISTANT_EMAIL=unity.agent@unity.ai` are present in your unity `.env` for the magnitude server auth to work.
