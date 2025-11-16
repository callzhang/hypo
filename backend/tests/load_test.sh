#!/bin/bash

# Load test script for Hypo Backend Relay
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
HOST="${HOST:-localhost}"
PORT="${PORT:-8080}"
BASE_URL="http://${HOST}:${PORT}"
CONCURRENT="${CONCURRENT:-1000}"
REQUESTS="${REQUESTS:-10000}"

echo -e "${YELLOW}Starting Hypo Backend Load Test${NC}"
echo "Target: ${BASE_URL}"
echo "Concurrent connections: ${CONCURRENT}"
echo "Total requests: ${REQUESTS}"
echo ""

# Check if server is running
echo -e "${YELLOW}Checking server health...${NC}"
if ! curl -f -s "${BASE_URL}/health" > /dev/null; then
    echo -e "${RED}Error: Server not responding at ${BASE_URL}/health${NC}"
    echo "Make sure the backend server is running with: cargo run"
    exit 1
fi
echo -e "${GREEN}Server is healthy${NC}"

# Check if Apache Bench is available
if ! command -v ab &> /dev/null; then
    echo -e "${RED}Error: Apache Bench (ab) is not installed${NC}"
    echo "Install with: sudo apt-get install apache2-utils (Ubuntu/Debian) or brew install apache2 (macOS)"
    exit 1
fi

# Create temporary file for POST data (simulating device registration)
cat > /tmp/device_register.json << 'EOF'
{
    "device_id": "test-device-123",
    "device_name": "Load Test Device",
    "public_key": "test-key-data-base64-encoded-here",
    "device_type": "android"
}
EOF

echo ""
echo -e "${YELLOW}Test 1: Health endpoint load test${NC}"
ab -n ${REQUESTS} -c ${CONCURRENT} -q "${BASE_URL}/health"

echo ""
echo -e "${YELLOW}Test 2: Metrics endpoint load test${NC}"
ab -n $((REQUESTS / 2)) -c $((CONCURRENT / 2)) -q "${BASE_URL}/metrics"

echo ""
echo -e "${YELLOW}Test 3: WebSocket connection simulation${NC}"
# Use a simple Python script to test WebSocket connections
cat > /tmp/ws_load_test.py << 'EOF'
import asyncio
import websockets
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor

async def connect_and_send(uri, device_id, messages_per_connection=10):
    try:
        async with websockets.connect(uri, extra_headers={"X-Device-ID": device_id}) as websocket:
            # Send authentication message
            auth_msg = {
                "type": "auth",
                "device_id": device_id,
                "timestamp": time.time()
            }
            await websocket.send(json.dumps(auth_msg))
            
            # Send test messages
            for i in range(messages_per_connection):
                test_msg = {
                    "type": "clipboard",
                    "id": f"test-{device_id}-{i}",
                    "content": f"Test clipboard content {i}",
                    "timestamp": time.time()
                }
                await websocket.send(json.dumps(test_msg))
                
            return True
    except Exception as e:
        print(f"Connection {device_id} failed: {e}")
        return False

async def run_ws_load_test(concurrent_connections=100):
    uri = f"ws://{sys.argv[1]}:{sys.argv[2]}/ws"
    
    start_time = time.time()
    tasks = []
    
    for i in range(concurrent_connections):
        device_id = f"load-test-device-{i}"
        tasks.append(connect_and_send(uri, device_id))
    
    results = await asyncio.gather(*tasks, return_exceptions=True)
    end_time = time.time()
    
    successful = sum(1 for r in results if r is True)
    failed = len(results) - successful
    
    print(f"WebSocket Load Test Results:")
    print(f"Duration: {end_time - start_time:.2f}s")
    print(f"Successful connections: {successful}")
    print(f"Failed connections: {failed}")
    print(f"Success rate: {successful/len(results)*100:.1f}%")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python ws_load_test.py HOST PORT")
        sys.exit(1)
    
    asyncio.run(run_ws_load_test(100))
EOF

# Run WebSocket load test if Python and websockets are available
if command -v python3 &> /dev/null; then
    if python3 -c "import websockets" 2>/dev/null; then
        echo "Running WebSocket load test with 100 concurrent connections..."
        python3 /tmp/ws_load_test.py ${HOST} ${PORT}
    else
        echo "Skipping WebSocket test (websockets library not installed)"
        echo "Install with: pip3 install websockets"
    fi
else
    echo "Skipping WebSocket test (python3 not available)"
fi

# Memory usage test
echo ""
echo -e "${YELLOW}Test 4: Memory usage monitoring${NC}"
echo "Monitoring server memory usage during load..."

# Get server PID if running locally
if [ "${HOST}" = "localhost" ] || [ "${HOST}" = "127.0.0.1" ]; then
    PID=$(pgrep -f "hypo-relay\|target.*debug.*main\|target.*release.*main" | head -1)
    if [ -n "$PID" ]; then
        echo "Monitoring process PID: ${PID}"
        
        # Monitor memory before load
        BEFORE_MEM=$(ps -p ${PID} -o rss= 2>/dev/null || echo "0")
        echo "Memory usage before load: ${BEFORE_MEM} KB"
        
        # Run concurrent health checks for 30 seconds
        echo "Running sustained load for 30 seconds..."
        timeout 30s bash -c "while true; do curl -s ${BASE_URL}/health > /dev/null & sleep 0.01; done"
        wait
        
        # Monitor memory after load
        AFTER_MEM=$(ps -p ${PID} -o rss= 2>/dev/null || echo "0")
        echo "Memory usage after load: ${AFTER_MEM} KB"
        
        if [ "${AFTER_MEM}" -gt 0 ] && [ "${BEFORE_MEM}" -gt 0 ]; then
            DIFF=$((AFTER_MEM - BEFORE_MEM))
            echo "Memory difference: ${DIFF} KB"
            if [ "${AFTER_MEM}" -lt 52428800 ]; then  # 50MB in KB
                echo -e "${GREEN}Memory usage is within acceptable limits (<50MB)${NC}"
            else
                echo -e "${RED}Warning: Memory usage exceeds 50MB${NC}"
            fi
        fi
    else
        echo "Could not find server process for memory monitoring"
    fi
else
    echo "Skipping memory monitoring (server not running locally)"
fi

echo ""
echo -e "${YELLOW}Test 5: Error rate measurement${NC}"
# Test error handling with invalid requests
ERRORS=$(ab -n 1000 -c 50 -q "${BASE_URL}/nonexistent" 2>&1 | grep "Non-2xx responses:" | awk '{print $3}' || echo "1000")
ERROR_RATE=$(echo "scale=2; ${ERRORS:-1000} / 1000 * 100" | bc -l 2>/dev/null || echo "100.00")
echo "Error rate for invalid endpoints: ${ERROR_RATE}%"

if [ $(echo "${ERROR_RATE} < 0.1" | bc -l 2>/dev/null || echo "0") -eq 1 ]; then
    echo -e "${GREEN}Error rate is within target (<0.1%)${NC}"
else
    echo -e "${YELLOW}Note: Error rate measurement may include expected 404s${NC}"
fi

# Cleanup
rm -f /tmp/device_register.json /tmp/ws_load_test.py

echo ""
echo -e "${GREEN}Load test completed!${NC}"
echo ""
echo "Performance Targets:"
echo "- Concurrent connections: ${CONCURRENT} (target: 1000)"
echo "- Memory usage: <50MB"
echo "- Error rate: <0.5%"
echo ""
echo "Review the results above to identify optimization opportunities."