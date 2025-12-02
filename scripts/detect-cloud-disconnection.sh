#!/bin/bash
# Detect cloud disconnection events and capture last 3 seconds of logs
# Only monitors emulator device

set -euo pipefail

# Configuration
# EMULATOR_DEVICE="emulator-5554"
EMULATOR_DEVICE="797e3471"
LOG_PATTERN="WebSocketTransportClient.*cloud|onClosed|onFailure|Event-driven|Applying exponential backoff|Connection failed|WebSocket closed"
OUTPUT_DIR="${HOME}/hypo_logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔍 Cloud Disconnection Detection Script${NC}"
echo -e "${YELLOW}Monitoring device: ${EMULATOR_DEVICE}${NC}"
echo -e "${YELLOW}Output directory: ${OUTPUT_DIR}${NC}"
echo ""

# Check if device is connected
if ! adb -s "${EMULATOR_DEVICE}" devices | grep -q "${EMULATOR_DEVICE}.*device$"; then
    echo -e "${RED}❌ Error: Device ${EMULATOR_DEVICE} not found or not authorized${NC}"
    echo "Available devices:"
    adb devices
    exit 1
fi

# Get app PID
APP_PID=$(adb -s "${EMULATOR_DEVICE}" shell pidof -s com.hypo.clipboard.debug 2>/dev/null || echo "")

if [ -z "${APP_PID}" ]; then
    echo -e "${YELLOW}⚠️  App not running. Waiting for app to start...${NC}"
    # Wait for app to start (max 30 seconds)
    for i in {1..30}; do
        APP_PID=$(adb -s "${EMULATOR_DEVICE}" shell pidof -s com.hypo.clipboard.debug 2>/dev/null || echo "")
        if [ -n "${APP_PID}" ]; then
            echo -e "${GREEN}✅ App started (PID: ${APP_PID})${NC}"
            break
        fi
        sleep 1
    done
    
    if [ -z "${APP_PID}" ]; then
        echo -e "${RED}❌ Error: App did not start within 30 seconds${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✅ Monitoring app (PID: ${APP_PID})${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop monitoring${NC}"
echo ""

# Function to capture logs when disconnection is detected
capture_logs() {
    local event_type="$1"
    local trigger_line="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output_file="${OUTPUT_DIR}/cloud_disconnection_${timestamp//[ :]/_}.log"
    
    echo -e "${RED}🚨 Cloud Disconnection Detected: ${event_type}${NC}"
    echo -e "${YELLOW}📝 Capturing last 3 seconds of logs...${NC}"
    
    # Get last 200 lines of logs (should cover ~3 seconds at typical log rates)
    # Use -d to dump current buffer, then filter by PID
    local log_capture=$(adb -s "${EMULATOR_DEVICE}" logcat -d --pid="${APP_PID}" 2>/dev/null | tail -n 200)
    
    # If that doesn't work, try without PID filter (less precise but more reliable)
    if [ -z "${log_capture}" ] || [ $(echo "${log_capture}" | wc -l) -lt 10 ]; then
        log_capture=$(adb -s "${EMULATOR_DEVICE}" logcat -d 2>/dev/null | grep -E ".*${APP_PID}.*" | tail -n 200)
    fi
    
    # Write to output file
    {
        echo "=========================================="
        echo "Cloud Disconnection Event"
        echo "Type: ${event_type}"
        echo "Timestamp: ${timestamp}"
        echo "Device: ${EMULATOR_DEVICE}"
        echo "App PID: ${APP_PID}"
        echo "=========================================="
        echo ""
        echo "Trigger Line:"
        echo "------------------------------------------"
        echo "${trigger_line}"
        echo ""
        echo "------------------------------------------"
        echo "Last 3 seconds of logs (all app logs):"
        echo "------------------------------------------"
        echo "${log_capture}"
        echo ""
        echo "------------------------------------------"
        echo "End of log capture"
        echo ""
    } > "${output_file}"
    
    echo -e "${GREEN}✅ Logs saved to: ${output_file}${NC}"
    echo ""
}

# Monitor logcat for disconnection events
adb -s "${EMULATOR_DEVICE}" logcat --pid="${APP_PID}" \
    | grep --line-buffered -E "${LOG_PATTERN}" \
    | while IFS= read -r line; do
        # Display the line
        echo "${line}"
        
        # Check for disconnection events
        if echo "${line}" | grep -qE "WebSocket closed.*cloud=true|Connection failed.*wss://|onClosed.*cloud|onFailure.*cloud|Event-driven.*triggering ensureConnection"; then
            # Determine event type
            event_type="Unknown"
            if echo "${line}" | grep -q "WebSocket closed"; then
                event_type="WebSocket Closed"
            elif echo "${line}" | grep -q "Connection failed"; then
                event_type="Connection Failed"
            elif echo "${line}" | grep -q "onClosed"; then
                event_type="onClosed Callback"
            elif echo "${line}" | grep -q "onFailure"; then
                event_type="onFailure Callback"
            elif echo "${line}" | grep -q "Event-driven"; then
                event_type="Event-Driven Reconnection"
            fi
            
            # Capture logs
            capture_logs "${event_type}" "${line}"
        fi
    done
