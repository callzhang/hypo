#!/bin/bash
# Automated Android UI testing using screenshots

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="/tmp/hypo_screenshots"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_section() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

# Take screenshot
log_section "Step 1: Capture Android Screen"
SCREENSHOT_OUTPUT=$("$SCRIPT_DIR/screenshot-android.sh" 2>&1)
SCREENSHOT_EXIT=$?

# Extract the filename from the output (last line should be the path)
SCREENSHOT_FILE=$(echo "$SCREENSHOT_OUTPUT" | tail -1 | tr -d '\n')

if [ $SCREENSHOT_EXIT -ne 0 ] || [ ! -f "$SCREENSHOT_FILE" ]; then
    log_error "Failed to capture screenshot"
    echo "Output: $SCREENSHOT_OUTPUT"
    exit 1
fi

log_success "Screenshot captured: $SCREENSHOT_FILE"

# Analyze screenshot
log_section "Step 2: Analyze Screenshot"
"$SCRIPT_DIR/analyze-screenshot.sh" "$SCREENSHOT_FILE"

# Check for specific UI states
log_section "Step 3: Detect UI State"

OCR_TEXT=""
if command -v tesseract &> /dev/null; then
    # Use absolute path and write to temp file first (more reliable)
    ABS_PATH=$(cd "$(dirname "$SCREENSHOT_FILE")" && pwd)/$(basename "$SCREENSHOT_FILE")
    TEMP_OCR="/tmp/hypo_ocr_$$.txt"
    OCR_TEXT=$(tesseract "$ABS_PATH" "$TEMP_OCR" 2>/dev/null && cat "${TEMP_OCR}.txt" 2>/dev/null || echo "")
    rm -f "${TEMP_OCR}.txt" 2>/dev/null || true
    
    # Detect pairing screen
    if echo "$OCR_TEXT" | grep -qi "Pairing\|Scan QR\|Enter code"; then
        log_info "📱 Detected: Pairing Screen"
        log_info "   Action: User needs to scan QR or enter code"
    fi
    
    # Detect settings screen
    if echo "$OCR_TEXT" | grep -qi "Settings\|Paired Devices\|LAN Sync"; then
        log_info "⚙️  Detected: Settings Screen"
        
        # Check for paired devices
        if echo "$OCR_TEXT" | grep -qi "dereks-macbook\|macbook\|\.local"; then
            log_success "   Found paired macOS device"
        else
            log_warning "   No paired devices found"
        fi
        
        # Check connection status
        if echo "$OCR_TEXT" | grep -qi "LAN\|Connected"; then
            log_success "   Connection status: Connected (LAN)"
        elif echo "$OCR_TEXT" | grep -qi "Cloud"; then
            log_success "   Connection status: Connected (Cloud)"
        elif echo "$OCR_TEXT" | grep -qi "Offline\|Disconnected"; then
            log_warning "   Connection status: Offline"
        fi
    fi
    
    # Detect home screen
    if echo "$OCR_TEXT" | grep -qi "Clipboard\|Latest Item\|History"; then
        log_info "🏠 Detected: Home Screen"
    fi
    
    # Detect error states
    if echo "$OCR_TEXT" | grep -qi "Error\|Failed\|Pairing Failed"; then
        log_error "❌ Detected: Error State"
        log_error "   Error message detected in UI"
    fi
    
else
    log_warning "tesseract not installed - UI state detection limited"
    log_info "Install with: brew install tesseract"
fi

log_section "Step 4: Recommendations"

# Provide actionable recommendations based on detected state
if echo "$OCR_TEXT" 2>/dev/null | grep -qi "Pairing Failed"; then
    log_info "🔧 Recommendation: Check pairing logs and re-pair device"
    log_info "   Run: adb logcat -s PairingHandshake:* LanPairingViewModel:*"
fi

if echo "$OCR_TEXT" 2>/dev/null | grep -qi "Offline\|Disconnected"; then
    log_info "🔧 Recommendation: Check network connection and device discovery"
    log_info "   Ensure both devices are on the same network"
fi

log_success "Analysis complete. Screenshot saved at: $SCREENSHOT_FILE"

