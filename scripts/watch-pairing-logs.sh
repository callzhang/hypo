#!/bin/bash
# Watch pairing logs in real-time

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$PROJECT_ROOT/.android-sdk}"

echo "🔍 Watching pairing logs..."
echo "Press Ctrl+C to stop"
echo ""

# Clear Android logs
"$ANDROID_SDK_ROOT/platform-tools/adb" logcat -c 2>/dev/null

# Monitor both Android and macOS
(
    # Android logs
    "$ANDROID_SDK_ROOT/platform-tools/adb" logcat | grep -E "LanPairingViewModel|LanWebSocketClient|pairing|Pairing|WebSocket|Connection|challenge|ACK|sendRawJson|onOpen|onFailure|onMessage" | while IFS= read -r line; do
        echo -e "\033[0;34m[ANDROID]\033[0m $line"
    done
) &
ANDROID_PID=$!

(
    # macOS logs - look for print statements in Console
    log stream --predicate 'process == "HypoMenuBar"' --level debug 2>/dev/null | grep -E "LanWebSocketServer|pairing|challenge|Connection|Received|WebSocket|ACK|❌|✅|⚠️|📥|📤|🔌|📋|🔔|🟡|⏳" | while IFS= read -r line; do
        echo -e "\033[0;32m[macOS]\033[0m $line"
    done
) &
MACOS_PID=$!

# Also watch debug log file
if [ -f "/tmp/hypo_debug.log" ]; then
    tail -f /tmp/hypo_debug.log 2>/dev/null | while IFS= read -r line; do
        echo -e "\033[1;33m[DEBUG]\033[0m $line"
    done &
    DEBUG_PID=$!
fi

trap "kill $ANDROID_PID $MACOS_PID ${DEBUG_PID:-} 2>/dev/null; exit" INT TERM

wait


