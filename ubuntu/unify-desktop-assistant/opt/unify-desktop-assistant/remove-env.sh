#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/agent-service/.env"

KEY="${1:-}"

if [[ -z "$KEY" ]]; then
  echo "Usage: remove-env <KEY>" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  exit 0
fi

tmpfile="$(mktemp)"
grep -vE "^${KEY}=" "$ENV_FILE" > "$tmpfile" || true
mv "$tmpfile" "$ENV_FILE"

echo "Removed $KEY from $ENV_FILE (if present)"

# Remove from environment
unset "$KEY"
echo "Unset $KEY from environment"
