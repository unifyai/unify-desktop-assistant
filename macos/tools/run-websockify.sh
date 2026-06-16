#!/usr/bin/env bash
# Launchd entrypoint: noVNC proxy for local Screen Sharing (port 6080 → VNC 5900).
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$TOOLS_DIR")"
NOVNC_DIR="$TOOLS_DIR/novnc"
PYTHON_BIN_FILE="$TOOLS_DIR/.python-bin"

if [[ -f "$PYTHON_BIN_FILE" ]]; then
  PYTHON_BIN="$(head -n1 "$PYTHON_BIN_FILE")"
else
  PYTHON_BIN="$(command -v python3 || echo /usr/bin/python3)"
fi

exec "$PYTHON_BIN" -m websockify --web="$NOVNC_DIR" 6080 localhost:5900
