# Linux Remote Client

## Installations

### Download Debian Package

TODO

### Local Setup

1. Add the required environment variables, then install the required package

`unify-desktop-assistant add-env UNIFY_BASE_URL https://api.unify.ai/v0`

`unify-desktop-assistant add-env UNIFY_KEY <your-key-value>`

`unify-desktop-assistant add-env ANTHROPIC_API_KEY <your-key-value> `

`unify-desktop-assistant install`

2. Start the remote client app.

`unify-desktop-assistant start "$UNIFY_KEY"`

3. Tunnel the service to HTTPS.

a. For testing

- Start the tunnel. A URL for testing will be provided.

`unify-desktop-assistant tunnel`

b. For production - WIP

- Login to Cloudflare. This is a one time step.

`cloudflared tunnel login`

- Start the tunnel.

`TUNNEL_HOSTNAME=<prod_hostname> TUNNEL_NAME=<prod_appname> unify-desktop-assistant tunnel`

### Troubleshooting

- Make sure `ANTHROPIC_API_KEY`, `UNIFY_BASE_URL` and `UNIFY_KEY` are in your `.env` file when starting the Docker container.
- When running with Actor, make sure `UNIFY_KEY` and at least `ASSISTANT_EMAIL=unity.agent@unity.ai` are present in your unity `.env` for the magnitude server auth to work.
