#!/bin/bash
# Screenshot Android device cast and save to /tmp for automation
#
# REQUIREMENTS:
#   - Terminal must have Accessibility access enabled:
#     System Settings > Privacy & Security > Accessibility > Terminal
#   - Without this access, the script will fall back to full screen capture

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/tmp/hypo_screenshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCREENSHOT_FILE="${OUTPUT_DIR}/android_${TIMESTAMP}.png"

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

# Create output directory
mkdir -p "$OUTPUT_DIR"

log_info "Screenshot Android Device Cast"
log_info "Output directory: $OUTPUT_DIR"

# Method 1: Automatically focus the cast window, then screenshot frontmost window
log_info "Searching for Android cast window..."

# Quick check: Is the cast process running? (exact name: "Xiaomi Interconnectivity")
CAST_PROCESS=$(osascript -e 'tell application "System Events" to get name of first process whose name is "Xiaomi Interconnectivity" or name contains "Xiaomi Interconnectivity"' 2>/dev/null || echo "")

if [ -n "$CAST_PROCESS" ]; then
    log_info "Found cast process: $CAST_PROCESS"
    # Try to focus it directly (fast path)
    FOCUS_RESULT=$(osascript << 'EOF'
tell application "System Events"
    try
        set proc to first process whose name is "Xiaomi Interconnectivity" or name contains "Xiaomi Interconnectivity"
        set frontmost of proc to true
        delay 0.1
        try
            set win to window 1 of proc
            perform action "AXRaise" of win
        end try
        return "focused"
    on error
        return "not_found"
    end try
end tell
EOF
) || FOCUS_RESULT="not_found"
else
    log_warning "Cast process not found, trying fallback search..."
    FOCUS_RESULT="not_found"
fi

if [ "$FOCUS_RESULT" = "focused" ]; then
    log_success "Focused cast window process"
    sleep 0.2  # Reduced delay
    METHOD="window"
else
    log_warning "Could not automatically focus cast window, trying direct search..."
    
    # Optimized: Search by process name first, then by portrait dimensions (height > width)
    FOUND_WINDOW=$(osascript << 'EOF'
tell application "System Events"
    -- First, try to find by exact process name (fastest)
    set targetProcesses to {"Xiaomi Interconnectivity", "小米互联服务", "Xiaomi", "Interconnectivity"}
    set targetWindow to missing value
    set targetProcess to missing value
    
    repeat with procName in targetProcesses
        try
            set proc to first process whose name contains procName
            if proc is not missing value then
                try
                    set targetWindow to window 1 of proc
                    set targetProcess to proc
                    exit repeat
                end try
            end if
        end try
    end repeat
    
    -- If not found by name, try by portrait dimensions (height > width, typical for phone screens)
    if targetWindow is missing value then
        set maxHeight to 0
        set processCount to 0
        repeat with proc in processes
            set processCount to processCount + 1
            if processCount > 50 then exit repeat  -- Limit search to first 50 processes
            try
                repeat with win in windows of proc
                    try
                        set winSize to size of win
                        set winWidth to item 1 of winSize
                        set winHeight to item 2 of winSize
                        -- Portrait orientation: height > width, reasonable phone screen size
                        if winHeight > winWidth and winHeight > 500 and winWidth > 200 and winWidth < 800 and winHeight < 2000 then
                            if winHeight > maxHeight then
                                set maxHeight to winHeight
                                set targetWindow to win
                                set targetProcess to proc
                            end if
                        end if
                    end try
                end repeat
            end try
        end repeat
    end if
    
    if targetWindow is not missing value then
        set frontmost of targetProcess to true
        delay 0.2
        perform action "AXRaise" of targetWindow
        delay 0.2
        return "found"
    else
        return "not_found"
    end if
end tell
EOF
) || echo "not_found"
    
    if [ "$FOUND_WINDOW" = "found" ]; then
        log_success "Found window and focused it"
        METHOD="window"
    else
        log_warning "Window not found, will use full screen"
        METHOD="fullscreen"
    fi
fi

# Method 2: Screenshot the focused window using bounds (fully automatic, no prompts)
if [ "$METHOD" = "window" ]; then
    log_info "Capturing window automatically using bounds (no manual selection)..."
    
    # Get window bounds - try multiple process names and retry
    WINDOW_BOUNDS=""
    for i in 1 2 3; do  # More retries
        WINDOW_BOUNDS=$(osascript <<'APPLESCRIPT'
tell application "System Events"
    try
        set proc to missing value
        try
            set proc to first process whose name is "Xiaomi Interconnectivity"
        on error
            try
                set proc to first process whose name contains "Xiaomi Interconnectivity"
            on error
                try
                    set proc to first process whose name contains "小米"
                end try
            end try
        end try
        
        if proc is not missing value then
            set frontmost of proc to true
            delay 0.2
            set win to window 1 of proc
            set winPos to position of win
            set winSize to size of win
            set winX to item 1 of winPos as string
            set winY to item 2 of winPos as string
            set winW to item 1 of winSize as string
            set winH to item 2 of winSize as string
            if (winH as number) > (winW as number) then
                return winX & "," & winY & "," & winW & "," & winH
            else
                return ""
            end if
        else
            return ""
        end if
    on error
        return ""
    end try
end tell
APPLESCRIPT
) || echo ""
        # Validate bounds format and that height > width (portrait)
        if [ -n "$WINDOW_BOUNDS" ] && [ "$WINDOW_BOUNDS" != "" ]; then
            if echo "$WINDOW_BOUNDS" | grep -qE "^[0-9]+,[0-9-]+,[0-9]+,[0-9]+$"; then
                # Extract dimensions to verify portrait
                WIDTH=$(echo "$WINDOW_BOUNDS" | cut -d',' -f3)
                HEIGHT=$(echo "$WINDOW_BOUNDS" | cut -d',' -f4)
                if [ "$HEIGHT" -gt "$WIDTH" ] && [ "$HEIGHT" -gt 500 ]; then
                    log_info "Found portrait window: ${WIDTH}x${HEIGHT}"
                    break
                fi
            fi
        fi
        [ $i -lt 3 ] && sleep 0.3  # Sleep between retries
    done
    
    if [ -n "$WINDOW_BOUNDS" ] && [ "$WINDOW_BOUNDS" != "" ]; then
        log_info "Window bounds: $WINDOW_BOUNDS"
        # Use -R with bounds for fully automatic capture (NO PROMPTS!)
        if screencapture -R "$WINDOW_BOUNDS" -x "$SCREENSHOT_FILE" 2>/dev/null; then
            CAPTURE_SUCCESS=true
        else
            log_warning "Bounds capture failed"
            CAPTURE_SUCCESS=false
        fi
    else
        log_error "Could not get window bounds automatically"
        log_error ""
        log_error "⚠️  TERMINAL NEEDS ACCESSIBILITY ACCESS:"
        log_error "   1. Open System Settings"
        log_error "   2. Go to Privacy & Security > Accessibility"
        log_error "   3. Enable Terminal (or your terminal app)"
        log_error "   4. Run this script again"
        log_error ""
        log_error "Without this access, the script cannot automatically detect"
        log_error "the window position and will fall back to full screen capture."
        CAPTURE_SUCCESS=false
    fi
    
    if [ "$CAPTURE_SUCCESS" = "true" ] && [ -f "$SCREENSHOT_FILE" ] && [ -s "$SCREENSHOT_FILE" ]; then
        # Verify it's a reasonable size (not a tiny dialog)
        DIMENSIONS=$(sips -g pixelWidth -g pixelHeight "$SCREENSHOT_FILE" 2>/dev/null | grep -E "pixelWidth|pixelHeight" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        WIDTH=$(echo "$DIMENSIONS" | cut -d'x' -f1)
        HEIGHT=$(echo "$DIMENSIONS" | cut -d'x' -f2)
        
        if [ "$WIDTH" -gt 200 ] && [ "$HEIGHT" -gt 300 ]; then
            log_success "Window screenshot captured automatically (${DIMENSIONS})"
            METHOD="window"
        else
            log_warning "Captured window too small (${DIMENSIONS}), falling back to full screen"
            METHOD="fullscreen"
        fi
    else
        log_warning "Window capture failed, falling back to full screen"
        METHOD="fullscreen"
    fi
fi

# Method 2: Fallback to full screen screenshot if window selection failed
if [ "$METHOD" != "window" ]; then
    log_info "Taking full screen screenshot..."
    if screencapture -x "$SCREENSHOT_FILE" 2>/dev/null; then
        log_success "Screenshot saved: $SCREENSHOT_FILE"
    else
        log_error "Failed to take screenshot"
        exit 1
    fi
fi

# Process the screenshot
if [ -f "$SCREENSHOT_FILE" ] && [ -s "$SCREENSHOT_FILE" ]; then
    # Get image dimensions
    if command -v sips &> /dev/null; then
        DIMENSIONS=$(sips -g pixelWidth -g pixelHeight "$SCREENSHOT_FILE" 2>/dev/null | grep -E "pixelWidth|pixelHeight" | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        log_info "Image dimensions: ${DIMENSIONS}"
        
        # Verify it's not just a Finder window (basic check)
        if command -v tesseract &> /dev/null; then
            OCR_PREVIEW=$(tesseract "$SCREENSHOT_FILE" stdout 2>/dev/null | head -5 | tr '\n' ' ')
            if echo "$OCR_PREVIEW" | grep -qi "Finder.*File.*Edit"; then
                log_warning "Screenshot appears to show Finder window, not Android cast"
                log_info "Tip: Make sure the Android cast window is visible and try again"
            fi
        fi
    fi
    
    # Create a symlink to latest
    LATEST_LINK="${OUTPUT_DIR}/android_latest.png"
    ln -sf "$(basename "$SCREENSHOT_FILE")" "$LATEST_LINK" 2>/dev/null || true
    
    echo "$SCREENSHOT_FILE"
    exit 0
else
    log_error "Screenshot file not created or is empty"
    exit 1
fi

