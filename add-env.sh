#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: unify-desktop-assistant add-env <KEY> <VALUE...>" >&2
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

KEY="$1"
shift
VALUE="$*"

# Validate KEY like an environment variable name
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

mkdir -p "$AGENT_DIR"
touch "$ENV_FILE"

# Decide whether to quote the value
SAFE_RE='^[A-Za-z0-9_./:-]+$'
if [[ "$VALUE" =~ $SAFE_RE ]]; then
  OUT_VALUE="$VALUE"
else
  esc="${VALUE//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//\$/\\$}"
  esc="${esc//\`/\\\`}"
  OUT_VALUE="\"$esc\""
fi

NEW_LINE="$KEY=$OUT_VALUE"

# Update or append the key in .env atomically
tmp_file="${ENV_FILE}.tmp$$"
awk -v key="$KEY" -v newline="$NEW_LINE" '
  BEGIN { updated=0 }
  index($0, key"=") == 1 { print newline; updated=1; next }
  { print }
  END { if (!updated) print newline }
' "$ENV_FILE" > "$tmp_file"
mv "$tmp_file" "$ENV_FILE"

echo "Set $KEY in $ENV_FILE"
