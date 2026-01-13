#!/bin/bash
# Build and relaunch macOS Hypo app
# Always builds the app to ensure latest code changes are included
# Usage: ./scripts/build-macos.sh [clean] [release]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$PROJECT_ROOT/macos"
BINARY_NAME="HypoMenuBar"

# Read version from centralized VERSION file
VERSION_FILE="$PROJECT_ROOT/VERSION"
if [ -f "$VERSION_FILE" ]; then
    APP_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
else
    APP_VERSION="1.0.6" # Fallback version
    log_warn "VERSION file not found, using fallback: $APP_VERSION"
fi

# Parse version to get build number (e.g., 1.0.5 -> 5)
BUILD_NUMBER=$(echo "$APP_VERSION" | awk -F. '{print $3}')
if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="6" # Fallback
fi

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

# Set app bundle name (always use "Hypo.app" for consistency)
APP_BUNDLE="$PROJECT_ROOT/macos/Hypo.app"

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
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
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
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Copy to Hypo</string>
            </dict>
            <key>NSMessage</key>
            <string>copyToHypo</string>
            <key>NSPortName</key>
            <string>com.hypo.clipboard</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSStringPboardType</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
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

# Ensure MacOS directory exists
mkdir -p "$APP_BUNDLE/Contents/MacOS"

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

# Update Info.plist with current version (create if missing)
log_info "Updating Info.plist with version $APP_VERSION (build $BUILD_NUMBER)..."
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
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
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
    <key>HypoBuildConfiguration</key>
    <string>$([ "$BUILD_CONFIG" = "release" ] && echo "Release" || echo "Debug")</string>
</dict>
</plist>
EOF
    log_success "Created Info.plist"
else
    # Update existing Info.plist with current version
    BUILD_CONFIG_VALUE="$([ "$BUILD_CONFIG" = "release" ] && echo "Release" || echo "Debug")"
    if command -v plutil &> /dev/null; then
        plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
        plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
        plutil -replace HypoBuildConfiguration -string "$BUILD_CONFIG_VALUE" "$APP_BUNDLE/Contents/Info.plist"
        log_success "Updated Info.plist with version $APP_VERSION (build $BUILD_NUMBER, config: $BUILD_CONFIG_VALUE)"
    else
        # Fallback: use sed if plutil is not available
        sed -i '' "s/<string>.*<\/string>.*CFBundleShortVersionString/<string>$APP_VERSION<\/string>/" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
        sed -i '' "s/<string>.*<\/string>.*CFBundleVersion/<string>$BUILD_NUMBER<\/string>/" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
        # Add or update HypoBuildConfiguration using sed
        if grep -q "HypoBuildConfiguration" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null; then
            sed -i '' "s/<string>.*<\/string>.*HypoBuildConfiguration/<string>$BUILD_CONFIG_VALUE<\/string>/" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
        else
            # Insert before </dict>
            sed -i '' "s|</dict>|    <key>HypoBuildConfiguration</key>\n    <string>$BUILD_CONFIG_VALUE</string>\n</dict>|" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
        fi
        log_success "Updated Info.plist with version $APP_VERSION (build $BUILD_NUMBER, config: $BUILD_CONFIG_VALUE) using sed"
    fi
fi

# Ensure icon is up to date (check if icon generation script is newer than icon)
# Icons are generated to Hypo.app
if [ -f "$PROJECT_ROOT/scripts/generate-icons.py" ] && [ -f "$ICON_ICNS" ]; then
    if [ "$PROJECT_ROOT/scripts/generate-icons.py" -nt "$ICON_ICNS" ]; then
        log_info "Icon generation script is newer than icon, regenerating..."
        python3 "$PROJECT_ROOT/scripts/generate-icons.py" 2>/dev/null || log_warn "Icon regeneration failed, using existing icon"
    fi
elif [ ! -f "$ICON_ICNS" ] && [ ! -d "$ICONSET_DIR" ]; then
    log_info "Icons not found, generating..."
    python3 "$PROJECT_ROOT/scripts/generate-icons.py" 2>/dev/null || log_warn "Icon generation failed, continuing without icon"
fi

# Sign the app for local development (adhoc signature)
# This allows the app to run locally without Gatekeeper blocking it
# We only re-sign if the signature is invalid or missing to preserve accessibility permissions
log_info "Signing app bundle for local development..."

if [ -f "$SCRIPT_DIR/sign-macos.sh" ]; then
    # Use the dedicated signing script (it will skip if signature is already valid)
    # Temporarily disable exit on error to allow build to continue if signing fails
    set +e
    bash "$SCRIPT_DIR/sign-macos.sh" "$APP_BUNDLE" 2>&1
    SIGN_EXIT_CODE=$?
    set -e
    
    if [ $SIGN_EXIT_CODE -ne 0 ]; then
        log_warn "Code signing failed (exit code: $SIGN_EXIT_CODE), trying fallback method..."
        # Fallback to simple ad-hoc signing
        xattr -cr "$APP_BUNDLE" 2>/dev/null || true
        if codesign --force --sign - "$APP_BINARY" 2>/dev/null && \
           codesign --force --sign - "$APP_BUNDLE" 2>/dev/null; then
            log_success "App signed with fallback method"
        else
            log_warn "Code signing failed, but app may still work for local development"
            log_info "If macOS says the app is damaged, right-click and select 'Open' to bypass Gatekeeper"
        fi
    else
        # Check if signing was skipped (exit code 0 from sign-macos.sh means success or skip)
        if codesign --verify --verbose "$APP_BUNDLE" 2>/dev/null; then
            # Signature is valid - check if it was just created or already existed
            log_success "App signature verified"
        fi
    fi
else
    # Fallback: Check if already signed before re-signing
    if codesign --verify --verbose "$APP_BUNDLE" 2>/dev/null; then
        log_info "App already has a valid signature, skipping re-signing"
        log_info "This preserves accessibility permissions across builds"
    else
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

# Define destination path
APPLICATIONS_APP="/Applications/$(basename "$APP_BUNDLE")"

# Remove existing app to ensure clean install
if [ -d "$APPLICATIONS_APP" ]; then
    rm -rf "$APPLICATIONS_APP"
fi

# Copy app to /Applications (use cp -R to preserve permissions and extended attributes)
if cp -R "$APP_BUNDLE" "/Applications/"; then
    log_success "App copied to /Applications: $APPLICATIONS_APP"
    # Update APP_BUNDLE to point to /Applications version for launching
    APP_BUNDLE="$APPLICATIONS_APP"
else
    log_error "Failed to copy app to /Applications"
    log_warn "Continuing with local app bundle: $APP_BUNDLE"
fi

# macOS uses unified logging (os_log), not file-based logging
# Logs are available via: log stream --predicate 'subsystem == "com.hypo.clipboard"'
# Note: HistoryPopupPresenter may still write to /tmp/hypo_debug.log for legacy debug purposes

# Launch the app
log_info "Launching app from /Applications..."
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

