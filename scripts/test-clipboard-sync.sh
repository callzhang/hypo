#!/bin/bash
# Test clipboard sync between Android and macOS

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"

echo "=== Clipboard Sync Test ==="
echo ""

# Check if device is connected
if ! "$ADB" devices | grep -q "device$"; then
    echo "❌ No Android device connected"
    exit 1
fi

echo "✅ Android device connected"
echo ""

# Clear logs
echo "📱 Step 1: Clearing logs..."
"$ADB" logcat -c
sleep 1
echo "✅ Logs cleared"
echo ""

# Test Android → macOS
echo "📋 Test 1: Android → macOS"
echo "  1. Copy some text on Android device (e.g., 'Hello from Android')"
echo "  2. Wait 5 seconds..."
echo ""
read -p "   Press Enter after copying text on Android..."
sleep 5

echo ""
echo "📊 Checking Android logs for clipboard sync..."
ANDROID_LOGS=$("$ADB" logcat -d | grep -E "(ClipboardListener|SyncCoordinator|SyncEngine|onClipboardEvent|📋|📨|📤)" | tail -20)
if [ -n "$ANDROID_LOGS" ]; then
    echo "✅ Clipboard sync activity detected:"
    echo "$ANDROID_LOGS"
else
    echo "⚠️  No clipboard sync logs found"
    echo "   Checking all ClipboardListener logs..."
    "$ADB" logcat -d | grep "ClipboardListener" | tail -10
fi

echo ""
echo "📋 Test 2: macOS → Android"
echo "  1. Copy some text on macOS (e.g., 'Hello from macOS')"
echo "  2. Wait 5 seconds..."
echo ""
read -p "   Press Enter after copying text on macOS..."
sleep 5

echo ""
echo "📊 Checking Android logs for incoming clipboard..."
INCOMING_LOGS=$("$ADB" logcat -d | grep -E "(IncomingClipboardHandler|MessageHandler|ChannelManager|clipboard)" | tail -20)
if [ -n "$INCOMING_LOGS" ]; then
    echo "✅ Incoming clipboard activity detected:"
    echo "$INCOMING_LOGS"
else
    echo "⚠️  No incoming clipboard logs found"
fi

echo ""
echo "=== Test Complete ==="
echo ""
echo "📝 Summary:"
echo "  - Check if text copied on Android appears on macOS"
echo "  - Check if text copied on macOS appears on Android"
echo ""
echo "🔍 If sync is not working:"
echo "  1. Verify devices are paired (Settings → Paired Devices)"
echo "  2. Check device shows as 'Connected (LAN)'"
echo "  3. Verify ClipboardSyncService is running"
echo "  4. Check for errors in logs: adb logcat | grep -i error"

