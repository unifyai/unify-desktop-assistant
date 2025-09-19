#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$BASE_DIR/agent-service/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  exit 0
fi

# Print only keys (before the equals), ignoring blank lines and comments
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | sed -E 's/=.*$//' | sort -u


