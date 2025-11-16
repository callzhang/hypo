#!/usr/bin/env bash
# Start Android Emulator for Hypo testing
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SDK_ROOT=${ANDROID_SDK_ROOT:-${REPO_ROOT}/.android-sdk}
EMULATOR="${SDK_ROOT}/emulator/emulator"
AVD_NAME="hypo_test_device"

# Check if emulator is installed
if [[ ! -x "${EMULATOR}" ]]; then
    echo "❌ Emulator not found. Run ./scripts/setup-android-emulator.sh first"
    exit 1
fi

# Check if AVD exists
if [[ ! -d "${HOME}/.android/avd/${AVD_NAME}.avd" ]]; then
    echo "❌ AVD '${AVD_NAME}' not found. Run ./scripts/setup-android-emulator.sh first"
    exit 1
fi

# Check if emulator is already running
if "${SDK_ROOT}/platform-tools/adb" devices | grep -q "emulator"; then
    echo "✅ Emulator is already running"
    "${SDK_ROOT}/platform-tools/adb" devices
    exit 0
fi

echo "🚀 Starting Android Emulator: ${AVD_NAME}..."
echo "   This may take 30-60 seconds on first launch"
echo ""

# Start emulator in background
"${EMULATOR}" -avd "${AVD_NAME}" -no-snapshot-load -wipe-data >/dev/null 2>&1 &
EMULATOR_PID=$!

echo "⏳ Waiting for emulator to boot..."
echo "   (PID: ${EMULATOR_PID})"

# Wait for emulator to be ready (up to 120 seconds)
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if "${SDK_ROOT}/platform-tools/adb" wait-for-device shell 'getprop sys.boot_completed' 2>/dev/null | grep -q "1"; then
        echo ""
        echo "✅ Emulator is ready!"
        "${SDK_ROOT}/platform-tools/adb" devices
        echo ""
        echo "To stop the emulator:"
        echo "  kill ${EMULATOR_PID}"
        echo "  or: ${SDK_ROOT}/platform-tools/adb emu kill"
        exit 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ $((ELAPSED % 10)) -eq 0 ]; then
        echo "   Still booting... (${ELAPSED}s elapsed)"
    fi
done

echo ""
echo "❌ Emulator failed to boot within ${TIMEOUT} seconds"
echo "   Check logs or try: ${EMULATOR} -avd ${AVD_NAME}"
exit 1

