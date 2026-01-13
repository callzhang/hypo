#!/bin/bash
# Sign macOS app (Self-signed preferred, falls back to Ad-hoc)
# Usage: ./scripts/sign-macos.sh [app-bundle-path]
#
# This script attempts to sign the app with a stable self-signed identity
# (if available) to preserve accessibility permissions across builds.
# If no such identity is found, it falls back to an ad-hoc signature.
#
# Ad-hoc signatures allow the app to run, but users will see a Gatekeeper
# warning on first launch. Users can right-click and select "Open" to bypass the warning.
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

# Step 0: Check if app is already signed and valid
# If the signature is valid, we skip re-signing to preserve accessibility permissions
log_info "Step 0: Checking existing signature..."
if codesign --verify --strict --verbose "$APP_BUNDLE" 2>/dev/null; then
    log_info "App already has a valid signature"
    log_info "Skipping re-signing to preserve accessibility permissions across builds"
    log_info "Note: If the binary changed, the signature will be invalid and re-signing will occur automatically"
    log_success "Using existing signature"
    exit 0
else
    log_info "App is not signed or signature is invalid (binary may have changed), will sign"
fi

# Step 1: Cleaning app bundle...
log_info "Step 1: Cleaning app bundle..."

# Remove any existing signature first (only if we need to re-sign)
codesign --remove-signature "$APP_BUNDLE" 2>/dev/null || true

# 1. Remove Finder metadata & AppleDouble files FIRST (Nuclear option)
# These are the source of "resource fork" errors
find "$APP_BUNDLE" -name .DS_Store -delete 2>/dev/null || true
find "$APP_BUNDLE" -name "._*" -delete 2>/dev/null || true

# 2. Merge/clean AppleDouble files (._*) using dot_clean if available
if command -v dot_clean &> /dev/null; then
    dot_clean -m "$APP_BUNDLE" || true
fi

# 3. Remove quarantine attribute
xattr -d com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# 4. Strip ALL extended attributes (Recursively)
# Now that ._ files are gone, this cleans the actual data files
log_info "Removing extended attributes from all files..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

log_success "Cleaned app bundle"


# Find best signing identity
SIGN_IDENTITY="-"
if security find-identity -v -p codesigning | grep -q "HypoSelfSign"; then
    SIGN_IDENTITY="HypoSelfSign"
    log_info "Found local development certificate: $SIGN_IDENTITY"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    # Pick the first Apple Development cert
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk -F '"' '{print $2}')
    log_info "Found Apple Development certificate: $SIGN_IDENTITY"
fi

# Check if HypoSelfSign exists but is untrusted (ignored by find-identity -v)
if [ "$SIGN_IDENTITY" = "-" ] && security find-identity -p codesigning | grep -q "HypoSelfSign"; then
    log_warn "Found 'HypoSelfSign' certificate, but it is not trusted/valid."
    log_warn "You must Open Keychain Access > 'HypoSelfSign' > Trust > Always Trust."
fi

log_info "Signing with identity: $SIGN_IDENTITY"

if [ "$SIGN_IDENTITY" = "-" ]; then
    log_warn "Using ad-hoc signing (identity '-')."
    log_warn "This will cause accessibility permission prompts on every rebuild."
    log_info "To fix this, run: ./scripts/setup-dev-certs.sh"
else
    log_success "Using stable identity. This should preserve accessibility permissions."
fi

codesign --force --deep --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

if [ $? -ne 0 ]; then
    log_error "Code signing failed"
    exit 1
fi

log_success "App signed successfully"

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
log_success "✅ Signing complete!"
log_info "App bundle: $APP_BUNDLE"

