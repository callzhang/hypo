#!/bin/bash
# Test script for pairing and bidirectional clipboard sync
# Monitors logs from both Android and macOS

set -e

ADB=""
if [ -d "$HOME/Library/Android/sdk" ]; then
    ADB="$HOME/Library/Android/sdk/platform-tools/adb"
elif [ -d ".android-sdk" ]; then
    ADB=".android-sdk/platform-tools/adb"
else
    echo "❌ ADB not found. Please set up Android SDK."
    exit 1
fi

echo "🧪 Hypo Pairing & Sync Test Suite"
echo "=================================="
echo ""

# Test 1: Verify services are running
echo "📋 Test 1: Service Status Check"
echo "--------------------------------"
echo "macOS WebSocket server:"
lsof -i :7010 | grep LISTEN && echo "✅ macOS server listening" || echo "❌ macOS server NOT listening"
echo ""

echo "Android service:"
"$ADB" shell dumpsys activity services | grep -i ClipboardSyncService && echo "✅ Android service running" || echo "❌ Android service NOT running"
echo ""

# Test 2: Monitor pairing flow
echo "📱 Test 2: Pairing Flow"
echo "----------------------"
echo "👉 Please tap the macOS device in Android's LAN pairing tab"
echo "Monitoring logs for 60 seconds..."
echo ""

"$ADB" logcat -c
echo "Android logs (pairing):"
timeout 60 "$ADB" logcat | grep -E "LanPairingViewModel|PairingHandshake|pairing|ACK" --line-buffered | head -30 &
ANDROID_PID=$!

echo "macOS logs (pairing):"
tail -f /tmp/hypo_debug.log 2>/dev/null | grep -E "pairing|Pairing|ACK|challenge" --line-buffered | head -20 &
MACOS_PID=$!

sleep 60
kill $ANDROID_PID $MACOS_PID 2>/dev/null || true

echo ""
echo "✅ Pairing test complete"
echo ""

# Test 3: Clipboard sync (Android → macOS)
echo "📋 Test 3: Android → macOS Clipboard Sync"
echo "-----------------------------------------"
echo "👉 Please copy some text on Android (e.g., 'Test from Android')"
echo "Monitoring logs for 30 seconds..."
echo ""

"$ADB" logcat -c
echo "Android logs (sync out):"
timeout 30 "$ADB" logcat | grep -E "ClipboardListener|SyncCoordinator|📤|Syncing" --line-buffered | head -20 &
ANDROID_SYNC_PID=$!

echo "macOS logs (sync in):"
tail -f /tmp/hypo_debug.log 2>/dev/null | grep -E "CLIPBOARD|clipboard|Incoming" --line-buffered | head -15 &
MACOS_SYNC_PID=$!

sleep 30
kill $ANDROID_SYNC_PID $MACOS_SYNC_PID 2>/dev/null || true

echo ""
echo "✅ Android → macOS sync test complete"
echo ""

# Test 4: Clipboard sync (macOS → Android)
echo "📋 Test 4: macOS → Android Clipboard Sync"
echo "-----------------------------------------"
echo "👉 Please copy some text on macOS (e.g., 'Test from macOS')"
echo "Monitoring logs for 30 seconds..."
echo ""

"$ADB" logcat -c
echo "macOS logs (sync out):"
tail -f /tmp/hypo_debug.log 2>/dev/null | grep -E "transmit|Synced|sync" --line-buffered | head -15 &
MACOS_OUT_PID=$!

echo "Android logs (sync in):"
timeout 30 "$ADB" logcat | grep -E "IncomingClipboardHandler|📥|Received clipboard" --line-buffered | head -20 &
ANDROID_IN_PID=$!

sleep 30
kill $MACOS_OUT_PID $ANDROID_IN_PID 2>/dev/null || true

echo ""
echo "✅ macOS → Android sync test complete"
echo ""

# Summary
echo "📊 Test Summary"
echo "==============="
echo "Check the logs above for:"
echo "  ✅ Pairing: Look for 'Pairing completed successfully'"
echo "  ✅ Android → macOS: Look for '📤 Syncing' and 'CLIPBOARD RECEIVED'"
echo "  ✅ macOS → Android: Look for 'transmit' and '📥 Received clipboard'"
echo ""

