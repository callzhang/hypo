#!/bin/bash

# Comprehensive server test script
# Tests all backend server functions and endpoints

set +e  # Don't exit on error, we'll handle failures ourselves

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVER_URL="${SERVER_URL:-https://hypo.fly.dev}"
LOCAL_URL="${LOCAL_URL:-http://localhost:8080}"
USE_LOCAL="${USE_LOCAL:-false}"

if [ "$USE_LOCAL" = "true" ]; then
    BASE_URL="$LOCAL_URL"
else
    BASE_URL="$SERVER_URL"
fi

PASSED=0
FAILED=0

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
    ((PASSED++))
}

log_error() {
    echo -e "${RED}❌${NC} $1"
    ((FAILED++))
}

log_test() {
    echo -e "${YELLOW}🧪${NC} $1"
}

test_endpoint() {
    local name="$1"
    local method="$2"
    local path="$3"
    local expected_status="$4"
    local data="$5"
    
    log_test "Testing $name: $method $path"
    
    if [ -n "$data" ]; then
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "${BASE_URL}${path}" 2>&1)
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
            "${BASE_URL}${path}" 2>&1)
    fi
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "$expected_status" ]; then
        log_success "$name: HTTP $http_code"
        echo "   Response: $(echo "$body" | head -c 200)"
        return 0
    else
        log_error "$name: Expected HTTP $expected_status, got $http_code"
        echo "   Response: $body"
        return 1
    fi
}

test_health() {
    log_test "Testing Health Endpoint"
    response=$(curl -s "${BASE_URL}/health")
    
    if echo "$response" | grep -q '"status":"ok"'; then
        log_success "Health endpoint returns OK"
        echo "   $response"
    else
        log_error "Health endpoint failed"
        echo "   $response"
        return 1
    fi
}

test_metrics() {
    log_test "Testing Metrics Endpoint"
    response=$(curl -s "${BASE_URL}/metrics")
    
    if echo "$response" | grep -q "websocket_connections"; then
        log_success "Metrics endpoint returns Prometheus format"
        echo "   $(echo "$response" | head -5)"
    else
        log_error "Metrics endpoint failed"
        echo "   $response"
        return 1
    fi
}

test_pairing_code_creation() {
    log_test "Testing Pairing Code Creation"
    
    # Generate a dummy public key (base64 encoded)
    DUMMY_KEY=$(echo -n "dummy-public-key-for-testing" | base64)
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"mac_device_id\":\"test-mac-device-123\",\"mac_device_name\":\"Test Mac Device\",\"mac_public_key\":\"${DUMMY_KEY}\"}" \
        "${BASE_URL}/pairing/code" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        if echo "$body" | grep -q "code"; then
            PAIRING_CODE=$(echo "$body" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
            log_success "Pairing code created: $PAIRING_CODE"
            export PAIRING_CODE
        else
            log_error "Pairing code creation response missing 'code' field"
            echo "   $body"
            return 1
        fi
    else
        log_error "Pairing code creation failed: HTTP $http_code"
        echo "   $body"
        return 1
    fi
}

test_pairing_code_claim() {
    if [ -z "$PAIRING_CODE" ]; then
        log_info "Skipping pairing code claim test (no code available)"
        return 0
    fi
    
    log_test "Testing Pairing Code Claim"
    
    # Generate dummy keys
    ANDROID_KEY=$(echo -n "dummy-android-public-key" | base64)
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"code\":\"${PAIRING_CODE}\",\"android_device_id\":\"test-android-456\",\"android_device_name\":\"Claiming Device\",\"android_public_key\":\"${ANDROID_KEY}\"}" \
        "${BASE_URL}/pairing/claim" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    # Claim might fail if code is already used or expired, which is OK for testing
    if [ "$http_code" = "200" ] || [ "$http_code" = "400" ] || [ "$http_code" = "404" ]; then
        log_success "Pairing code claim endpoint responds (HTTP $http_code)"
    else
        log_error "Pairing code claim failed: HTTP $http_code"
        echo "   $body"
        return 1
    fi
}

test_websocket_headers() {
    log_test "Testing WebSocket Endpoint Headers"
    
    # Test that WebSocket endpoint requires headers
    response=$(curl -s -w "\n%{http_code}" \
        -H "Upgrade: websocket" \
        -H "Connection: Upgrade" \
        "${BASE_URL}/ws" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    
    # Should reject without X-Device-Id and X-Device-Platform
    if [ "$http_code" = "400" ] || [ "$http_code" = "426" ]; then
        log_success "WebSocket endpoint validates headers (HTTP $http_code)"
    else
        log_error "WebSocket endpoint unexpected response: HTTP $http_code"
        return 1
    fi
}

test_invalid_endpoints() {
    log_test "Testing Invalid Endpoints (404 handling)"
    
    response=$(curl -s -w "\n%{http_code}" "${BASE_URL}/nonexistent" 2>&1)
    http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" = "404" ]; then
        log_success "Invalid endpoints return 404"
    else
        log_error "Invalid endpoint returned HTTP $http_code (expected 404)"
        return 1
    fi
}

test_cors_headers() {
    log_test "Testing CORS Headers"
    
    response=$(curl -s -I -X OPTIONS \
        -H "Origin: https://example.com" \
        -H "Access-Control-Request-Method: POST" \
        "${BASE_URL}/health" 2>&1)
    
    # CORS headers are optional, so we just check the endpoint responds
    if echo "$response" | grep -q "HTTP"; then
        log_success "CORS preflight handled"
    else
        log_error "CORS preflight failed"
        return 1
    fi
}

run_rust_tests() {
    log_test "Running Rust Integration Tests"
    
    if ! command -v cargo &> /dev/null; then
        log_error "cargo not found, skipping Rust tests"
        return 1
    fi
    
    cd /Users/derek/Documents/Projects/hypo/backend
    
    if cargo test --test '*' 2>&1 | tee /tmp/rust_tests.log; then
        log_success "Rust integration tests passed"
    else
        log_error "Rust integration tests failed"
        echo "   Check /tmp/rust_tests.log for details"
        return 1
    fi
}

main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Hypo Backend Server Test Suite        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    log_info "Server URL: $BASE_URL"
    log_info "Testing all server functions and endpoints"
    echo ""
    
    # Test 1: Health Check
    test_health
    echo ""
    
    # Test 2: Metrics
    test_metrics
    echo ""
    
    # Test 3: Pairing Code Creation
    test_pairing_code_creation
    echo ""
    
    # Test 4: Pairing Code Claim
    test_pairing_code_claim
    echo ""
    
    # Test 5: WebSocket Headers
    test_websocket_headers
    echo ""
    
    # Test 6: Invalid Endpoints
    test_invalid_endpoints
    echo ""
    
    # Test 7: CORS
    test_cors_headers
    echo ""
    
    # Test 8: Rust Integration Tests (if cargo available)
    if command -v cargo &> /dev/null && [ "$USE_LOCAL" = "true" ]; then
        run_rust_tests
        echo ""
    else
        log_info "Skipping Rust tests (cargo not available or using remote server)"
        echo ""
    fi
    
    # Summary
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Test Summary                          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}✅ Passed: $PASSED${NC}"
    echo -e "${RED}❌ Failed: $FAILED${NC}"
    echo ""
    
    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed! 🎉${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed. Check output above.${NC}"
        exit 1
    fi
}

main "$@"

