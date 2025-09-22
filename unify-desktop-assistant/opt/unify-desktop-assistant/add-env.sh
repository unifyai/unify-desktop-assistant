#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/agent-service/.env"

KEY="${1:-}"
shift || true
VALUE="$*"

if [[ -z "$KEY" || -z "$VALUE" ]]; then
  echo "Usage: add-env <KEY> <VALUE...>" >&2
  exit 1
fi

mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"

# Remove any existing key (match start-of-line KEY=)
if grep -qE "^${KEY}=" "$ENV_FILE"; then
  tmpfile="$(mktemp)"
  grep -vE "^${KEY}=" "$ENV_FILE" > "$tmpfile"
  mv "$tmpfile" "$ENV_FILE"
fi

# Append new entry, shell-escape VALUE so sourcing works (handles spaces, quotes)
printf "%s=%q\n" "$KEY" "$VALUE" >> "$ENV_FILE"
echo "Saved $KEY to $ENV_FILE"

# Export to current environment for this process and its children
export "$KEY=$VALUE"
echo "Exported $KEY to environment"
