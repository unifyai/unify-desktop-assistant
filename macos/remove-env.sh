#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: unify-desktop-assistant remove-env <KEY>" >&2
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

KEY="$1"

if [[ ! "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Error: KEY must match [A-Za-z_][A-Za-z0-9_]*" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/agent-service"
ENV_FILE="$AGENT_DIR/.env"

if [[ ! -d "$AGENT_DIR" ]]; then
  echo "Error: agent-service not found at $AGENT_DIR. Did you run 'unify-desktop-assistant install'?" >&2
  exit 1
fi

touch "$ENV_FILE"

tmp_file="${ENV_FILE}.tmp$$"
awk -v key="$KEY" 'index($0, key"=") == 1 { next } { print }' "$ENV_FILE" > "$tmp_file"
mv "$tmp_file" "$ENV_FILE"

echo "Removed $KEY from $ENV_FILE"


