#!/bin/bash
# Test script to verify transport status persistence across app restarts
# Usage: ./scripts/test-transport-persistence.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$PROJECT_ROOT/.android-sdk}"
ADB="${ANDROID_SDK_ROOT}/platform-tools/adb"

PACKAGE="com.hypo.clipboard"
LOG_TAG="TransportManager"

echo "=== Testing Transport Status Persistence ==="
echo ""

# Check device connection
if ! "$ADB" devices | grep -q "device$"; then
    echo "❌ No Android device connected"
    echo "Please connect your device via USB and enable USB debugging"
    exit 1
fi

echo "✅ Device connected"
echo ""

# Step 1: Clear app data to start fresh
echo "📱 Step 1: Clearing app data..."
"$ADB" shell pm clear "$PACKAGE" 2>/dev/null || echo "   (Note: Some devices may not allow clearing app data)"
sleep 2

# Step 2: Install/Reinstall app
echo "📱 Step 2: Installing app..."
"$ADB" install -r "$PROJECT_ROOT/android/app/build/outputs/apk/debug/app-debug.apk" >/dev/null 2>&1
echo "✅ App installed"
echo ""

# Step 3: Start app and monitor logs for initial state
echo "📱 Step 3: Starting app and checking initial state..."
"$ADB" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 3

echo "   Checking logs for SharedPreferences initialization..."
INITIAL_LOGS=$("$ADB" logcat -d | grep "$LOG_TAG" | tail -20)
if echo "$INITIAL_LOGS" | grep -q "⚠️ No SharedPreferences available"; then
    echo "   ❌ WARNING: Still seeing 'No SharedPreferences available' - fix may not be working"
else
    echo "   ✅ No 'No SharedPreferences available' warnings found"
fi

if echo "$INITIAL_LOGS" | grep -q "📦 Loading persisted transport status"; then
    echo "   ✅ Transport status loading attempted"
    LOADED_COUNT=$(echo "$INITIAL_LOGS" | grep -c "✅ Loaded persisted status" || true)
    echo "   📊 Loaded $LOADED_COUNT persisted status entries"
else
    echo "   ⚠️  No transport status loading logs found (may be normal if no previous pairing)"
fi
echo ""

# Step 4: Instructions for manual pairing
echo "📱 Step 4: Manual pairing required"
echo "   Please manually pair a device now:"
echo "   1. Open Hypo app on Android"
echo "   2. Go to Settings → Pair New Device"
echo "   3. Select LAN tab and pair with your macOS device"
echo "   4. Wait for 'Pairing successful' message"
echo ""
echo "   Waiting 30 seconds for pairing to complete..."
echo "   (You can pair the device now)"
sleep 30

# Step 5: Check that status was persisted
echo ""
echo "📱 Step 5: Verifying status was persisted..."
sleep 2
PAIRING_LOGS=$("$ADB" logcat -d | grep "$LOG_TAG" | tail -30)
if echo "$PAIRING_LOGS" | grep -q "💾 Persisting transport status"; then
    echo "   ✅ Transport status persistence logged"
    PERSISTED_DEVICE=$(echo "$PAIRING_LOGS" | grep "💾 Persisting transport status" | tail -1 | sed -n 's/.*device=\([^,]*\).*/\1/p')
    echo "   📊 Persisted status for device: $PERSISTED_DEVICE"
else
    echo "   ⚠️  No persistence logs found - pairing may not have completed"
fi
echo ""

# Step 6: Force stop and restart app
echo "📱 Step 6: Force stopping app..."
"$ADB" shell am force-stop "$PACKAGE"
sleep 2

echo "📱 Step 7: Restarting app..."
"$ADB" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 3

# Step 7: Check logs after restart
echo "📱 Step 8: Checking logs after restart..."
RESTART_LOGS=$("$ADB" logcat -d | grep "$LOG_TAG" | tail -30)

if echo "$RESTART_LOGS" | grep -q "⚠️ No SharedPreferences available"; then
    echo "   ❌ FAILED: Still seeing 'No SharedPreferences available' after restart"
    echo "   The fix is not working correctly"
    exit 1
else
    echo "   ✅ No 'No SharedPreferences available' warnings"
fi

if echo "$RESTART_LOGS" | grep -q "📦 Loading persisted transport status"; then
    echo "   ✅ Transport status loading attempted after restart"
    RESTART_LOADED=$(echo "$RESTART_LOGS" | grep -c "✅ Loaded persisted status" || true)
    echo "   📊 Loaded $RESTART_LOADED persisted status entries after restart"
    
    if [ "$RESTART_LOADED" -gt 0 ]; then
        echo ""
        echo "✅ SUCCESS: Transport status persisted and loaded correctly!"
        echo "   The device should show as 'Connected' in Settings after restart"
    else
        echo "   ⚠️  No status entries loaded (may be normal if pairing didn't complete)"
    fi
else
    echo "   ⚠️  No transport status loading logs found after restart"
fi

echo ""
echo "=== Test Complete ==="
echo ""
echo "Next steps:"
echo "  1. Check the Settings screen - paired device should show as 'Connected'"
echo "  2. If it shows 'Offline', check the device ID matching logic"
echo ""

