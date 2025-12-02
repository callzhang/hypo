#!/bin/bash
# Automated Clipboard Sync Test Script for Android Emulator
# Tests clipboard sync between Android emulator and macOS app

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Detect Android SDK - prefer Android Studio SDK
if [ -d "$HOME/Library/Android/sdk" ]; then
    ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
    echo -e "${GREEN}Using Android Studio SDK: $ANDROID_SDK_ROOT${NC}"
elif [ -d "$PROJECT_ROOT/.android-sdk" ]; then
    ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
    echo -e "${GREEN}Using project SDK: $ANDROID_SDK_ROOT${NC}"
else
    echo -e "${RED}❌ Android SDK not found${NC}"
    exit 1
fi

ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"

# Verify emulator exists
if [ ! -f "$EMULATOR" ]; then
    echo -e "${RED}❌ Emulator not found at $EMULATOR${NC}"
    exit 1
fi

# Check if emulator is running
echo -e "${BLUE}=== Checking emulator status ===${NC}"
DEVICES=$("$ADB" devices 2>/dev/null | grep -v "List" | grep "device" | wc -l | tr -d ' ')
if [ "$DEVICES" -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No emulator running. Starting emulator...${NC}"
    AVD=$("$EMULATOR" -list-avds 2>/dev/null | head -1)
    if [ -z "$AVD" ]; then
        echo -e "${RED}❌ No AVD found. Please create one in Android Studio.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Starting AVD: $AVD${NC}"
    "$EMULATOR" -avd "$AVD" -no-snapshot-load -no-audio -gpu host >/dev/null 2>&1 &
    EMULATOR_PID=$!
    echo -e "${YELLOW}Waiting for emulator to boot (max 60 seconds)...${NC}"
    
    # Wait for device with timeout
    TIMEOUT=60
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if "$ADB" devices 2>/dev/null | grep -q "device$"; then
            echo -e "${GREEN}✅ Emulator detected${NC}"
            break
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        echo -n "."
    done
    echo ""
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo -e "${RED}❌ Emulator failed to start within $TIMEOUT seconds${NC}"
        kill $EMULATOR_PID 2>/dev/null || true
        exit 1
    fi
    
    sleep 5  # Give it a bit more time to fully boot
    echo -e "${GREEN}✅ Emulator ready${NC}"
else
    echo -e "${GREEN}✅ Emulator already running${NC}"
fi

# Build and install
echo -e "${BLUE}=== Building and installing app ===${NC}"
cd android
# Use system Java - let Gradle find it automatically
unset JAVA_HOME
echo -e "${YELLOW}Building (this may take a minute)...${NC}"
if ./gradlew assembleDebug 2>&1 | tee /tmp/gradle-build.log | tail -10; then
    echo -e "${GREEN}✅ Build complete${NC}"
else
    echo -e "${RED}❌ Build failed. Check /tmp/gradle-build.log${NC}"
    exit 1
fi

"$ADB" install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null 2>&1
echo -e "${GREEN}✅ App installed${NC}"

# Clear logs and start app
echo -e "${BLUE}=== Starting app ===${NC}"
"$ADB" logcat -c
"$ADB" shell am force-stop com.hypo.clipboard.debug >/dev/null 2>&1
sleep 1
"$ADB" shell am start -n com.hypo.clipboard.debug/com.hypo.clipboard.MainActivity >/dev/null 2>&1
sleep 3
echo -e "${GREEN}✅ App started${NC}"

# Check macOS app
echo -e "${BLUE}=== Checking macOS app ===${NC}"
if lsof -i :7010 | grep -q LISTEN; then
    echo -e "${GREEN}✅ macOS app listening on port 7010${NC}"
    MAC_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1)
    echo -e "${GREEN}   macOS IP: $MAC_IP${NC}"
else
    echo -e "${YELLOW}⚠️  macOS app not listening on port 7010${NC}"
fi

# Test clipboard sync
echo -e "${BLUE}=== Testing clipboard sync ===${NC}"
"$ADB" logcat -c
echo -e "${YELLOW}Waiting 10 seconds for clipboard events...${NC}"
echo -e "${YELLOW}(You can copy text on emulator during this time)${NC}"

# Try to simulate clipboard copy
TEST_TEXT="SyncTest$(date +%s)"
echo -e "${YELLOW}Attempting to set clipboard: $TEST_TEXT${NC}"
"$ADB" shell "service call clipboard 1 i32 1 s16 'text/plain' s16 '$TEST_TEXT'" 2>/dev/null || true

# Wait for events
sleep 10

# Check logs
echo -e "${BLUE}=== Checking sync logs ===${NC}"
CLIPBOARD_EVENTS=$("$ADB" logcat -d | grep -c "NEW clipboard event" || echo "0")
SYNC_ATTEMPTS=$("$ADB" logcat -d | grep -c "Syncing to device" || echo "0")
TRANSPORT_SEND=$("$ADB" logcat -d | grep -c "transport.send()" || echo "0")
WEBSOCKET_SEND=$("$ADB" logcat -d | grep -c "send() called" || echo "0")
CONNECTED=$("$ADB" logcat -d | grep -c "Connection established\|onOpen" || echo "0")
KEY_LOADED=$("$ADB" logcat -d | grep -c "Key loaded" || echo "0")

echo -e "${BLUE}Results:${NC}"
echo -e "  Clipboard events detected: ${GREEN}$CLIPBOARD_EVENTS${NC}"
echo -e "  Sync attempts: ${GREEN}$SYNC_ATTEMPTS${NC}"
echo -e "  transport.send() calls: ${GREEN}$TRANSPORT_SEND${NC}"
echo -e "  WebSocket send() calls: ${GREEN}$WEBSOCKET_SEND${NC}"
echo -e "  WebSocket connected: ${GREEN}$CONNECTED${NC}"
echo -e "  Keys loaded: ${GREEN}$KEY_LOADED${NC}"

# Show recent sync logs
echo -e "${BLUE}=== Recent sync activity ===${NC}"
"$ADB" logcat -d | grep -E "(NEW clipboard|Received clipboard|Broadcasting|Syncing|transport.send|send\(\) called|Key loaded|Connection)" | tail -15

# Check for errors
ERROR_COUNT=$("$ADB" logcat -d | grep -E "(Failed|Error|Exception)" | grep -E "(SyncEngine|LanWebSocketClient)" | wc -l | tr -d ' ')
if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${RED}=== Errors found ($ERROR_COUNT) ===${NC}"
    "$ADB" logcat -d | grep -E "(Failed|Error|Exception)" | grep -E "(SyncEngine|LanWebSocketClient)" | tail -10
fi

echo -e "${GREEN}✅ Test complete${NC}"

