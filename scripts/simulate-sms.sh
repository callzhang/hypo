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

PACKAGE_NAME="com.hypo.clipboard.debug"

# Function to run adb commands with device ID
adb_cmd() {
    adb -s "$DEVICE_ID" "$@"
}

echo "=== Simulating SMS Reception ==="
echo "Device: $DEVICE_ID"
echo "Sender: $SENDER"
echo "Message: $MESSAGE"
echo ""

# Check if app is installed
if ! adb_cmd shell pm list packages | grep -q "$PACKAGE_NAME"; then
    echo "❌ App not installed. Please install the app first:"
    echo "   ./scripts/build-android.sh"
    exit 1
fi

# Check if RECEIVE_SMS permission is granted
PERMISSION_CHECK=$(adb_cmd shell dumpsys package "$PACKAGE_NAME" | grep -A 1 "android.permission.RECEIVE_SMS" | grep "granted=true" || echo "")
if [ -z "$PERMISSION_CHECK" ]; then
    echo "⚠️  RECEIVE_SMS permission may not be granted"
    echo "   Grant permission in: Settings → Apps → Hypo → Permissions → SMS"
    echo ""
fi

# Check if device is emulator
if echo "$DEVICE_ID" | grep -q "emulator"; then
    echo "📱 Emulator detected - using adb emu sms command..."
    echo ""
    adb_cmd emu sms send "$SENDER" "$MESSAGE"
    echo "✅ SMS sent via emulator command"
    echo ""
    echo "📋 Waiting 2 seconds for processing..."
    sleep 2
    
    # Try to read clipboard (may require root)
    echo ""
    echo "=== Checking Results ==="
    CLIPBOARD=$(adb_cmd shell service call clipboard 1 2>/dev/null | grep -oP "(?<=text=')[^']*" || echo "")
    if [ -n "$CLIPBOARD" ]; then
        echo "✅ Clipboard content detected:"
        echo "   $CLIPBOARD"
    else
        echo "⚠️  Could not read clipboard directly (may require root)"
        echo "   Check app's clipboard history or monitor logs"
    fi
    
    echo ""
    echo "📊 Recent logs:"
    adb_cmd logcat -d -t 20 | grep -vE "MIUIInput|SKIA|VRI|RenderThread|ViewRootImpl|Choreographer|WindowOnBackDispatcher|Binder.*destroyed|弹出式窗口|Cleared Reference|sticky GC|non sticky GC|maxfree|minfree|Zygote|nativeloader|AssetManager2|ApplicationLoaders|ViewContentFactory|CompatChangeReporter|libc.*Access denied|TurboSchedMonitor|MiuiDownscaleImpl|MiuiMonitorThread|ResMonitorStub|MiuiAppAdaptationStubsControl|MiuiProcessManagerServiceStub|MiuiNBIManagerImpl|DecorViewImmersiveImpl|WM-WrkMgrInitializer|WM-PackageManagerHelper|WM-Schedulers|Adreno|Vulkan|libEGL|AdrenoVK|AdrenoUtils|SnapAlloc|qdgralloc|RenderLite|FramePredict|DecorView|ActivityThread.*HardwareRenderer|ActivityThread.*Miui Feature|ActivityThread.*TrafficStats|ActivityThread.*currentPkg|DesktopModeFlags|FirstFrameSpeedUp|ComputilityLevel|SLF4J|Sentry.*auto-init|Sentry.*Retrieving|AppScoutStateMachine|FlingPromotion|ForceDarkHelper|MiuiForceDarkConfig|vulkan.*searching|libEGL.*shader cache|Perf.*Connecting|NativeTurboSchedManager|ashmem.*Pinning|EpFrameworkFactory" | grep -E "SmsReceiver|ClipboardListener" | tail -10 || echo "   No recent SMS-related logs"
    
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
    adb_cmd logcat -c  # Clear logs
    adb_cmd logcat | grep -vE "MIUIInput|SKIA|VRI|RenderThread|ViewRootImpl|Choreographer|WindowOnBackDispatcher|Binder.*destroyed|弹出式窗口|Cleared Reference|sticky GC|non sticky GC|maxfree|minfree|Zygote|nativeloader|AssetManager2|ApplicationLoaders|ViewContentFactory|CompatChangeReporter|libc.*Access denied|TurboSchedMonitor|MiuiDownscaleImpl|MiuiMonitorThread|ResMonitorStub|MiuiAppAdaptationStubsControl|MiuiProcessManagerServiceStub|MiuiNBIManagerImpl|DecorViewImmersiveImpl|WM-WrkMgrInitializer|WM-PackageManagerHelper|WM-Schedulers|Adreno|Vulkan|libEGL|AdrenoVK|AdrenoUtils|SnapAlloc|qdgralloc|RenderLite|FramePredict|DecorView|ActivityThread.*HardwareRenderer|ActivityThread.*Miui Feature|ActivityThread.*TrafficStats|ActivityThread.*currentPkg|DesktopModeFlags|FirstFrameSpeedUp|ComputilityLevel|SLF4J|Sentry.*auto-init|Sentry.*Retrieving|AppScoutStateMachine|FlingPromotion|ForceDarkHelper|MiuiForceDarkConfig|vulkan.*searching|libEGL.*shader cache|Perf.*Connecting|NativeTurboSchedManager|ashmem.*Pinning|EpFrameworkFactory" | grep --line-buffered -E "SmsReceiver|ClipboardListener|SMS|📱|✅.*SMS"
fi

