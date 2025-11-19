#!/bin/bash
# Build and relaunch macOS Hypo app
# Usage: ./scripts/build-macos.sh [clean]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$PROJECT_ROOT/macos"
APP_BUNDLE="$PROJECT_ROOT/macos/HypoApp.app"
BINARY_NAME="HypoMenuBar"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}ℹ️  $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# Check if we should clean build
if [ "$1" == "clean" ]; then
    log_info "Cleaning build artifacts..."
    cd "$MACOS_DIR"
    swift package clean
    rm -rf .build
    log_success "Clean complete"
fi

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    log_error "App bundle not found at $APP_BUNDLE"
    log_info "Creating app bundle structure..."
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    
    # Create minimal Info.plist if it doesn't exist
    if [ ! -f "$APP_BUNDLE/Contents/Info.plist" ]; then
        cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$BINARY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.hypo.clipboard</string>
    <key>CFBundleName</key>
    <string>Hypo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF
        log_success "Created Info.plist"
    fi
fi

# Build the app
log_info "Building macOS app..."
cd "$MACOS_DIR"

if ! swift build 2>&1 | tee /tmp/hypo_build.log; then
    log_error "Build failed. Check /tmp/hypo_build.log for details"
    exit 1
fi

# Find the built binary (prefer debug, fallback to release)
BUILT_BINARY=$(find "$MACOS_DIR/.build" -name "$BINARY_NAME" -type f | head -1)

if [ -z "$BUILT_BINARY" ]; then
    log_error "Built binary not found in .build directory"
    exit 1
fi

log_success "Build complete: $BUILT_BINARY"

# Verify binary exists and is newer than app bundle (if it exists)
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
if [ -f "$APP_BINARY" ]; then
    BUILT_TIME=$(stat -f "%m" "$BUILT_BINARY" 2>/dev/null || echo "0")
    APP_TIME=$(stat -f "%m" "$APP_BINARY" 2>/dev/null || echo "0")
    
    if [ "$BUILT_TIME" -le "$APP_TIME" ]; then
        log_warn "Built binary is not newer than app bundle binary"
        log_info "Forcing copy to ensure latest code is used..."
    fi
fi

# Copy binary to app bundle (always copy to ensure latest)
log_info "Copying binary to app bundle..."
cp -f "$BUILT_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Verify the copy succeeded and binaries match
if [ -f "$APP_BINARY" ]; then
    BUILT_HASH=$(shasum -a 256 "$BUILT_BINARY" | cut -d' ' -f1)
    APP_HASH=$(shasum -a 256 "$APP_BINARY" | cut -d' ' -f1)
    
    if [ "$BUILT_HASH" = "$APP_HASH" ]; then
        log_success "Binary copied and verified (checksums match)"
    else
        log_error "Binary copy verification failed - checksums do not match!"
        log_error "Built: ${BUILT_HASH:0:16}..."
        log_error "App:   ${APP_HASH:0:16}..."
        exit 1
    fi
else
    log_error "Failed to copy binary to app bundle"
    exit 1
fi

# Kill existing instances
log_info "Stopping existing app instances..."
if killall -9 "$BINARY_NAME" 2>/dev/null; then
    sleep 1
    log_success "Stopped existing instances"
else
    log_info "No existing instances to stop"
fi

# Clear debug log if requested
if [ "$1" == "clean-log" ] || [ "$2" == "clean-log" ]; then
    log_info "Clearing debug log..."
    rm -f /tmp/hypo_debug.log
    log_success "Debug log cleared"
fi

# Launch the app
log_info "Launching app..."
open "$APP_BUNDLE"

# Wait a moment for app to start
sleep 2

# Verify app is running
if pgrep -x "$BINARY_NAME" > /dev/null; then
    log_success "App is running (PID: $(pgrep -x "$BINARY_NAME"))"
    
    # Show recent logs if available
    if [ -f "/tmp/hypo_debug.log" ]; then
        echo ""
        log_info "Recent debug logs:"
        tail -20 /tmp/hypo_debug.log | sed 's/^/  /'
    fi
else
    log_warn "App may not have started. Check Console.app for errors"
fi

echo ""
log_success "Build and launch complete!"
log_info "App bundle: $APP_BUNDLE"
log_info "Debug log: /tmp/hypo_debug.log"

