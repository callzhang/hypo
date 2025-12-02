#!/bin/bash
# Simple automatic screenshot using screencapture -R with manual bounds
# This is a workaround when window bounds can't be retrieved automatically

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="/tmp/hypo_screenshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCREENSHOT_FILE="${OUTPUT_DIR}/android_${TIMESTAMP}.png"

mkdir -p "$OUTPUT_DIR"

# Focus the window first
"$SCRIPT_DIR/focus-cast-window.sh" >/dev/null 2>&1
sleep 1.0

# Try to get bounds, if that fails, use a default phone-sized region
BOUNDS=$(osascript << 'EOF' 2>/dev/null || echo ""
tell application "System Events"
    repeat with proc in processes
        try
            if name of proc contains "小米" then
                set frontmost of proc to true
                delay 0.3
                try
                    set win to window 1 of proc
                    set {winX, winY} to position of win
                    set {winW, winH} to size of win
                    return winX & "," & winY & "," & winW & "," & winH
                end try
            end if
        end try
    end repeat
    return ""
end tell
EOF
)

if [ -z "$BOUNDS" ] || [ "$BOUNDS" = "" ]; then
    echo "⚠️  Could not get window bounds automatically"
    echo "📋 Please ensure Terminal has Accessibility access:"
    echo "   System Settings > Privacy & Security > Accessibility > Terminal"
    echo ""
    echo "🔄 Falling back to full screen capture..."
    screencapture -x "$SCREENSHOT_FILE"
else
    echo "✅ Capturing window at: $BOUNDS"
    screencapture -R "$BOUNDS" -x "$SCREENSHOT_FILE"
fi

if [ -f "$SCREENSHOT_FILE" ]; then
    echo "$SCREENSHOT_FILE"
else
    echo "❌ Screenshot failed" >&2
    exit 1
fi

