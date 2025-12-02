#!/bin/bash
# Test clipboard polling implementation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check for Android SDK
if [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    if [ -d "$PROJECT_ROOT/.android-sdk" ]; then
        export ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
    else
        echo -e "${RED}❌ ANDROID_SDK_ROOT not set and .android-sdk not found${NC}"
        exit 1
    fi
fi

ADB="$ANDROID_SDK_ROOT/platform-tools/adb"

if [ ! -f "$ADB" ]; then
    echo -e "${RED}❌ ADB not found at $ADB${NC}"
    exit 1
fi

# Check for connected device
DEVICE_CHECK=$("$ADB" devices 2>/dev/null | grep -q "device$" && echo "yes" || echo "no")

if [ "$DEVICE_CHECK" != "yes" ]; then
    echo -e "${RED}❌ No Android device connected${NC}"
    exit 1
fi

echo -e "${YELLOW}=== Clipboard Polling Test ===${NC}"
echo ""
echo "This test will:"
echo "1. Clear logs"
echo "2. Monitor clipboard activity for 30 seconds"
echo "3. Show results"
echo ""
echo -e "${YELLOW}📋 INSTRUCTIONS:${NC}"
echo "   While monitoring, please:"
echo "   1. Open any app on your device (Notes, Browser, etc.)"
echo "   2. Select and copy some text manually"
echo "   3. Wait a few seconds"
echo "   4. Check if it appears in Hypo app history"
echo ""
read -p "Press Enter to start monitoring (or Ctrl+C to cancel)..."

echo ""
echo -e "${YELLOW}Clearing logs and starting monitoring...${NC}"
"$ADB" logcat -c

echo -e "${GREEN}✅ Monitoring for 30 seconds...${NC}"
echo "   (Copy some text on your device now!)"
echo ""

# Monitor for 30 seconds
"$ADB" logcat | grep --line-buffered -E "(ClipboardListener|Polling detected|onPrimaryClipChanged|NEW clipboard|Processing clip|Event signature|SyncCoordinator.*Received clipboard|History Flow emitted)" &
MONITOR_PID=$!

sleep 30

kill $MONITOR_PID 2>/dev/null || true

echo ""
echo -e "${YELLOW}=== Test Results ===${NC}"
echo ""

# Check results
POLLING_STARTED=$("$ADB" logcat -d -t 60 | grep -c "Starting clipboard polling" || echo "0")
CLIPBOARD_EVENTS=$("$ADB" logcat -d -t 60 | grep -c "NEW clipboard event" || echo "0")
POLLING_DETECTED=$("$ADB" logcat -d -t 60 | grep -c "Polling detected" || echo "0")
LISTENER_TRIGGERED=$("$ADB" logcat -d -t 60 | grep -c "onPrimaryClipChanged TRIGGERED" || echo "0")

echo "📊 Statistics:"
echo "   Polling instances started: $POLLING_STARTED"
echo "   Clipboard events detected: $CLIPBOARD_EVENTS"
echo "   Manual changes (polling): $POLLING_DETECTED"
echo "   Listener callbacks: $LISTENER_TRIGGERED"
echo ""

if [ "$CLIPBOARD_EVENTS" -gt 0 ]; then
    echo -e "${GREEN}✅ Clipboard events detected!${NC}"
else
    echo -e "${YELLOW}⚠️  No clipboard events detected${NC}"
    echo "   This could mean:"
    echo "   - No text was copied during the test"
    echo "   - Clipboard access permission not granted"
    echo "   - App is not in foreground"
fi

if [ "$POLLING_DETECTED" -gt 0 ]; then
    echo -e "${GREEN}✅ Polling detected manual clipboard changes!${NC}"
else
    echo -e "${YELLOW}⚠️  Polling did not detect manual changes${NC}"
fi

echo ""
echo -e "${YELLOW}=== Recent Clipboard Activity ===${NC}"
"$ADB" logcat -d -t 60 | grep -E "(ClipboardListener|Polling detected|NEW clipboard|onPrimaryClipChanged)" | tail -20

echo ""
echo -e "${YELLOW}=== Test Complete ===${NC}"
echo "Check the Hypo app history tab to see if copied items appear."

