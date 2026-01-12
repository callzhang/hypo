#!/bin/bash
# Comprehensive SMS-to-clipboard testing script
# Tests SMS reception, clipboard copy, and sync functionality

set -e

DEVICE_ID="${1:-}"

if [ -z "$DEVICE_ID" ]; then
    echo "Usage: $0 <device_id>"
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

echo "=== SMS-to-Clipboard Test Suite ==="
echo "Device: $DEVICE_ID"
echo ""

# Check app installation
if ! adb_cmd shell pm list packages | grep -q "$PACKAGE_NAME"; then
    echo "❌ App not installed"
    exit 1
fi

# Check permissions
echo "📋 Checking permissions..."
RECEIVE_SMS=$(adb_cmd shell dumpsys package "$PACKAGE_NAME" | grep -A 1 "android.permission.RECEIVE_SMS" | grep "granted=true" || echo "")
if [ -z "$RECEIVE_SMS" ]; then
    echo "⚠️  RECEIVE_SMS permission not granted"
    echo "   Grant in: Settings → Apps → Hypo → Permissions → SMS"
else
    echo "✅ RECEIVE_SMS permission granted"
fi

# Check if receiver is registered
echo ""
echo "📱 Checking SMS receiver registration..."
RECEIVER=$(adb_cmd shell dumpsys package "$PACKAGE_NAME" | grep -A 5 "SmsReceiver" | grep "android.provider.Telephony.SMS_RECEIVED" || echo "")
if [ -z "$RECEIVER" ]; then
    echo "⚠️  SMS receiver may not be registered"
else
    echo "✅ SMS receiver registered"
fi

# Get app PID for log filtering
APP_PID=$(adb_cmd shell pidof -s "$PACKAGE_NAME" 2>/dev/null || echo "")
if [ -z "$APP_PID" ]; then
    echo "⚠️  App is not running. Starting app..."
    adb_cmd shell am start -n "$PACKAGE_NAME/com.hypo.clipboard.MainActivity" >/dev/null 2>&1
    sleep 2
    APP_PID=$(adb_cmd shell pidof -s "$PACKAGE_NAME" 2>/dev/null || echo "")
fi

if [ -n "$APP_PID" ]; then
    echo "✅ App is running (PID: $APP_PID)"
else
    echo "⚠️  Could not get app PID"
fi

echo ""
echo "=== Test Instructions ==="
echo ""
echo "For Emulator:"
echo "  1. Run: adb -s $DEVICE_ID emu sms send +1234567890 'Test message'"
echo "  2. Monitor logs below"
echo ""
echo "For Physical Device:"
echo "  1. Send a real SMS from another phone to this device"
echo "  2. Monitor logs below"
echo ""
echo "Expected behavior:"
echo "  - SmsReceiver should log: '📱 Received SMS from ...'"
echo "  - SmsReceiver should log: '✅ SMS content copied to clipboard'"
echo "  - ClipboardListener should detect change and sync to macOS"
echo ""
echo "=== Monitoring Logs (Press Ctrl+C to stop) ==="
echo ""

# Monitor logs for SMS and clipboard events
adb_cmd logcat -c  # Clear logs first

# Only use --pid filter if we have a valid PID
if [ -n "$APP_PID" ]; then
    adb_cmd logcat --pid="$APP_PID" 2>/dev/null | grep -vE "MIUIInput|SKIA|VRI|RenderThread|ViewRootImpl|Choreographer|WindowOnBackDispatcher|Binder.*destroyed|弹出式窗口|Cleared Reference|sticky GC|non sticky GC|maxfree|minfree|Zygote|nativeloader|AssetManager2|ApplicationLoaders|ViewContentFactory|CompatChangeReporter|libc.*Access denied|TurboSchedMonitor|MiuiDownscaleImpl|MiuiMonitorThread|ResMonitorStub|MiuiAppAdaptationStubsControl|MiuiProcessManagerServiceStub|MiuiNBIManagerImpl|DecorViewImmersiveImpl|WM-WrkMgrInitializer|WM-PackageManagerHelper|WM-Schedulers|Adreno|Vulkan|libEGL|AdrenoVK|AdrenoUtils|SnapAlloc|qdgralloc|RenderLite|FramePredict|DecorView|ActivityThread.*HardwareRenderer|ActivityThread.*Miui Feature|ActivityThread.*TrafficStats|ActivityThread.*currentPkg|DesktopModeFlags|FirstFrameSpeedUp|ComputilityLevel|SLF4J|Sentry.*auto-init|Sentry.*Retrieving|AppScoutStateMachine|FlingPromotion|ForceDarkHelper|MiuiForceDarkConfig|vulkan.*searching|libEGL.*shader cache|Perf.*Connecting|NativeTurboSchedManager|ashmem.*Pinning|EpFrameworkFactory" | grep --line-buffered -E "SmsReceiver|ClipboardListener|SMS|clipboard" || \
    adb_cmd logcat | grep -vE "MIUIInput|SKIA|VRI|RenderThread|ViewRootImpl|Choreographer|WindowOnBackDispatcher|Binder.*destroyed|弹出式窗口|Cleared Reference|sticky GC|non sticky GC|maxfree|minfree|Zygote|nativeloader|AssetManager2|ApplicationLoaders|ViewContentFactory|CompatChangeReporter|libc.*Access denied|TurboSchedMonitor|MiuiDownscaleImpl|MiuiMonitorThread|ResMonitorStub|MiuiAppAdaptationStubsControl|MiuiProcessManagerServiceStub|MiuiNBIManagerImpl|DecorViewImmersiveImpl|WM-WrkMgrInitializer|WM-PackageManagerHelper|WM-Schedulers|Adreno|Vulkan|libEGL|AdrenoVK|AdrenoUtils|SnapAlloc|qdgralloc|RenderLite|FramePredict|DecorView|ActivityThread.*HardwareRenderer|ActivityThread.*Miui Feature|ActivityThread.*TrafficStats|ActivityThread.*currentPkg|DesktopModeFlags|FirstFrameSpeedUp|ComputilityLevel|SLF4J|Sentry.*auto-init|Sentry.*Retrieving|AppScoutStateMachine|FlingPromotion|ForceDarkHelper|MiuiForceDarkConfig|vulkan.*searching|libEGL.*shader cache|Perf.*Connecting|NativeTurboSchedManager|ashmem.*Pinning|EpFrameworkFactory" | grep --line-buffered -E "SmsReceiver|ClipboardListener|SMS|clipboard"
else
    # No PID available - monitor all logs
    adb_cmd logcat | grep -vE "MIUIInput|SKIA|VRI|RenderThread|Zygote|nativeloader|AssetManager2|ApplicationLoaders|ViewContentFactory|CompatChangeReporter|libc.*Access denied|TurboSchedMonitor|MiuiDownscaleImpl|MiuiMonitorThread|ResMonitorStub|MiuiAppAdaptationStubsControl|MiuiProcessManagerServiceStub|MiuiNBIManagerImpl|DecorViewImmersiveImpl|WM-WrkMgrInitializer|WM-PackageManagerHelper|WM-Schedulers|Adreno|Vulkan|libEGL|AdrenoVK|AdrenoUtils|SnapAlloc|qdgralloc|RenderLite|FramePredict|DecorView|ActivityThread.*HardwareRenderer|ActivityThread.*Miui Feature|ActivityThread.*TrafficStats|ActivityThread.*currentPkg|DesktopModeFlags|FirstFrameSpeedUp|ComputilityLevel|SLF4J|Sentry.*auto-init|Sentry.*Retrieving|AppScoutStateMachine|FlingPromotion|ForceDarkHelper|MiuiForceDarkConfig|vulkan.*searching|libEGL.*shader cache|Perf.*Connecting|NativeTurboSchedManager|ashmem.*Pinning|EpFrameworkFactory" | grep --line-buffered -E "SmsReceiver|ClipboardListener|SMS|clipboard"
fi

