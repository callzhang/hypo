#!/bin/bash
# Monitor pairing test - captures logs from both Android and macOS simultaneously

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$PROJECT_ROOT/.android-sdk}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Check Android device
if [ ! -f "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
    log_error "ADB not found at $ANDROID_SDK_ROOT/platform-tools/adb"
    exit 1
fi

ADB="$ANDROID_SDK_ROOT/platform-tools/adb"

DEVICE_CHECK=$("$ADB" devices 2>/dev/null | grep -q "device$" && echo "yes" || echo "no")
if [ "$DEVICE_CHECK" != "yes" ]; then
    log_error "No Android device connected"
    exit 1
fi

log_info "🔍 Starting pairing test monitoring..."
echo ""

# Clear Android logs
log_info "Clearing Android logs..."
"$ADB" logcat -c
log_success "Android logs cleared"

echo ""
log_warning "📱 Please initiate LAN pairing from Android now..."
log_info "Monitoring will continue for 40 seconds..."
echo ""

# Function to monitor Android logs
monitor_android() {
    "$ADB" logcat | grep -E "LanPairingViewModel|LanWebSocketClient|pairing|Pairing|ACK|timeout|onOpen|sendRawJson|WebSocket|Challenge" | while IFS= read -r line; do
        echo -e "${BLUE}[ANDROID]${NC} $line"
    done
}

# Function to monitor macOS logs
monitor_macos() {
    log stream --predicate 'subsystem == "com.hypo.clipboard" && category == "lan-server"' --level debug 2>/dev/null | while IFS= read -r line; do
        echo -e "${GREEN}[macOS]${NC} $line"
    done
}

# Also monitor general macOS process logs
monitor_macos_general() {
    log show --predicate 'process == "HypoMenuBar"' --style compact 2>/dev/null | grep -E "🔑|key|Key|🔔|newConnectionHandler|Connection|pairing|challenge|ACK|handshake|WebSocket|🔌|📥|✅|❌" | while IFS= read -r line; do
        echo -e "${GREEN}[macOS]${NC} $line"
    done
}

# Run monitoring in background
monitor_android &
ANDROID_PID=$!

monitor_macos &
MACOS_PID=$!

monitor_macos_general &
MACOS_GENERAL_PID=$!

# Wait for timeout or Ctrl+C
trap "kill $ANDROID_PID $MACOS_PID $MACOS_GENERAL_PID 2>/dev/null; exit" INT TERM

sleep 40

# Stop monitoring
kill $ANDROID_PID $MACOS_PID $MACOS_GENERAL_PID 2>/dev/null || true

echo ""
log_info "📊 Gathering final logs..."
echo ""

# Get final Android logs
log_info "=== Final Android Logs ==="
"$ADB" logcat -d | grep -E "LanPairingViewModel|LanWebSocketClient|pairing|Pairing|ACK|timeout|onOpen|sendRawJson|WebSocket|Challenge" | tail -20

echo ""
log_info "=== Final macOS Logs ==="
log show --predicate 'process == "HypoMenuBar"' --last 40s --style compact 2>/dev/null | grep -E "🔑|key|Key|🔔|newConnectionHandler|Connection|pairing|challenge|ACK|handshake|WebSocket|🔌|📥|✅|❌" | tail -20

echo ""
log_success "Monitoring complete!"

