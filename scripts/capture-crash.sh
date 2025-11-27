#!/bin/bash
# Capture crash logs when manually copying text

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    if [ -d "$PROJECT_ROOT/.android-sdk" ]; then
        export ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
    else
        echo "❌ ANDROID_SDK_ROOT not set"
        exit 1
    fi
fi

ADB="$ANDROID_SDK_ROOT/platform-tools/adb"

echo "=== Crash Capture Script ==="
echo ""
echo "This will monitor for crashes when you copy text manually."
echo ""
echo "📋 INSTRUCTIONS:"
echo "1. Keep this script running"
echo "2. Copy some text manually on your device"
echo "3. The script will capture any crash logs"
echo ""
read -p "Press Enter to start monitoring (or Ctrl+C to cancel)..."

echo ""
echo "Clearing logs and starting monitoring..."
"$ADB" logcat -c

echo "Monitoring for 30 seconds..."
echo "Please copy text manually now..."

# Monitor in background
"$ADB" logcat | grep -v "MIUIInput" | grep --line-buffered -E "(FATAL|AndroidRuntime|Exception|Error|ClipboardListener|ClipboardParser|hypo)" &
MONITOR_PID=$!

sleep 30

kill $MONITOR_PID 2>/dev/null || true

echo ""
echo "=== Crash Analysis ==="
echo ""

# Check for crashes
CRASHES=$("$ADB" logcat -d -t 60 | grep -v "MIUIInput" | grep -c "FATAL EXCEPTION" || echo "0")
EXCEPTIONS=$("$ADB" logcat -d -t 60 | grep -v "MIUIInput" | grep -c "Exception" || echo "0")

if [ "$CRASHES" -gt 0 ]; then
    echo "❌ CRASHES DETECTED: $CRASHES"
    echo ""
    echo "=== Crash Details ==="
    "$ADB" logcat -d -t 60 | grep -v "MIUIInput" | grep -B 5 -A 50 "FATAL EXCEPTION" | head -100
else
    echo "✅ No crashes detected"
fi

echo ""
echo "=== All Exceptions ==="
"$ADB" logcat -d -t 60 | grep -v "MIUIInput" | grep "Exception" | grep -v "LanWebSocketClient" | tail -30

echo ""
echo "=== ClipboardListener Activity ==="
"$ADB" logcat -d -t 60 | grep -v "MIUIInput" | grep "ClipboardListener" | tail -30

