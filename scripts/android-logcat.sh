#!/bin/bash
# Android logcat wrapper that automatically filters out MIUIInput and other system noise
# Usage: 
#   ./scripts/android-logcat.sh [device_id]
#   ./scripts/android-logcat.sh [device_id] --pid=<pid> | grep "pattern"
#   ./scripts/android-logcat.sh [device_id] | grep "pattern"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Get Android SDK
if [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    if [ -d "$PROJECT_ROOT/.android-sdk" ]; then
        export ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
    elif [ -d "$HOME/Library/Android/sdk" ]; then
        export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
    else
        echo "❌ ANDROID_SDK_ROOT not set"
        exit 1
    fi
fi

ADB_PATH="$ANDROID_SDK_ROOT/platform-tools/adb"
ADB_ARGS=()

# Check if device ID is provided as first argument
DEVICE_ID=""
if [ $# -gt 0 ] && ([[ "$1" =~ ^[0-9a-f]+$ ]] || [[ "$1" == "emulator-"* ]]); then
    DEVICE_ID="$1"
    ADB_ARGS+=("-s" "$DEVICE_ID")
    shift
else
    # No device ID provided - check connected devices
    if ! DEVICES_OUTPUT=$("$ADB_PATH" devices 2>&1); then
        echo "❌ Failed to query ADB devices"
        echo "   Error: $DEVICES_OUTPUT"
        exit 1
    fi
    
    # Parse device list (lines ending with "device" or "unauthorized", excluding header)
    DEVICE_LIST=$(echo "$DEVICES_OUTPUT" | grep -E "(device|unauthorized)$" | grep -v "^List of devices")
    DEVICE_COUNT=$(echo "$DEVICE_LIST" | wc -l | tr -d ' ')
    
    if [ "$DEVICE_COUNT" -eq 0 ]; then
        echo "❌ No Android devices connected"
        echo ""
        echo "📋 Connect a device and try again, or specify device ID:"
        echo "   ./scripts/android-logcat.sh <device_id>"
        exit 1
    elif [ "$DEVICE_COUNT" -gt 1 ]; then
        # Multiple devices - prefer physical device over emulator
        PHYSICAL_DEVICE=$(echo "$DEVICE_LIST" | grep -v "emulator-" | awk '{print $1}' | head -1)
        
        if [ -n "$PHYSICAL_DEVICE" ]; then
            # Use physical device automatically
            DEVICE_ID="$PHYSICAL_DEVICE"
            ADB_ARGS+=("-s" "$DEVICE_ID")
            echo "📱 Multiple devices detected, using physical device: $DEVICE_ID" >&2
        else
            # All are emulators or no physical device found - show error
            echo "❌ Multiple devices connected. Please specify device ID:"
            echo ""
            echo "📱 Connected devices:"
            echo "$DEVICE_LIST" | while read -r line; do
                DEV_ID=$(echo "$line" | awk '{print $1}')
                DEV_STATUS=$(echo "$line" | awk '{print $2}')
                echo "   $DEV_ID ($DEV_STATUS)"
            done
            echo ""
            echo "Usage: ./scripts/android-logcat.sh <device_id>"
            exit 1
        fi
    else
        # Single device - use it automatically
        DEVICE_ID=$(echo "$DEVICE_LIST" | awk '{print $1}' | head -1)
        if [ -z "$DEVICE_ID" ]; then
            echo "❌ Failed to detect device ID"
            exit 1
        fi
        ADB_ARGS+=("-s" "$DEVICE_ID")
    fi
fi

# Check if --pid is in the arguments
HAS_PID=false
PID_VALUE=""
REMAINING_ARGS=()

for arg in "$@"; do
    if [[ "$arg" == --pid=* ]]; then
        HAS_PID=true
        PID_VALUE="${arg#--pid=}"
        # Don't add to REMAINING_ARGS - we'll handle it separately
    elif [[ "$arg" == --pid ]]; then
        HAS_PID=true
        # Next argument should be the PID
        continue
    else
        REMAINING_ARGS+=("$arg")
    fi
done

# Build logcat command
if [ "$HAS_PID" = true ] && [ -n "$PID_VALUE" ]; then
    # Use PID-based filtering with MIUIInput exclusion
    exec "$ADB_PATH" "${ADB_ARGS[@]}" logcat --pid="$PID_VALUE" | grep -v "MIUIInput" "${REMAINING_ARGS[@]}"
elif [ $# -gt 0 ]; then
    # User provided custom arguments - pipe through grep to filter MIUIInput
    exec "$ADB_PATH" "${ADB_ARGS[@]}" logcat "$@" | grep -v "MIUIInput"
else
    # Default: show app logs only, exclude MIUIInput
    exec "$ADB_PATH" "${ADB_ARGS[@]}" logcat -v time "*:S" "com.hypo.clipboard.debug:D" "com.hypo.clipboard:D" | grep -v "MIUIInput"
fi

