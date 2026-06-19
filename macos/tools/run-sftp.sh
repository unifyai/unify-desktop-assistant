#!/usr/bin/env bash
# Launchd entrypoint: app-owned SFTP server (rclone serve sftp) for Unify Desktop
# Assistant. Serves the user's $HOME, pubkey-only auth (authorized_keys synced
# from Orchestra), bound per-mode (cloud=127.0.0.1 behind the rathole tunnel,
# self-host=0.0.0.0 so the local Unity stack can reach it).
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$TOOLS_DIR")"
RCLONE_BIN="$INSTALL_DIR/rclone/rclone"
SSH_DIR="$INSTALL_DIR/ssh"
ENV_FILE="$INSTALL_DIR/agent-service/.env"

get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | sed "s/^$1=//"; }

# The SFTP username is a fixed contract with the cloud-side rclone client (unity
# CM dials user "unity"); it is NOT the local OS account.
bind_addr="$(get_env SFTP_BIND_ADDR)";   [[ -z "$bind_addr" ]] && bind_addr="127.0.0.1"
sftp_user="$(get_env SFTP_USER)";        [[ -z "$sftp_user" ]] && sftp_user="unity"
sftp_port="$(get_env SFTP_LOCAL_PORT)";  [[ -z "$sftp_port" ]] && sftp_port="2222"

exec "$RCLONE_BIN" serve sftp "$HOME" \
  --addr "${bind_addr}:${sftp_port}" \
  --user "$sftp_user" \
  --authorized-keys "$SSH_DIR/authorized_keys" \
  --key "$SSH_DIR/host_ed25519"
