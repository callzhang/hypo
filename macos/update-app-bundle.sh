#!/bin/bash
# Update HypoApp.app with the latest build

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_PATH="$SCRIPT_DIR/.build/release/HypoMenuBar"
APP_BUNDLE="$SCRIPT_DIR/HypoApp.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/HypoMenuBar"

# Check if build exists
if [ ! -f "$BUILD_PATH" ]; then
    echo "❌ Build not found: $BUILD_PATH"
    echo "   Run: cd $SCRIPT_DIR && swift build -c release"
    exit 1
fi

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ App bundle not found: $APP_BUNDLE"
    exit 1
fi

# Backup old executable
if [ -f "$APP_EXECUTABLE" ]; then
    BACKUP="$APP_EXECUTABLE.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$APP_EXECUTABLE" "$BACKUP"
    echo "📦 Backed up old executable to: $BACKUP"
fi

# Copy new build
cp "$BUILD_PATH" "$APP_EXECUTABLE"
chmod +x "$APP_EXECUTABLE"

echo "✅ Updated HypoApp.app with latest build"
echo ""
echo "Build timestamp: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$BUILD_PATH")"
echo "App bundle timestamp: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$APP_EXECUTABLE")"
