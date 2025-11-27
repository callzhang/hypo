#!/bin/bash
# Unified pairing monitoring script - monitors both Android and macOS logs
# Replaces: monitor-pairing-debug.sh, monitor-pairing-test.sh, watch-pairing-logs.sh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$PROJECT_ROOT/.android-sdk}"
MACOS_APP="$PROJECT_ROOT/macos/HypoApp.app"

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

# Parse mode argument
MODE="${1:-watch}"  # watch, debug, or test

case "$MODE" in
    watch)
        log_info "🔍 Watching pairing logs in real-time..."
        ;;
    debug)
        log_info "🔍 Starting comprehensive pairing debug monitor..."
        # Stop existing macOS app
        log_info "Stopping existing macOS app..."
        pkill -f "HypoMenuBar" 2>/dev/null || true
        sleep 2
        
        # Start macOS app
        log_info "Starting macOS app..."
        if [ -d "$MACOS_APP" ]; then
            open "$MACOS_APP"
            log_success "macOS app launched"
            sleep 3
        else
            log_error "macOS app not found at $MACOS_APP"
            exit 1
        fi
        
        # Verify WebSocket server
        log_info "Checking if WebSocket server is listening on port 7010..."
        if lsof -i :7010 | grep -q "HypoMenuBar"; then
            log_success "WebSocket server is listening on port 7010"
        else
            log_warning "WebSocket server may not be running yet, waiting..."
            sleep 2
            if lsof -i :7010 | grep -q "HypoMenuBar"; then
                log_success "WebSocket server is now listening"
            else
                log_error "WebSocket server is not listening on port 7010"
            fi
        fi
        ;;
    test)
        log_info "🧪 Pairing test mode - monitoring for 60 seconds..."
        ;;
    *)
        echo "Usage: $0 [watch|debug|test]"
        echo "  watch: Simple real-time log monitoring (default)"
        echo "  debug: Full debug mode (stops/starts macOS app, verifies services)"
        echo "  test: Test mode (monitors for 60 seconds then exits)"
        exit 1
        ;;
esac

# Clear Android logs
log_info "Clearing Android logs..."
"$ANDROID_SDK_ROOT/platform-tools/adb" logcat -c 2>/dev/null || log_warning "Could not clear Android logs"

log_info ""
log_info "═══════════════════════════════════════════════════════════"
log_info "🔍 PAIRING MONITOR - Ready"
log_info "═══════════════════════════════════════════════════════════"
log_info ""
log_info "Please initiate pairing from Android now..."
[ "$MODE" != "test" ] && log_info "Press Ctrl+C to stop monitoring"
log_info ""

# Monitor Android logs
(
    "$ANDROID_SDK_ROOT/platform-tools/adb" logcat | grep -v "MIUIInput" | grep -E "LanPairingViewModel|LanWebSocketClient|pairing|Pairing|WebSocket|Connection|challenge|ACK|sendRawJson|onOpen|onFailure|onMessage" | while IFS= read -r line; do
        echo -e "${BLUE}[ANDROID]${NC} $line"
    done
) &
ANDROID_PID=$!

# Monitor macOS logs
log stream --predicate 'process == "HypoMenuBar"' --level debug 2>/dev/null | grep -E "LanWebSocketServer|pairing|challenge|Connection|Received|WebSocket|ACK|❌|✅|⚠️|📥|📤|🔌|📋|🔔|🟡|⏳" | while IFS= read -r line; do
    echo -e "${GREEN}[macOS]${NC} $line"
done &
MACOS_PID=$!

# Monitor debug log file
if [ -f "/tmp/hypo_debug.log" ]; then
    tail -f /tmp/hypo_debug.log 2>/dev/null | while IFS= read -r line; do
        echo -e "${YELLOW}[DEBUG]${NC} $line"
    done &
    DEBUG_PID=$!
fi

# Cleanup on exit
trap "kill $ANDROID_PID $MACOS_PID ${DEBUG_PID:-} 2>/dev/null; exit" INT TERM

# Wait based on mode
if [ "$MODE" = "test" ]; then
    sleep 60
    kill $ANDROID_PID $MACOS_PID ${DEBUG_PID:-} 2>/dev/null || true
    log_info "Test monitoring complete"
else
    wait $ANDROID_PID $MACOS_PID ${DEBUG_PID:-} 2>/dev/null || true
fi


