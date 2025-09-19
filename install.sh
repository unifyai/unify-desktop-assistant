#!/usr/bin/env bash
set -euo pipefail

# Install websockify via Python pip (assumes Python is installed)
if command -v python3 >/dev/null 2>&1; then
PY=python3
elif command -v python >/dev/null 2>&1; then
PY=python
else
echo "Error: Python is not installed (python3/python)." >&2
exit 1
fi

echo "Installing/Upgrading websockify via pip..."
if ! $PY -m pip install --upgrade --user websockify 2>/dev/null; then
  sudo $PY -m pip install --upgrade websockify
fi

# Ensure websockify is reachable
if ! command -v websockify >/dev/null 2>&1; then
USER_BASE=$($PY -m site --user-base 2>/dev/null || echo "")
if [ -n "$USER_BASE" ] && [ -x "$USER_BASE/bin/websockify" ]; then
  echo "websockify installed at $USER_BASE/bin/websockify. Consider adding it to your PATH."
else
  echo "Warning: websockify not found on PATH. Ensure your pip bin directory is in PATH." >&2
fi
fi

# Fetch noVNC via git into /opt/novnc (assumes git is installed)
echo "Fetching noVNC into /opt/novnc..."
sudo mkdir -p /opt
if [ -d "/opt/novnc/.git" ]; then
  sudo git -C /opt/novnc fetch --depth=1 origin || true
  # Try common default branches
  if sudo git -C /opt/novnc rev-parse --verify origin/master >/dev/null 2>&1; then
    sudo git -C /opt/novnc reset --hard origin/master
  elif sudo git -C /opt/novnc rev-parse --verify origin/main >/dev/null 2>&1; then
    sudo git -C /opt/novnc reset --hard origin/main
  fi
else
  sudo rm -rf /opt/novnc
  sudo git clone --depth 1 https://github.com/novnc/noVNC.git /opt/novnc
fi

sudo chmod -R a+rX /opt/novnc

echo "mac install: websockify (pip) and noVNC (git) installed. Web root at /opt/novnc."

# Install Node-based tooling and agent-service dependencies (assumes Node/npm installed)
if ! command -v npm >/dev/null 2>&1; then
  echo "Error: npm not found on PATH. Please install Node.js (includes npm)." >&2
  exit 1
fi

echo "Installing global TypeScript tooling (ts-node, typescript)..."
npm install -g ts-node typescript

echo "Installing agent-service npm dependencies..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/agent-service"
if [ ! -d "$AGENT_DIR" ]; then
  echo "Error: agent-service not found at $AGENT_DIR" >&2
  exit 1
fi

# --- Link local magnitude (Unity fork) before installing agent-service deps ---
MAG_DIR="$SCRIPT_DIR/magnitude"
if [ ! -d "$MAG_DIR" ]; then
  echo "Cloning unifyai/magnitude into $MAG_DIR ..."
  git clone https://github.com/unifyai/magnitude.git "$MAG_DIR"
fi

echo "Switching unifyai/magnitude to 'unity-modifications' branch..."
pushd "$MAG_DIR" >/dev/null
git fetch origin unity-modifications || true
if git rev-parse --verify origin/unity-modifications >/dev/null 2>&1; then
  git checkout -B unity-modifications origin/unity-modifications
else
  git checkout unity-modifications || true
fi
popd >/dev/null

# Ensure Bun is installed for building magnitude-core
if command -v bun >/dev/null 2>&1; then
  BUN_BIN="$(command -v bun)"
else
  echo "Installing Bun (https://bun.sh) ..."
  curl -fsSL https://bun.sh/install | bash
  if [ -x "$HOME/.bun/bin/bun" ]; then
    BUN_BIN="$HOME/.bun/bin/bun"
  else
    BUN_BIN="bun"
  fi
fi

echo "Installing dependencies and building magnitude-core with Bun..."
pushd "$MAG_DIR/packages/magnitude-core" >/dev/null
"$BUN_BIN" install
npm run build
popd >/dev/null
pushd "$AGENT_DIR" >/dev/null
npm install

npx playwright@1.52.0 install --with-deps chromium
popd >/dev/null
