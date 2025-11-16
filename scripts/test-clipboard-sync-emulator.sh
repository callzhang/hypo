#!/usr/bin/env bash
# Test clipboard sync on Android emulator
# Faster alternative to physical device testing

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SDK_ROOT=${ANDROID_SDK_ROOT:-${REPO_ROOT}/.android-sdk}
ADB="${SDK_ROOT}/platform-tools/adb"

echo "🧪 Clipboard Sync Test (Emulator)"
echo "=================================="
echo ""

# Check if emulator is running
if ! "${ADB}" devices | grep -q "emulator"; then
    echo "❌ No emulator detected. Starting emulator..."
    ./scripts/start-android-emulator.sh
    sleep 5
fi

# Build and install
echo "🔨 Building Android app..."
./scripts/build-android.sh

echo ""
echo "📋 Testing clipboard sync..."
echo "   The app should be installed and running"
echo ""
echo "📝 Test steps:"
echo "   1. Open the Hypo app on the emulator"
echo "   2. Grant clipboard permission if prompted"
echo "   3. Copy text on the emulator (long-press → Copy)"
echo "   4. Check logs below for sync activity"
echo ""
echo "📊 Monitoring logs (press Ctrl+C to stop)..."
echo ""

"${ADB}" logcat -c
"${ADB}" logcat | grep -E "(HistoryViewModel|ClipboardRepository|ClipboardListener|SyncCoordinator|Item saved|Flow emitted)"

