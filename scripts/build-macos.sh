#!/bin/bash
# Build and relaunch macOS Hypo app
# Always builds the app to ensure latest code changes are included
# Usage: ./scripts/build-macos.sh [clean] [release]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$PROJECT_ROOT/macos"
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

# Parse arguments
CLEAN_BUILD=false
BUILD_CONFIG="debug"  # default: debug build

for arg in "$@"; do
    case "$arg" in
        clean)
            CLEAN_BUILD=true
            ;;
        release)
            BUILD_CONFIG="release"
            ;;
        *)
            log_warn "Unknown argument: $arg"
            log_info "Usage: $0 [clean] [release]"
            log_info "Default: debug build"
            ;;
    esac
done

# Set app bundle name based on build configuration
if [ "$BUILD_CONFIG" = "release" ]; then
    APP_BUNDLE="$PROJECT_ROOT/macos/HypoApp-release.app"
else
    APP_BUNDLE="$PROJECT_ROOT/macos/HypoApp.app"
fi

# Clean build if requested
if [ "$CLEAN_BUILD" = true ]; then
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
    <string>6</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
        log_success "Created Info.plist"
    fi
fi

# Ensure app icon exists
ICON_ICNS="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ICONSET_DIR="$APP_BUNDLE/Contents/Resources/AppIcon.iconset"
if [ ! -f "$ICON_ICNS" ] && [ ! -d "$ICONSET_DIR" ]; then
    log_warn "App icon not found. Generating icons..."
    if [ -f "$PROJECT_ROOT/scripts/generate-icons.py" ]; then
        python3 "$PROJECT_ROOT/scripts/generate-icons.py" || log_warn "Icon generation failed, continuing without icon"
    else
        log_warn "Icon generation script not found. App will run without icon."
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

# Always build - force rebuild by touching Package.swift to ensure SPM rebuilds
# This ensures the app is always built with the latest code changes
if [ -d ".build" ]; then
    log_info "Forcing rebuild to ensure latest code is built..."
    touch Package.swift
fi

# Build the app and capture exit status
if [ "$BUILD_CONFIG" = "release" ]; then
    log_info "Building release configuration..."
    swift build -c release 2>&1 | tee /tmp/hypo_build.log
else
    log_info "Building debug configuration (default)..."
    swift build 2>&1 | tee /tmp/hypo_build.log
fi
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

# Find the built binary (look in the appropriate build directory)
if [ "$BUILD_CONFIG" = "release" ]; then
    BUILT_BINARY="$MACOS_DIR/.build/release/$BINARY_NAME"
    if [ ! -f "$BUILT_BINARY" ]; then
        # Fallback: search for it
        BUILT_BINARY=$(find "$MACOS_DIR/.build" -path "*/release/$BINARY_NAME" -type f 2>/dev/null | head -1)
    fi
else
    BUILT_BINARY="$MACOS_DIR/.build/debug/$BINARY_NAME"
    if [ ! -f "$BUILT_BINARY" ]; then
        # Fallback: search for it
        BUILT_BINARY=$(find "$MACOS_DIR/.build" -name "$BINARY_NAME" -type f 2>/dev/null | head -1)
    fi
fi

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

# Ensure Info.plist exists (create if missing)
if [ ! -f "$APP_BUNDLE/Contents/Info.plist" ]; then
    log_info "Creating Info.plist..."
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
    <string>6</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF
    log_success "Created Info.plist"
fi

# Ensure icon is up to date (check if icon generation script is newer than icon)
# Icons are generated to HypoApp.app, so copy them to release bundle if needed
DEBUG_ICON_ICNS="$PROJECT_ROOT/macos/HypoApp.app/Contents/Resources/AppIcon.icns"
DEBUG_ICONSET_DIR="$PROJECT_ROOT/macos/HypoApp.app/Contents/Resources/AppIcon.iconset"
DEBUG_MENUBAR_ICONSET="$PROJECT_ROOT/macos/HypoApp.app/Contents/Resources/MenuBarIcon.iconset"

if [ "$BUILD_CONFIG" = "release" ]; then
    # For release builds, copy icons from debug bundle if they exist
    if [ -f "$DEBUG_ICON_ICNS" ] || [ -d "$DEBUG_ICONSET_DIR" ]; then
        log_info "Copying icons from debug bundle to release bundle..."
        mkdir -p "$APP_BUNDLE/Contents/Resources"
        if [ -f "$DEBUG_ICON_ICNS" ]; then
            cp -f "$DEBUG_ICON_ICNS" "$ICON_ICNS"
        fi
        if [ -d "$DEBUG_ICONSET_DIR" ]; then
            cp -rf "$DEBUG_ICONSET_DIR" "$ICONSET_DIR"
        fi
        if [ -d "$DEBUG_MENUBAR_ICONSET" ]; then
            cp -rf "$DEBUG_MENUBAR_ICONSET" "$APP_BUNDLE/Contents/Resources/MenuBarIcon.iconset"
        fi
        log_success "Icons copied to release bundle"
    else
        # Generate icons if they don't exist in debug bundle
        log_info "Generating icons (they will be created in debug bundle)..."
        python3 "$PROJECT_ROOT/scripts/generate-icons.py" 2>/dev/null || log_warn "Icon generation failed"
        # Copy them to release bundle
        if [ -f "$DEBUG_ICON_ICNS" ]; then
            mkdir -p "$APP_BUNDLE/Contents/Resources"
            cp -f "$DEBUG_ICON_ICNS" "$ICON_ICNS"
            if [ -d "$DEBUG_ICONSET_DIR" ]; then
                cp -rf "$DEBUG_ICONSET_DIR" "$ICONSET_DIR"
            fi
            if [ -d "$DEBUG_MENUBAR_ICONSET" ]; then
                cp -rf "$DEBUG_MENUBAR_ICONSET" "$APP_BUNDLE/Contents/Resources/MenuBarIcon.iconset"
            fi
            log_success "Icons generated and copied to release bundle"
        fi
    fi
else
    # For debug builds, use standard icon generation
    if [ -f "$PROJECT_ROOT/scripts/generate-icons.py" ] && [ -f "$ICON_ICNS" ]; then
        if [ "$PROJECT_ROOT/scripts/generate-icons.py" -nt "$ICON_ICNS" ]; then
            log_info "Icon generation script is newer than icon, regenerating..."
            python3 "$PROJECT_ROOT/scripts/generate-icons.py" 2>/dev/null || log_warn "Icon regeneration failed, using existing icon"
        fi
    elif [ ! -f "$ICON_ICNS" ] && [ ! -d "$ICONSET_DIR" ]; then
        log_info "Icons not found, generating..."
        python3 "$PROJECT_ROOT/scripts/generate-icons.py" 2>/dev/null || log_warn "Icon generation failed, continuing without icon"
    fi
fi

# Sign the app for local development (adhoc signature)
# This allows the app to run locally without Gatekeeper blocking it
log_info "Signing app bundle for local development..."
if [ -f "$SCRIPT_DIR/sign-macos.sh" ]; then
    # Use the dedicated signing script
    # Temporarily disable exit on error to allow build to continue if signing fails
    set +e
    bash "$SCRIPT_DIR/sign-macos.sh" "$APP_BUNDLE" 2>&1
    SIGN_EXIT_CODE=$?
    set -e
    
    if [ $SIGN_EXIT_CODE -ne 0 ]; then
        log_warn "Code signing failed (exit code: $SIGN_EXIT_CODE), but app may still work for local development"
        log_info "If macOS says the app is damaged, right-click and select 'Open' to bypass Gatekeeper"
    fi
else
    # Fallback to simple ad-hoc signing if script not found
    log_warn "sign-macos.sh not found, using simple ad-hoc signing..."
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
    if codesign --force --sign - "$APP_BINARY" 2>/dev/null && \
       codesign --force --sign - "$APP_BUNDLE" 2>/dev/null; then
        log_success "App signed successfully"
    else
        log_warn "Code signing failed, but app may still work for local development"
        log_info "If macOS says the app is damaged, right-click and select 'Open' to bypass Gatekeeper"
    fi
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

# macOS uses unified logging (os_log), not file-based logging
# Logs are available via: log stream --predicate 'subsystem == "com.hypo.clipboard"'
# Note: HistoryPopupPresenter may still write to /tmp/hypo_debug.log for legacy debug purposes

# Launch the app
log_info "Launching app..."
open "$APP_BUNDLE"

# Wait for app to start (menu bar apps can take a moment to initialize)
log_info "Waiting for app to initialize..."
MAX_WAIT=10
WAITED=0
APP_STARTED=false

while [ $WAITED -lt $MAX_WAIT ]; do
    if pgrep -x "$BINARY_NAME" > /dev/null; then
        APP_STARTED=true
        break
    fi
    sleep 0.5
    WAITED=$((WAITED + 1))
done

# Verify app is running
if [ "$APP_STARTED" = true ]; then
    PID=$(pgrep -x "$BINARY_NAME")
    log_success "App is running (PID: $PID)"
    
    # Give it a bit more time to show menu bar icon
    sleep 1
    
    # Check if app is still running (might have crashed)
    if ! pgrep -x "$BINARY_NAME" > /dev/null; then
        log_error "App started but crashed immediately. Check logs for errors:"
        log_info "  log stream --predicate 'subsystem == \"com.hypo.clipboard\"' --level debug"
        exit 1
    fi
    
    # macOS uses unified logging - view logs with:
    # log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug
    echo ""
    log_info "ℹ️  View logs with: log stream --predicate 'subsystem == \"com.hypo.clipboard\"' --level debug"
    log_info "ℹ️  Look for the menu bar icon in the top-right of your screen"
else
    log_error "App failed to start after ${MAX_WAIT} seconds"
    log_error "Check Console.app or run: log stream --predicate 'subsystem == \"com.hypo.clipboard\"' --level debug"
    exit 1
fi

echo ""
log_success "Build and launch complete!"
log_info "App bundle: $APP_BUNDLE"
log_info "View logs: log stream --predicate 'subsystem == \"com.hypo.clipboard\"' --level debug"

