#!/bin/bash
# Quick Android device connection checker

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/Users/derek/Documents/Projects/hypo/.android-sdk}"

echo "🔍 Checking Android device connection..."
echo ""

# Check if ADB exists
if [[ ! -f "$ANDROID_SDK_ROOT/platform-tools/adb" ]]; then
    echo "❌ ADB not found at: $ANDROID_SDK_ROOT/platform-tools/adb"
    echo "   Run: ./scripts/setup-android-sdk.sh"
    exit 1
fi

# Restart ADB server
echo "🔄 Restarting ADB server..."
"$ANDROID_SDK_ROOT/platform-tools/adb" kill-server 2>/dev/null
sleep 1
"$ANDROID_SDK_ROOT/platform-tools/adb" start-server
sleep 2

# Check devices
echo ""
echo "📱 Connected devices:"
echo "════════════════════════════════════════"
"$ANDROID_SDK_ROOT/platform-tools/adb" devices -l
echo "════════════════════════════════════════"
echo ""

# Check device status
DEVICE_COUNT=$("$ANDROID_SDK_ROOT/platform-tools/adb" devices | grep -c "device$")
UNAUTHORIZED_COUNT=$("$ANDROID_SDK_ROOT/platform-tools/adb" devices | grep -c "unauthorized")

if [[ $DEVICE_COUNT -gt 0 ]]; then
    echo "✅ Device connected and authorized!"
    echo ""
    echo "Device info:"
    "$ANDROID_SDK_ROOT/platform-tools/adb" shell getprop ro.product.model 2>/dev/null || echo "   (Could not get device model)"
    "$ANDROID_SDK_ROOT/platform-tools/adb" shell getprop ro.build.version.release 2>/dev/null || echo "   (Could not get Android version)"
    exit 0
elif [[ $UNAUTHORIZED_COUNT -gt 0 ]]; then
    echo "⚠️  Device detected but NOT AUTHORIZED"
    echo ""
    echo "📋 Fix steps:"
    echo "   1. Unplug USB cable"
    echo "   2. Plug it back in"
    echo "   3. On your phone: Tap 'Allow' when prompted"
    echo "   4. Check 'Always allow from this computer'"
    echo "   5. Run this script again"
    exit 1
else
    echo "❌ No Android device detected"
    echo ""
    echo "📋 Troubleshooting:"
    echo "   1. Check USB cable connection"
    echo "   2. Enable USB Debugging:"
    echo "      Settings → Developer Options → USB Debugging → ON"
    echo "   3. Set USB mode to 'File Transfer' or 'MTP'"
    echo "   4. Unplug and replug USB cable"
    echo "   5. Check if phone shows 'Allow USB debugging?' prompt"
    exit 1
fi

