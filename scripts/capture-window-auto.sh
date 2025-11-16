#!/bin/bash
# Fully automatic window capture using window bounds

set -euo pipefail

OUTPUT_FILE="${1:-/tmp/hypo_screenshots/android_auto.png}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Focus the window first
"$SCRIPT_DIR/focus-cast-window.sh" >/dev/null 2>&1
sleep 0.8

# Get window bounds using AppleScript
BOUNDS=$(osascript << 'EOF'
tell application "System Events"
    set proc to first process whose name contains "小米"
    set frontmost of proc to true
    delay 0.3
    try
        set win to window 1 of proc
        set winPos to position of win
        set winSize to size of win
        set winX to item 1 of winPos
        set winY to item 2 of winPos
        set winW to item 1 of winSize
        set winH to item 2 of winSize
        return winX & "," & winY & "," & winW & "," & winH
    on error
        return ""
    end try
end tell
EOF
)

if [ -n "$BOUNDS" ] && [ "$BOUNDS" != "" ]; then
    echo "Capturing window at bounds: $BOUNDS"
    screencapture -R "$BOUNDS" -x "$OUTPUT_FILE"
    echo "$OUTPUT_FILE"
else
    echo "Could not get window bounds" >&2
    exit 1
fi

