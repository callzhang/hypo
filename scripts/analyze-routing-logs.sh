#!/bin/bash
# Analyze backend routing logs to count messages sent to each device

set -euo pipefail

echo "=== Backend Message Routing Analysis ==="
echo ""

# Check if flyctl is available
if ! command -v flyctl &> /dev/null; then
    echo "❌ Error: flyctl not found. Please install Fly.io CLI or use full path."
    echo "   Example: /Users/derek/.fly/bin/flyctl logs --app hypo --limit 2000"
    exit 1
fi

# Get logs
echo "📥 Fetching backend logs..."
LOGS=$(flyctl logs --app hypo --limit 2000 2>&1)

# Count routing attempts
TOTAL_ATTEMPTS=$(echo "$LOGS" | grep -c "\[ROUTING\].*targeting device" || echo "0")

# Count successful routings to each device
MACOS_COUNT=$(echo "$LOGS" | grep -c "Successfully routed.*to target device: 007E4A95-0E1A-4B10-91FA-87942EFAA68E" || echo "0")
ANDROID_COUNT=$(echo "$LOGS" | grep -c "Successfully routed.*to target device: c7bd7e23-b5c1-4dfd-bb62-6a3b7c880760" || echo "0")

# Count failed routings
FAILED_COUNT=$(echo "$LOGS" | grep -c "Target device.*not connected" || echo "0")

# Get other device IDs that received messages
OTHER_DEVICES=$(echo "$LOGS" | grep "Successfully routed.*to target device:" | \
    grep -oE "to target device: [a-fA-F0-9-]+" | \
    cut -d' ' -f4 | \
    grep -v "007E4A95-0E1A-4B10-91FA-87942EFAA68E" | \
    grep -v "c7bd7e23-b5c1-4dfd-bb62-6a3b7c880760" | \
    sort | uniq -c | sort -rn || echo "")

echo "📊 Summary Statistics:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total routing attempts: $TOTAL_ATTEMPTS"
echo ""
echo "✅ Successful routings:"
echo "   macOS (007E4A95-0E1A-4B10-91FA-87942EFAA68E): $MACOS_COUNT messages"
echo "   Android (c7bd7e23-b5c1-4dfd-bb62-6a3b7c880760): $ANDROID_COUNT messages"
echo ""
if [ -n "$OTHER_DEVICES" ] && [ "$OTHER_DEVICES" != "0" ]; then
    echo "   Other devices:"
    echo "$OTHER_DEVICES" | while read count device; do
        echo "     $device: $count messages"
    done
fi
echo ""
echo "❌ Failed routings: $FAILED_COUNT"
echo ""

# Show recent routing activity
echo "📋 Recent Routing Activity (Last 10 messages):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$LOGS" | grep -E "\[ROUTING\].*targeting device|\[ROUTING\].*Successfully routed|\[ROUTING\].*Target device.*not connected" | tail -10 | while read line; do
    timestamp=$(echo "$line" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || echo "unknown")
    if echo "$line" | grep -q "targeting device:"; then
        device=$(echo "$line" | grep -oE "targeting device: [a-fA-F0-9-]+" | cut -d' ' -f3)
        echo "  $timestamp [ATTEMPT] Targeting: $device"
    elif echo "$line" | grep -q "Successfully routed.*to target device:"; then
        device=$(echo "$line" | grep -oE "to target device: [a-fA-F0-9-]+" | cut -d' ' -f4)
        echo "  $timestamp [SUCCESS] Routed to: $device"
    elif echo "$line" | grep -q "Target device.*not connected"; then
        device=$(echo "$line" | grep -oE "Target device [a-fA-F0-9-]+" | cut -d' ' -f3)
        echo "  $timestamp [FAILED]  Device not connected: $device"
    fi
done

echo ""
echo "💡 Tip: For more detailed logs, run:"
echo "   flyctl logs --app hypo --limit 5000 | grep '\[ROUTING\]'"

