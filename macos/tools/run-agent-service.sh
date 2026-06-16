#!/usr/bin/env bash
# Launchd entrypoint: Magnitude agent-service (Unity user-desktop control API).
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$TOOLS_DIR")"
AGENT_DIR="$INSTALL_DIR/agent-service"
ENV_FILE="$AGENT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$INSTALL_DIR/browsers}"
cd "$AGENT_DIR"
exec npx -y ts-node src/index.ts
