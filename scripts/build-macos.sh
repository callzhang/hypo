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
    <string>4</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.3</string>
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

# Check for corrupted package checkouts and fix them
if [ -d ".build/checkouts" ]; then
    # Check if any checkout directory is missing critical files
    CORRUPTED=0
    for checkout in .build/checkouts/*; do
        if [ -d "$checkout" ] && [ ! -f "$checkout/Package.swift" ] && [ ! -d "$checkout/Sources" ]; then
            CORRUPTED=1
            break
        fi
    done
    
    if [ "$CORRUPTED" -eq 1 ]; then
        log_warn "Detected corrupted package checkouts, resetting..."
        swift package reset 2>/dev/null || rm -rf .build/checkouts
        log_success "Package checkouts reset"
    fi
fi

# Check if we need to force a rebuild
# Swift Package Manager should detect changes, but we can help by checking timestamps
FORCE_REBUILD=false
if [ -d ".build" ] && [ -d "$APP_BUNDLE" ]; then
    # Find any Swift source file newer than the built binary
    BUILT_BINARY_CHECK=$(find .build -name "$BINARY_NAME" -type f 2>/dev/null | head -1)
    if [ -n "$BUILT_BINARY_CHECK" ]; then
        NEWER_FILES=$(find Sources -name "*.swift" -newer "$BUILT_BINARY_CHECK" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$NEWER_FILES" -gt 0 ]; then
            log_info "Found $NEWER_FILES source file(s) newer than built binary - rebuild needed"
            FORCE_REBUILD=true
        fi
    else
        # No binary found, definitely need to build
        FORCE_REBUILD=true
    fi
fi

# Force rebuild if needed by touching a source file (triggers SPM to rebuild)
if [ "$FORCE_REBUILD" = true ] && [ -d ".build" ]; then
    log_info "Forcing rebuild by touching Package.swift..."
    touch Package.swift
fi

# Build the app and capture exit status
log_info "Running 'swift build'..."
swift build 2>&1 | tee /tmp/hypo_build.log
BUILD_EXIT_CODE=${PIPESTATUS[0]}

# Check if build failed
if [ $BUILD_EXIT_CODE -ne 0 ]; then
    log_error "Build failed"
    # Check if it's a dependency issue
    if grep -q "error opening input file.*checkouts" /tmp/hypo_build.log; then
        log_warn "Dependency checkout issue detected. Try: cd macos && swift package reset"
    fi
    # Show compilation errors
    ERROR_COUNT=$(grep -c "error:" /tmp/hypo_build.log || echo "0")
    if [ "$ERROR_COUNT" -gt 0 ]; then
        log_error "Found $ERROR_COUNT compilation error(s). Last few errors:"
        grep -E "error:" /tmp/hypo_build.log | tail -10 | sed 's/^/  /'
    fi
    log_error "Full build log: /tmp/hypo_build.log"
    exit 1
fi

# Find the built binary (prefer debug, fallback to release)
BUILT_BINARY=$(find "$MACOS_DIR/.build" -name "$BINARY_NAME" -type f 2>/dev/null | head -1)

if [ -z "$BUILT_BINARY" ]; then
    log_error "Built binary not found in .build directory"
    log_error "Build may have succeeded but binary was not produced"
    log_info "Searching for any binaries in .build:"
    find "$MACOS_DIR/.build" -name "*MenuBar*" -type f 2>/dev/null | head -5 | sed 's/^/  /'
    log_info "Build log location: /tmp/hypo_build.log"
    exit 1
fi

log_success "Build complete: $BUILT_BINARY"

# Always copy binary to app bundle to ensure it's updated
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

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

# Touch the app bundle to update its modification time
touch "$APP_BUNDLE"
log_info "App bundle updated: $(date -r "$APP_BUNDLE" '+%Y-%m-%d %H:%M:%S')"

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

