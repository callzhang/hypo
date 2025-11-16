#!/bin/bash
# Analyze Android screenshot for UI automation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOT_FILE="${1:-/tmp/hypo_screenshots/android_latest.png}"

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

if [ ! -f "$SCREENSHOT_FILE" ]; then
    log_error "Screenshot file not found: $SCREENSHOT_FILE"
    exit 1
fi

log_info "Analyzing screenshot: $SCREENSHOT_FILE"

# Check if we have OCR capabilities
if command -v tesseract &> /dev/null; then
    log_info "Running OCR on screenshot..."
    # Use absolute path and write to temp file first (more reliable)
    ABS_PATH=$(cd "$(dirname "$SCREENSHOT_FILE")" && pwd)/$(basename "$SCREENSHOT_FILE")
    TEMP_OCR="/tmp/hypo_ocr_$$.txt"
    OCR_TEXT=$(tesseract "$ABS_PATH" "$TEMP_OCR" 2>/dev/null && cat "${TEMP_OCR}.txt" 2>/dev/null || echo "")
    rm -f "${TEMP_OCR}.txt" 2>/dev/null || true
    
    if [ -n "$OCR_TEXT" ]; then
        log_success "OCR Results:"
        echo "$OCR_TEXT" | head -20
        
        # Check for common UI elements
        if echo "$OCR_TEXT" | grep -qi "Hypo\|Clipboard\|Settings\|Pair\|Device"; then
            log_success "Found Hypo app UI elements"
        fi
        
        if echo "$OCR_TEXT" | grep -qi "Connected\|LAN\|Cloud\|Offline"; then
            log_info "Connection status detected in screenshot"
        fi
        
        if echo "$OCR_TEXT" | grep -qi "Pairing\|Discovering\|Devices Found"; then
            log_info "Pairing UI detected"
        fi
    fi
else
    log_warning "tesseract not installed - OCR analysis skipped"
    log_info "Install with: brew install tesseract"
fi

# Use sips to get basic image info
if command -v sips &> /dev/null; then
    log_info "Image information:"
    sips -g all "$SCREENSHOT_FILE" 2>/dev/null | grep -E "pixelWidth|pixelHeight|format|space" || true
fi

# Check for specific colors (Android Material Design colors)
# This is a simple heuristic - could be improved with image processing
log_info "Basic image analysis complete"

