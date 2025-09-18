#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/agent-service"
ENV_FILE="$AGENT_DIR/.env"

if [[ ! -d "$AGENT_DIR" ]]; then
  echo "Error: agent-service not found at $AGENT_DIR. Did you run 'unify-desktop-assistant install'?" >&2
  exit 1
fi

touch "$ENV_FILE"

# Print only keys, skip empty lines and comments
awk -F'=' 'BEGIN { OFS="" } /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next } { gsub(/[[:space:]]+$/, "", $1); gsub(/^[[:space:]]+/, "", $1); print $1 }' "$ENV_FILE"


