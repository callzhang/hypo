#!/bin/bash
# Self-sign macOS app for free distribution (without notarization)
# Usage: ./scripts/sign-macos.sh [app-bundle-path]
#
# This creates an ad-hoc signature that allows the app to run,
# but users will see a Gatekeeper warning on first launch.
# Users can right-click and select "Open" to bypass the warning.
#
# For notarization (no warnings), you need a paid Apple Developer account.
# See docs/NOTARIZATION.md for details.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$PROJECT_ROOT/macos"

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

# Get app bundle path
APP_BUNDLE="${1:-$MACOS_DIR/HypoApp.app}"

if [ ! -d "$APP_BUNDLE" ]; then
    log_error "App bundle not found: $APP_BUNDLE"
    log_info "Usage: $0 [app-bundle-path]"
    exit 1
fi

APP_BUNDLE=$(cd "$(dirname "$APP_BUNDLE")" && pwd)/$(basename "$APP_BUNDLE")
log_info "App bundle: $APP_BUNDLE"

# Check for entitlements file
ENTITLEMENTS="$MACOS_DIR/HypoApp.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
    log_warn "Entitlements file not found: $ENTITLEMENTS"
    log_info "Creating minimal entitlements file..."
    cat > "$ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <false/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <false/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.multicast</key>
    <true/>
</dict>
</plist>
EOF
    log_success "Created entitlements file"
fi

log_info "Using entitlements: $ENTITLEMENTS"

# Step 0: Clean extended attributes and resource forks (required before signing)
log_info "Step 0: Cleaning app bundle..."
# Remove any existing signature first
codesign --remove-signature "$APP_BUNDLE" 2>/dev/null || true
# Remove quarantine attribute (set by macOS when downloading from internet)
xattr -d com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
# Remove extended attributes and resource forks
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
# Remove Finder metadata files
find "$APP_BUNDLE" -name .DS_Store -delete 2>/dev/null || true
find "$APP_BUNDLE" -name "._*" -delete 2>/dev/null || true
log_success "Cleaned app bundle"

# Step 1: Ad-hoc sign the app (free, no certificate needed)
log_info "Step 1: Ad-hoc signing app bundle..."
log_warn "Note: This is a free ad-hoc signature, not notarized."
log_warn "Users will see a Gatekeeper warning on first launch."

codesign --force --deep --sign "-" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_BUNDLE"

if [ $? -ne 0 ]; then
    log_error "Code signing failed"
    exit 1
fi

log_success "App signed with ad-hoc signature"

# Verify signature
log_info "Verifying signature..."
codesign --verify --verbose "$APP_BUNDLE"
if [ $? -ne 0 ]; then
    log_error "Signature verification failed"
    exit 1
fi

log_success "Signature verified"

# Check Gatekeeper status
log_info "Checking Gatekeeper status..."
spctl --assess --verbose "$APP_BUNDLE" 2>&1 | head -5 || true

echo ""
log_warn "⚠️  IMPORTANT: This app is NOT notarized"
log_info ""
log_info "Users will see a warning when opening the app:"
log_info "  'Hypo.app cannot be opened because the developer cannot be verified'"
log_info ""
log_info "Users can bypass this by:"
log_info "  1. Right-click the app → Open → Open"
log_info "  2. Or: System Settings → Privacy & Security → Allow"
log_info ""
log_info "For notarization (no warnings), you need:"
log_info "  - Apple Developer Program membership (\$99/year)"
log_info "  - Developer ID Application certificate"
log_info "  - See docs/NOTARIZATION.md for details"
log_info ""
log_success "✅ Ad-hoc signing complete!"
log_info "App bundle: $APP_BUNDLE"

