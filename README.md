# Unity Assistant Desktop Remote Client

## Prerequisites

1. Homebrew

`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

## Installations

### Download Homebrew Package

1. Install the CLI tool.

`brew install --HEAD unifyai/unifyai/unify-desktop-assistant`

2. Proceed to local setup.

### Local Setup

Watch this video for [local setup](https://www.loom.com/share/c6db63fa38d54ed8ac9591dec5ab1d8a?sid=ee5d12ed-3106-41fd-9f24-5ffd70a50fba).

1. Add the required environment variables.

`unify-desktop-assistant add-env UNIFY_BASE_URL https://api.unify.ai/v0`

`unify-desktop-assistant add-env UNIFY_KEY <your-key-value>`

`unify-desktop-assistant add-env ANTHROPIC_API_KEY <your-key-value>`

`unify-desktop-assistant add-env ASSISTANT_NAME <first> <last>`

```bash
set -a
source "$(brew --prefix unifyai/unifyai/unify-desktop-assistant)/libexec/agent-service/.env"
set +a
```

2. Install the required dependencies.

`unify-desktop-assistant install`

3. Create a user profile for the agent with the following details:

Username: `<AGENT_NAME_FIRST_LAST>`

Password: `<UNIFY_KEY>`

4. Start the remote client app.

`unify-desktop-assistant start`

5. Tunnel the service to HTTPS.

a. For testing

- Start the tunnel. A URL for testing will be provided.

`unify-desktop-assistant tunnel`

b. For production - WIP

- Login to Cloudflare. This is a one time step.

`cloudflared tunnel login`

- Start the tunnel.

`TUNNEL_HOSTNAME=<prod_hostname> TUNNEL_NAME=<prod_appname> unify-desktop-assistant tunnel`

### Live Remote Viewing and Controls

1. Tunnel the remote view.

`unify-desktop-assistant liveview`

2. View and control the desktop through the URL below. When prompted for username and password, use the details above.

`<cloudflared-url>/vnc.html?resize=scale&autoreconnect=1&autoconnect=1`

### Troubleshooting

- Make sure `ANTHROPIC_API_KEY`, `UNIFY_BASE_URL` and `UNIFY_KEY` are in your `.env` file when starting the service.
- When running with Actor, make sure `UNIFY_KEY` and at least `ASSISTANT_EMAIL=unity.agent@unity.ai` are present in your unity `.env` for the magnitude server auth to work.
