#!/usr/bin/env bash
# build.sh - Build Unify Desktop Assistant .deb Package
#
# This script assembles the .deb package for Unify Desktop Assistant.
# It packages pre-built magnitude and agent-service alongside the tools,
# GUI, systemd units, and DEBIAN maintainer scripts.
#
# Usage:
#   ./build.sh                  # Build .deb (production URLs)
#   ./build.sh --staging        # Build .deb (staging URLs)
#   ./build.sh --version 1.2.0  # Build with custom version
#   ./build.sh --clean          # Clean output before building

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$SCRIPT_DIR/output"
BUILD_DIR="$SCRIPT_DIR/build"

# Defaults
VERSION=""
STAGING=false
CLEAN=false
ENVIRONMENT="main"

# Environment-specific URLs
ORCHESTRA_URL_MAIN="https://api.unify.ai/v0"
ORCHESTRA_URL_STAGING="https://internal.example.com/v0"
COMMS_URL_MAIN="https://unity-comms-app-000000000000.us-central1.run.app"
COMMS_URL_STAGING="https://unity-comms-app-staging-000000000000.us-central1.run.app"

echo ""
echo "=========================================="
echo "  Unify Desktop Assistant - Build .deb"
echo "=========================================="
echo ""

# =============================================================================
# Argument Parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"; shift 2 ;;
        --staging)
            STAGING=true; ENVIRONMENT="staging"; shift ;;
        --clean)
            CLEAN=true; shift ;;
        -h|--help)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --version VER   Set package version (default: from control file)"
            echo "  --staging       Build with staging URLs"
            echo "  --clean         Clean output before building"
            echo "  -h, --help      Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Clean
# =============================================================================

if $CLEAN; then
    echo "Cleaning build directories..."
    rm -rf "$OUTPUT_DIR" "$BUILD_DIR"
    echo "  Cleaned"
fi

# =============================================================================
# Validate Prerequisites
# =============================================================================

echo "Checking prerequisites..."

# Check for dpkg-deb
if ! command -v dpkg-deb &>/dev/null; then
    echo "ERROR: dpkg-deb not found. Install dpkg or run on a Debian/Ubuntu system." >&2
    echo "  On macOS: brew install dpkg" >&2
    exit 1
fi

# Check that magnitude and agent-service exist
if [[ ! -f "$PROJECT_DIR/magnitude/package.json" ]]; then
    echo "ERROR: magnitude/package.json not found at $PROJECT_DIR/magnitude/" >&2
    echo "  Make sure magnitude is checked out in the ubuntu/ directory." >&2
    exit 1
fi

if [[ ! -f "$PROJECT_DIR/agent-service/package.json" ]]; then
    echo "ERROR: agent-service/package.json not found at $PROJECT_DIR/agent-service/" >&2
    exit 1
fi

echo "  Prerequisites OK"

# =============================================================================
# Prepare Build Tree
# =============================================================================

echo "Preparing build tree..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/DEBIAN"
mkdir -p "$BUILD_DIR/opt/unify-desktop-assistant"
mkdir -p "$BUILD_DIR/usr/bin"

APP_ROOT="$BUILD_DIR/opt/unify-desktop-assistant"

# --- DEBIAN maintainer scripts ---
cp "$SCRIPT_DIR/DEBIAN/control" "$BUILD_DIR/DEBIAN/control"
cp "$SCRIPT_DIR/DEBIAN/templates" "$BUILD_DIR/DEBIAN/templates"
cp "$SCRIPT_DIR/DEBIAN/config" "$BUILD_DIR/DEBIAN/config"
cp "$SCRIPT_DIR/DEBIAN/postinst" "$BUILD_DIR/DEBIAN/postinst"
cp "$SCRIPT_DIR/DEBIAN/prerm" "$BUILD_DIR/DEBIAN/prerm"
cp "$SCRIPT_DIR/DEBIAN/postrm" "$BUILD_DIR/DEBIAN/postrm"

chmod 755 "$BUILD_DIR/DEBIAN/config"
chmod 755 "$BUILD_DIR/DEBIAN/postinst"
chmod 755 "$BUILD_DIR/DEBIAN/prerm"
chmod 755 "$BUILD_DIR/DEBIAN/postrm"

# --- Version override ---
if [[ -n "$VERSION" ]]; then
    sed -i.bak "s/^Version:.*/Version: $VERSION/" "$BUILD_DIR/DEBIAN/control"
    rm -f "$BUILD_DIR/DEBIAN/control.bak"
    echo "  Version: $VERSION"
else
    VERSION=$(grep -oP '^Version:\s*\K.*' "$BUILD_DIR/DEBIAN/control")
    echo "  Version: $VERSION (from control)"
fi

# --- Environment-specific URL baking ---
if $STAGING; then
    ORCHESTRA_URL="$ORCHESTRA_URL_STAGING"
    COMMS_URL="$COMMS_URL_STAGING"
    echo "  Environment: staging"
else
    ORCHESTRA_URL="$ORCHESTRA_URL_MAIN"
    COMMS_URL="$COMMS_URL_MAIN"
    echo "  Environment: main (production)"
fi

# Bake URLs into environment.conf (not user-editable, determined by main/staging build)
cat > "$APP_ROOT/environment.conf" <<EOF
# Auto-generated by build.sh — do not edit
# Environment: $ENVIRONMENT
ORCHESTRA_URL=$ORCHESTRA_URL
UNITY_COMMS_URL=$COMMS_URL
EOF
echo "  Baked environment.conf ($ENVIRONMENT)"

# --- tools/ ---
echo "  Copying tools/..."
mkdir -p "$APP_ROOT/tools"
cp "$PROJECT_DIR/tools/setup.sh" "$APP_ROOT/tools/"
chmod +x "$APP_ROOT/tools/setup.sh"

# Copy tunnel and liveview scripts if they exist in new location
for script in tunnel.sh liveview.sh; do
    if [[ -f "$PROJECT_DIR/tools/$script" ]]; then
        cp "$PROJECT_DIR/tools/$script" "$APP_ROOT/tools/"
        chmod +x "$APP_ROOT/tools/$script"
    fi
done

# --- gui/ ---
echo "  Copying gui/..."
mkdir -p "$APP_ROOT/gui"
if [[ -f "$PROJECT_DIR/gui/unify-assistant.py" ]]; then
    cp "$PROJECT_DIR/gui/unify-assistant.py" "$APP_ROOT/gui/"
    chmod +x "$APP_ROOT/gui/unify-assistant.py"
fi

# --- assets/ (tray icon / logo) ---
echo "  Copying assets..."
if [[ -d "$PROJECT_DIR/assets" ]]; then
    mkdir -p "$APP_ROOT/assets"
    cp "$PROJECT_DIR/assets/"* "$APP_ROOT/assets/" 2>/dev/null || true
fi

# --- systemd/ ---
echo "  Copying systemd units..."
mkdir -p "$APP_ROOT/systemd"
cp "$PROJECT_DIR/systemd/"*.service "$APP_ROOT/systemd/" 2>/dev/null || true
cp "$PROJECT_DIR/systemd/"*.timer "$APP_ROOT/systemd/" 2>/dev/null || true

# --- magnitude/ (excluding node_modules, .git) ---
echo "  Copying magnitude/ (excluding node_modules, .git)..."
mkdir -p "$APP_ROOT/magnitude"
tar -C "$PROJECT_DIR/magnitude" \
    --exclude='node_modules' --exclude='.git' --exclude='*.log' \
    -cf - . | tar -C "$APP_ROOT/magnitude" -xf -

# --- agent-service/ (excluding node_modules, .git, .env, logs) ---
echo "  Copying agent-service/ (excluding node_modules, .git, .env, logs)..."
mkdir -p "$APP_ROOT/agent-service"
tar -C "$PROJECT_DIR/agent-service" \
    --exclude='node_modules' --exclude='.git' --exclude='.env' --exclude='*.log' \
    -cf - . | tar -C "$APP_ROOT/agent-service" -xf -

# --- logs/ directory ---
mkdir -p "$APP_ROOT/logs"

# --- CLI wrapper ---
echo "  Installing CLI wrapper..."
cp "$PROJECT_DIR/usr/bin/unify-desktop-assistant" "$BUILD_DIR/usr/bin/unify-desktop-assistant"
chmod 755 "$BUILD_DIR/usr/bin/unify-desktop-assistant"

# --- Set permissions ---
echo "  Setting permissions..."
find "$BUILD_DIR" -type d -exec chmod 755 {} \;
find "$APP_ROOT" -name "*.sh" -exec chmod 755 {} \;
find "$APP_ROOT" -name "*.py" -exec chmod 755 {} \;

# =============================================================================
# Build .deb Package
# =============================================================================

echo ""
echo "Building .deb package..."

mkdir -p "$OUTPUT_DIR"

ENV_SUFFIX=""
if $STAGING; then
    ENV_SUFFIX="-staging"
fi

DEB_FILENAME="unify-desktop-assistant_${VERSION}${ENV_SUFFIX}_amd64.deb"

dpkg-deb --build --root-owner-group "$BUILD_DIR" "$OUTPUT_DIR/$DEB_FILENAME"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "Build complete!"
echo ""
echo "Output files:"
DEB_SIZE=$(du -sh "$OUTPUT_DIR/$DEB_FILENAME" 2>/dev/null | cut -f1)
echo "  $DEB_FILENAME ($DEB_SIZE)"
echo ""
echo "Install with:"
echo "  sudo apt install $OUTPUT_DIR/$DEB_FILENAME"
echo ""

# Cleanup build directory
rm -rf "$BUILD_DIR"
echo "Build tree cleaned up."
