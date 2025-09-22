#!/usr/bin/env bash
set -euo pipefail

# Ensure we run from the directory of this script
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

# Install runtime dependencies used by linux.sh (x11vnc and websockify) and tools to fetch noVNC
apt-get update
apt-get install -y \
  x11vnc \
  websockify \
  wget \
  unzip \
  curl \
  git \
  ca-certificates \
  gnupg

mkdir -p /opt/novnc && \
  wget https://github.com/novnc/noVNC/archive/refs/heads/master.zip && \
  unzip master.zip && \
  mv noVNC-master/* /opt/novnc && \
  rm -rf master.zip noVNC-master

# Install Node.js 22.x (NodeSource) and project dependencies
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

npm install -g turbo bun

# Link local magnitude (Unity fork) before installing agent-service deps
MAG_DIR="$BASE_DIR/magnitude"
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

# echo "Installing dependencies and building magnitude-core with Bun..."
pushd "$MAG_DIR/packages/magnitude-core" >/dev/null
bun install
npm run build
popd >/dev/null

# Install global TypeScript runner and Node deps for agent-service
cd "$BASE_DIR/agent-service"

# Prefer clean, lockfile-resolved install if lockfile exists
npm install -g ts-node typescript
npm install
