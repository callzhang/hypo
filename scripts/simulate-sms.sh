#!/bin/bash
# Script to simulate SMS reception on Android device for testing SMS-to-clipboard functionality
# Supports both emulators (via adb emu sms) and physical devices (via real SMS or broadcast)

set -e

DEVICE_ID="${1:-}"
SENDER="${2:-+1234567890}"
MESSAGE="${3:-Test SMS message from simulation script}"

if [ -z "$DEVICE_ID" ]; then
    echo "Usage: $0 <device_id> [sender_number] [message]"
    echo ""
    echo "Available devices:"
    adb devices -l | grep -v "List" | awk '{print $1 " - " $NF}'
    exit 1
fi

ADB="adb -s $DEVICE_ID"
PACKAGE_NAME="com.hypo.clipboard.debug"

echo "=== Simulating SMS Reception ==="
echo "Device: $DEVICE_ID"
echo "Sender: $SENDER"
echo "Message: $MESSAGE"
echo ""

# Check if app is installed
if ! "$ADB" shell pm list packages | grep -q "$PACKAGE_NAME"; then
    echo "❌ App not installed. Please install the app first:"
    echo "   ./scripts/build-android.sh"
    exit 1
fi

# Check if RECEIVE_SMS permission is granted
PERMISSION_CHECK=$("$ADB" shell dumpsys package "$PACKAGE_NAME" | grep -A 1 "android.permission.RECEIVE_SMS" | grep "granted=true" || echo "")
if [ -z "$PERMISSION_CHECK" ]; then
    echo "⚠️  RECEIVE_SMS permission may not be granted"
    echo "   Grant permission in: Settings → Apps → Hypo → Permissions → SMS"
    echo ""
fi

# Check if device is emulator
if echo "$DEVICE_ID" | grep -q "emulator"; then
    echo "📱 Emulator detected - using adb emu sms command..."
    echo ""
    "$ADB" emu sms send "$SENDER" "$MESSAGE"
    echo "✅ SMS sent via emulator command"
    echo ""
    echo "📋 Waiting 2 seconds for processing..."
    sleep 2
    
    # Try to read clipboard (may require root)
    echo ""
    echo "=== Checking Results ==="
    CLIPBOARD=$("$ADB" shell service call clipboard 1 2>/dev/null | grep -oP "(?<=text=')[^']*" || echo "")
    if [ -n "$CLIPBOARD" ]; then
        echo "✅ Clipboard content detected:"
        echo "   $CLIPBOARD"
    else
        echo "⚠️  Could not read clipboard directly (may require root)"
        echo "   Check app's clipboard history or monitor logs"
    fi
    
    echo ""
    echo "📊 Recent logs:"
    "$ADB" logcat -d -t 20 | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep -E "SmsReceiver|ClipboardListener" | tail -10 || echo "   No recent SMS-related logs"
    
else
    echo "📱 Physical device detected"
    echo ""
    echo "⚠️  Direct SMS simulation requires root access or real SMS"
    echo ""
    echo "Testing Options:"
    echo ""
    echo "Option 1: Send Real SMS (Recommended)"
    echo "  1. Send SMS from another phone to this device"
    echo "  2. Monitor logs: ./scripts/test-sms-clipboard.sh $DEVICE_ID"
    echo ""
    echo "Option 2: Use Android Studio SMS Emulator"
    echo "  - Open Android Studio → View → Tool Windows → Emulator"
    echo "  - Use SMS emulator panel to send test SMS"
    echo ""
    echo "Option 3: Monitor for Real SMS"
    echo "  Press Ctrl+C to stop monitoring"
    echo ""
    "$ADB" logcat -c  # Clear logs
    "$ADB" logcat | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep --line-buffered -E "SmsReceiver|ClipboardListener|SMS|📱|✅.*SMS"
fi

