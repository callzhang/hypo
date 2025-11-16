#!/bin/bash
# Reopen the Hypo Android app on connected device

set -uo pipefail  # Remove -e to allow error handling

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
    echo "   Please connect your device and enable USB debugging"
    exit 1
fi

echo -e "${YELLOW}Opening Hypo app...${NC}"

# Try multiple methods to open the app (suppress errors to try all methods)
if "$ADB" shell am start -n com.hypo.clipboard/.MainActivity >/dev/null 2>&1; then
    echo -e "${GREEN}✅ App opened successfully${NC}"
    exit 0
fi

if "$ADB" shell am start -a android.intent.action.MAIN -n com.hypo.clipboard/.MainActivity >/dev/null 2>&1; then
    echo -e "${GREEN}✅ App opened successfully${NC}"
    exit 0
fi

if "$ADB" shell monkey -p com.hypo.clipboard -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    echo -e "${GREEN}✅ App opened successfully${NC}"
    exit 0
fi

echo -e "${YELLOW}⚠️  Could not auto-open app. Please open manually.${NC}"
exit 1

