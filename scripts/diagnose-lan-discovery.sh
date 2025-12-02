#!/bin/bash

# Diagnostic script to trace LAN discovery and connection issues
# Captures logs from Android and macOS to understand why peers are marked as "lost"

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get Android device ID (Xiaomi)
ANDROID_DEVICE=""
if [ -z "$ANDROID_DEVICE" ]; then
    # Try to find Xiaomi device
    ANDROID_DEVICE=$(adb devices | grep "0d50ce95" | head -1 | awk '{print $1}' || echo "")
    if [ -z "$ANDROID_DEVICE" ]; then
        # Try any connected device
        ANDROID_DEVICE=$(adb devices | grep -E "device$" | head -1 | awk '{print $1}' || echo "")
    fi
    if [ -z "$ANDROID_DEVICE" ]; then
        echo -e "${YELLOW}⚠️  No Android device found. Please specify device ID:${NC}"
        echo "Usage: $0 [android_device_id]"
        exit 1
    fi
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  LAN Discovery & Connection Diagnostic Tool${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}📱 Android Device: $ANDROID_DEVICE${NC}"
echo -e "${CYAN}🍎 macOS: Local${NC}"
echo ""

# Create temp directory for logs
TMPDIR=$(mktemp -d)
ANDROID_LOG="$TMPDIR/android.log"
MACOS_LOG="$TMPDIR/macos.log"
REPORT="$TMPDIR/report.txt"

echo -e "${GREEN}📊 Starting diagnostic capture...${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop and generate report${NC}"
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo -e "${BLUE}🛑 Stopping log capture...${NC}"
    kill $ANDROID_PID $MACOS_PID 2>/dev/null || true
    sleep 1
    kill -9 $ANDROID_PID $MACOS_PID 2>/dev/null || true
    
    echo -e "${GREEN}📋 Generating analysis report...${NC}"
    generate_report
    echo ""
    echo -e "${GREEN}✅ Report saved to: $REPORT${NC}"
    echo -e "${CYAN}📁 Raw logs: $TMPDIR${NC}"
    exit 0
}

trap cleanup INT TERM

generate_report() {
    {
        echo "═══════════════════════════════════════════════════════════"
        echo "  LAN Discovery & Connection Diagnostic Report"
        echo "  Generated: $(date)"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        
        # Android Discovery Events
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📱 ANDROID DISCOVERY EVENTS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -s "$ANDROID_LOG" ]; then
            grep -E "(Service found|Service resolved|onServiceLost|Service lost|reported as lost)" "$ANDROID_LOG" | tail -20 || echo "No discovery events found"
        else
            echo "No Android logs captured"
        fi
        echo ""
        
        # Android Connection Attempts
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📱 ANDROID CONNECTION ATTEMPTS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -s "$ANDROID_LOG" ]; then
            grep -E "(connection attempt|ws://10\.0\.0\.107|Connection.*failed|retrying|WebSocket connection)" "$ANDROID_LOG" | tail -20 || echo "No connection attempts found"
        else
            echo "No connection logs found"
        fi
        echo ""
        
        # Android Transport Status
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📱 ANDROID TRANSPORT STATUS CHANGES"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -s "$ANDROID_LOG" ]; then
            grep -E "(markDeviceConnected|ActiveTransport|CLOUD|LAN|lastSuccessfulTransport|ConnectionState)" "$ANDROID_LOG" | tail -20 || echo "No transport status changes found"
        else
            echo "No transport status logs found"
        fi
        echo ""
        
        # macOS Bonjour Events
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🍎 macOS BONJOUR ADVERTISING"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -s "$MACOS_LOG" ]; then
            grep -E "(Bonjour|publish|advertising|service.*registered|service.*stopped)" "$MACOS_LOG" | tail -20 || echo "No Bonjour events found"
        else
            echo "No macOS logs captured"
        fi
        echo ""
        
        # macOS Connection Status
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🍎 macOS CONNECTION STATUS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ -s "$MACOS_LOG" ]; then
            grep -E "(activeConnections|Connection.*established|Connection.*closed|discoveredPeers)" "$MACOS_LOG" | tail -20 || echo "No connection status found"
        else
            echo "No connection status logs found"
        fi
        echo ""
        
        # Analysis
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔍 ANALYSIS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Count events
        SERVICE_FOUND=$(grep -c "Service found" "$ANDROID_LOG" 2>/dev/null || echo "0")
        SERVICE_LOST=$(grep -c "onServiceLost\|Service lost\|reported as lost" "$ANDROID_LOG" 2>/dev/null || echo "0")
        CONN_ATTEMPTS=$(grep -c "connection attempt.*10\.0\.0\.107" "$ANDROID_LOG" 2>/dev/null || echo "0")
        CONN_FAILED=$(grep -c "Connection.*failed.*10\.0\.0\.107" "$ANDROID_LOG" 2>/dev/null || echo "0")
        CLOUD_TRANSPORT=$(grep -c "ActiveTransport.*CLOUD\|markDeviceConnected.*CLOUD" "$ANDROID_LOG" 2>/dev/null || echo "0")
        LAN_TRANSPORT=$(grep -c "ActiveTransport.*LAN\|markDeviceConnected.*LAN" "$ANDROID_LOG" 2>/dev/null || echo "0")
        
        echo "Event Counts:"
        echo "  • Services Found: $SERVICE_FOUND"
        echo "  • Services Lost: $SERVICE_LOST"
        echo "  • Connection Attempts (LAN): $CONN_ATTEMPTS"
        echo "  • Connection Failures (LAN): $CONN_FAILED"
        echo "  • Cloud Transport Activations: $CLOUD_TRANSPORT"
        echo "  • LAN Transport Activations: $LAN_TRANSPORT"
        echo ""
        
        # Check for patterns
        if [ "$SERVICE_LOST" -gt "$SERVICE_FOUND" ]; then
            echo "⚠️  ISSUE: More services lost than found - discovery is unstable"
        fi
        
        if [ "$CONN_FAILED" -gt 0 ] && [ "$LAN_TRANSPORT" -eq 0 ]; then
            echo "⚠️  ISSUE: LAN connection attempts failing, falling back to cloud"
        fi
        
        if [ "$CLOUD_TRANSPORT" -gt "$LAN_TRANSPORT" ]; then
            echo "⚠️  ISSUE: System prefers cloud over LAN transport"
        fi
        
        # Check timing correlation
        echo ""
        echo "Timeline Analysis:"
        echo "  Checking for correlation between service lost and connection attempts..."
        
        if [ -s "$ANDROID_LOG" ]; then
            LAST_LOST=$(grep "onServiceLost\|reported as lost" "$ANDROID_LOG" | tail -1 | cut -d' ' -f1-2 || echo "")
            LAST_ATTEMPT=$(grep "connection attempt.*10\.0\.0\.107" "$ANDROID_LOG" | tail -1 | cut -d' ' -f1-2 || echo "")
            
            if [ -n "$LAST_LOST" ] && [ -n "$LAST_ATTEMPT" ]; then
                echo "  • Last service lost: $LAST_LOST"
                echo "  • Last connection attempt: $LAST_ATTEMPT"
            fi
        fi
        
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  End of Report"
        echo "═══════════════════════════════════════════════════════════"
    } > "$REPORT"
    
    cat "$REPORT"
}

# Start Android log capture
echo -e "${BLUE}📱 Starting Android log capture...${NC}"
adb -s "$ANDROID_DEVICE" logcat -c > /dev/null 2>&1 || true
adb -s "$ANDROID_DEVICE" logcat -v time \
    | grep -E "(Service found|Service resolved|onServiceLost|Service lost|dereks-macbook|007E4A95|LanWebSocketClient|connection attempt|ws://10\.0\.0\.107|Connection.*failed|retrying|markDeviceConnected|ActiveTransport|CLOUD|LAN|lastSuccessfulTransport|reported as lost|Peer.*lost|discovered.*peer)" \
    | tee "$ANDROID_LOG" &
ANDROID_PID=$!

# Start macOS log capture
echo -e "${BLUE}🍎 Starting macOS log capture...${NC}"
log stream --predicate 'subsystem == "com.hypo.clipboard"' --style compact \
    | grep -E "(Bonjour|publish|advertising|service.*registered|service.*stopped|LanWebSocketServer|Connection.*established|Connection.*closed|activeConnections|discoveredPeers)" \
    | tee "$MACOS_LOG" &
MACOS_PID=$!

echo -e "${GREEN}✅ Both log streams started${NC}"
echo -e "${YELLOW}📝 Logs are being captured...${NC}"
echo ""

# Wait for user interrupt
wait
