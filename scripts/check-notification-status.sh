#!/bin/bash
# Script to check Android notification status for Hypo app

set -e

DEVICE_ID="${1:-}"
if [ -z "$DEVICE_ID" ]; then
    echo "Usage: $0 <device_id>"
    echo ""
    echo "Available devices:"
    adb devices -l | grep -v "List" | awk '{print $1 " - " $NF}'
    exit 1
fi

ADB="adb -s $DEVICE_ID"

echo "=== Hypo Notification Status Check ==="
echo "Device: $DEVICE_ID"
echo ""

# Get app PID
APP_PID=$($ADB shell pidof -s com.hypo.clipboard.debug 2>/dev/null || echo "")
if [ -z "$APP_PID" ]; then
    echo "❌ App is not running (com.hypo.clipboard.debug)"
    echo "   Please start the app first"
    exit 1
fi

echo "✅ App is running (PID: $APP_PID)"
echo ""

# Check notification logs
echo "=== Recent Notification Logs ==="
$ADB logcat -d --pid=$APP_PID | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep -E "ClipboardSyncService|Notification|notification" | tail -30
echo ""

# Check for notification channel creation
echo "=== Notification Channel Status ==="
CHANNEL_LOG=$($ADB logcat -d --pid=$APP_PID | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep "Notification channel created" | tail -1)
if [ -n "$CHANNEL_LOG" ]; then
    echo "$CHANNEL_LOG"
else
    echo "⚠️  No notification channel creation log found"
fi
echo ""

# Check for foreground service start
echo "=== Foreground Service Status ==="
FOREGROUND_LOG=$($ADB logcat -d --pid=$APP_PID | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep -E "Foreground service|startForeground" | tail -3)
if [ -n "$FOREGROUND_LOG" ]; then
    echo "$FOREGROUND_LOG"
else
    echo "⚠️  No foreground service start log found"
fi
echo ""

# Check for notification update logs
echo "=== Notification Update Logs ==="
UPDATE_LOG=$($ADB logcat -d --pid=$APP_PID | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep "Notification updated" | tail -5)
if [ -n "$UPDATE_LOG" ]; then
    echo "$UPDATE_LOG"
else
    echo "⚠️  No notification update logs found"
fi
echo ""

# Check for errors
echo "=== Notification Errors ==="
ERROR_LOG=$($ADB logcat -d --pid=$APP_PID | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep -E "Notification.*[Ee]rror|Failed.*notification|CRITICAL.*notification" | tail -10)
if [ -n "$ERROR_LOG" ]; then
    echo "$ERROR_LOG"
else
    echo "✅ No notification errors found"
fi
echo ""

# Check observeLatestItem
echo "=== Latest Item Observation ==="
OBSERVE_LOG=$($ADB logcat -d --pid=$APP_PID | grep -vE "MIUIInput|SKIA|VRI|RenderThread" | grep -E "observe.*latest|Latest item changed" | tail -5)
if [ -n "$OBSERVE_LOG" ]; then
    echo "$OBSERVE_LOG"
else
    echo "⚠️  No latest item observation logs found"
fi
echo ""

echo "=== Recommendations ==="
echo "1. Check if notifications are enabled: Settings → Apps → Hypo → Notifications"
echo "2. Check if 'Clipboard Sync' channel is enabled: Settings → Apps → Hypo → Notifications → Clipboard Sync"
echo "3. Check if channel importance is DEFAULT (not NONE or LOW)"
echo "4. Check logs above for any errors or warnings"
echo ""
echo "To monitor in real-time:"
echo "  adb -s $DEVICE_ID logcat --pid=$APP_PID | grep -vE 'MIUIInput|SKIA|VRI|RenderThread' | grep -E 'ClipboardSyncService|Notification'"

