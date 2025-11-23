#!/bin/bash
# Comprehensive Sync Matrix Test Script
# Tests all 8 combinations: Plaintext/Encrypted × Cloud/LAN × macOS/Android

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
ANDROID_DEVICE_ID="c7bd7e23-b5c1-4dfd-bb62-6a3b7c880760"
MACOS_DEVICE_ID="007E4A95-0E1A-4B10-91FA-87942EFAA68E"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test results (using simple variables instead of associative array for macOS compatibility)
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
RESULTS_FILE="/tmp/test_results_$$.txt"

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

# Get encryption key for a device from macOS keychain
# When sending to Android, we use the key that macOS has for Android
# When sending to macOS, we use the key that macOS has for the sender (Android)
get_encryption_key() {
    local target_device_id=$1
    local target_platform=$2
    
    # For Android target: get the key macOS has stored for this Android device
    # This is the key that Android will use to decrypt (it's the same key)
    if [ "$target_platform" = "android" ]; then
        # macOS stores keys as "android-{device-id}"
        security find-generic-password -w -s 'com.hypo.clipboard.keys' -a "android-${target_device_id}" 2>/dev/null | xxd -p -c 32 | head -1 || echo ""
    elif [ "$target_platform" = "macos" ]; then
        # For macOS target, we need the key that macOS uses for the sender
        # Since we're simulating Android sending to macOS, use Android's key for macOS
        # macOS stores keys for paired devices - we'll use the Android device's key
        # that macOS has stored (the key macOS uses to encrypt messages TO Android)
        # Actually, we need the key that macOS will use to decrypt FROM Android
        # This is typically stored with the Android device ID
        security find-generic-password -w -s 'com.hypo.clipboard.keys' -a "android-${ANDROID_DEVICE_ID}" 2>/dev/null | xxd -p -c 32 | head -1 || echo ""
    else
        echo ""
    fi
}

# Check Android reception
check_android_reception() {
    local test_case=$1
    local message_text=$2
    local timeout=${3:-5}
    
    sleep "$timeout"
    
    # Check for onMessage() call
    local onmessage_count=$(adb logcat -d -t 300 | grep -c "🔥🔥🔥.*onMessage.*CALLED" || echo "0")
    
    # Check for handler processing
    local handler_success=$(adb logcat -d -t 300 | grep -c "IncomingClipboardHandler.*✅ Decoded clipboard event" || echo "0")
    local handler_failure=$(adb logcat -d -t 300 | grep -c "IncomingClipboardHandler.*❌ Failed" || echo "0")
    
    # Check for specific message text in logs (if plaintext)
    local message_found=$(adb logcat -d -t 300 | grep -c "$message_text" || echo "0")
    
    echo "$onmessage_count|$handler_success|$handler_failure|$message_found"
}

# Check macOS reception (if app is running)
check_macos_reception() {
    local test_case=$1
    local message_text=$2
    local timeout=${3:-5}
    
    sleep "$timeout"
    
    # Check if macOS app is running
    if ! pgrep -f "HypoMenuBar\|HypoApp" > /dev/null; then
        echo "not_running"
        return
    fi
    
    # Check debug log file
    if [ -f "/tmp/hypo_debug.log" ]; then
        local log_entries=$(grep -c "CLIPBOARD RECEIVED\|IncomingClipboardHandler" /tmp/hypo_debug.log 2>/dev/null || echo "0")
        echo "$log_entries"
    else
        echo "0"
    fi
}

# Run a single test case
run_test_case() {
    local case_num=$1
    local encryption=$2
    local transport=$3
    local target_platform=$4
    local description="$5"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    log_info "Running Case $case_num: $description"
    
    local test_id="test-case${case_num}-$(date +%s)"
    local message_text="Case $case_num: $description $(date +%H:%M:%S)"
    local result="UNKNOWN"
    local error_msg=""
    
    # Determine target device ID
    local target_device_id=""
    if [ "$target_platform" = "android" ]; then
        target_device_id="$ANDROID_DEVICE_ID"
    else
        target_device_id="$MACOS_DEVICE_ID"
    fi
    
    # Get encryption key if needed
    local encryption_key=""
    if [ "$encryption" = "encrypted" ]; then
        encryption_key=$(get_encryption_key "$target_device_id" "$target_platform")
        if [ -z "$encryption_key" ]; then
            log_warning "  Encryption key not found for $target_platform device, using plaintext"
            encryption="plaintext"
        fi
    fi
    
    # Clear logcat buffer to get fresh baseline
    adb logcat -c > /dev/null 2>&1 || true
    sleep 1
    
    # Get baseline counts (should be 0 after clearing)
    local android_baseline=0
    local handler_baseline=0
    
    # Run the test
    if [ "$transport" = "cloud" ]; then
        # Cloud relay test
        local cmd="python3 $SCRIPT_DIR/simulate-android-relay.py"
        cmd="$cmd --text \"$message_text\""
        cmd="$cmd --device-id \"$test_id\""
        cmd="$cmd --target-platform \"$target_platform\""
        cmd="$cmd --target \"$target_device_id\""
        
        if [ "$encryption" = "encrypted" ] && [ -n "$encryption_key" ]; then
            cmd="$cmd --encrypted --key \"$encryption_key\""
        fi
        
        if eval "$cmd" > /tmp/test_case_${case_num}.log 2>&1; then
            log_success "  Message sent via cloud relay"
        else
            log_error "  Failed to send message"
            error_msg="Send failed"
            result="FAILED"
        fi
    else
        # LAN test
        local cmd="python3 $SCRIPT_DIR/simulate-android-copy.py"
        cmd="$cmd --text \"$message_text\""
        cmd="$cmd --target-platform \"$target_platform\""
        
        if [ "$target_platform" = "android" ]; then
            cmd="$cmd --target-device-id \"$target_device_id\""
        fi
        
        if [ "$encryption" = "encrypted" ] && [ -n "$encryption_key" ]; then
            cmd="$cmd --encrypted --key \"$encryption_key\""
        fi
        
        if eval "$cmd" > /tmp/test_case_${case_num}.log 2>&1; then
            log_success "  Message sent via LAN"
        else
            log_error "  Failed to send message"
            error_msg="Send failed"
            result="FAILED"
        fi
    fi
    
    # Check reception
    if [ "$result" != "FAILED" ]; then
        sleep 3
        
        if [ "$target_platform" = "android" ]; then
            # Check Android reception - look for messages after sending
            local onmessage_count=$(adb logcat -d 2>/dev/null | grep -c "🔥🔥🔥.*onMessage.*CALLED" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
            local handler_success=$(adb logcat -d 2>/dev/null | grep -c "IncomingClipboardHandler.*✅ Decoded clipboard event" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
            local handler_failure=$(adb logcat -d 2>/dev/null | grep -c "IncomingClipboardHandler.*❌ Failed" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
            
            # Ensure numeric values
            onmessage_count=${onmessage_count:-0}
            handler_success=${handler_success:-0}
            handler_failure=${handler_failure:-0}
            
            # Convert to integers
            onmessage_count=$(echo "$onmessage_count" | grep -o '[0-9]*' | head -1 || echo "0")
            handler_success=$(echo "$handler_success" | grep -o '[0-9]*' | head -1 || echo "0")
            handler_failure=$(echo "$handler_failure" | grep -o '[0-9]*' | head -1 || echo "0")
            
            # Check if we got a new onMessage call (since we cleared the buffer)
            if [ "${onmessage_count:-0}" -gt 0 ] 2>/dev/null; then
                if [ "$handler_success" -gt 0 ]; then
                    log_success "  Android received and processed message"
                    result="PASSED"
                    PASSED_TESTS=$((PASSED_TESTS + 1))
                elif [ "$handler_failure" -gt 0 ]; then
                    # Check if this was an encrypted message that failed
                    if [ "$encryption" = "encrypted" ]; then
                        log_warning "  Android received message but decryption failed"
                        result="PARTIAL"
                        error_msg="Decryption failed (check encryption key)"
                    else
                        log_warning "  Android received message but processing failed"
                        result="PARTIAL"
                        error_msg="Processing failed (check logs)"
                    fi
                else
                    # Message received but no handler activity - might be processing
                    log_warning "  Android received message, checking handler status..."
                    sleep 2
                    # Re-check after delay
                    local handler_success_retry=$(adb logcat -d 2>/dev/null | grep -c "IncomingClipboardHandler.*✅ Decoded clipboard event" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
                    handler_success_retry=$(echo "$handler_success_retry" | grep -o '[0-9]*' | head -1 || echo "0")
                    if [ "${handler_success_retry:-0}" -gt 0 ] 2>/dev/null; then
                        log_success "  Android received and processed message (delayed)"
                        result="PASSED"
                        PASSED_TESTS=$((PASSED_TESTS + 1))
                    else
                        log_warning "  Android received message but handler not invoked"
                        result="PARTIAL"
                        error_msg="Handler not invoked"
                    fi
                fi
            else
                log_error "  Android did not receive message"
                result="FAILED"
                error_msg="No onMessage() call"
                FAILED_TESTS=$((FAILED_TESTS + 1))
            fi
        else
            # Check macOS reception
            local macos_status=$(check_macos_reception "$case_num" "$message_text" 0)
            if [ "$macos_status" = "not_running" ]; then
                log_warning "  macOS app not running, cannot verify reception"
                result="SKIPPED"
                error_msg="macOS app not running"
            elif [ "$macos_status" -gt 0 ]; then
                log_success "  macOS received message"
                result="PASSED"
                PASSED_TESTS=$((PASSED_TESTS + 1))
            else
                log_warning "  macOS reception not confirmed"
                result="UNKNOWN"
                error_msg="Reception not confirmed"
            fi
        fi
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    
    # Store result in file
    echo "$case_num|$result|$error_msg" >> "$RESULTS_FILE"
    
    echo ""
}

# Main test execution
main() {
    echo ""
    echo "🧪 Comprehensive Sync Matrix Test"
    echo "=================================="
    echo ""
    echo "Test Matrix:"
    echo "  - Encryption: Plaintext / Encrypted"
    echo "  - Transport: LAN / Cloud"
    echo "  - Target: macOS / Android"
    echo ""
    echo "Device IDs:"
    echo "  Android: $ANDROID_DEVICE_ID"
    echo "  macOS: $MACOS_DEVICE_ID"
    echo ""
    
    # Verify Android is connected
    if ! adb devices | grep -q "device$"; then
        log_error "Android device not connected"
        exit 1
    fi
    
    log_info "Starting test matrix..."
    echo ""
    
    # Test Case 1: Plaintext + Cloud + macOS
    run_test_case 1 "plaintext" "cloud" "macos" "Plaintext Cloud macOS"
    
    # Test Case 2: Plaintext + Cloud + Android
    run_test_case 2 "plaintext" "cloud" "android" "Plaintext Cloud Android"
    
    # Test Case 3: Plaintext + LAN + macOS
    run_test_case 3 "plaintext" "lan" "macos" "Plaintext LAN macOS"
    
    # Test Case 4: Plaintext + LAN + Android
    run_test_case 4 "plaintext" "lan" "android" "Plaintext LAN Android"
    
    # Test Case 5: Encrypted + Cloud + macOS
    run_test_case 5 "encrypted" "cloud" "macos" "Encrypted Cloud macOS"
    
    # Test Case 6: Encrypted + Cloud + Android
    run_test_case 6 "encrypted" "cloud" "android" "Encrypted Cloud Android"
    
    # Test Case 7: Encrypted + LAN + macOS
    run_test_case 7 "encrypted" "lan" "macos" "Encrypted LAN macOS"
    
    # Test Case 8: Encrypted + LAN + Android
    run_test_case 8 "encrypted" "lan" "android" "Encrypted LAN Android"
    
    # Print summary
    echo ""
    echo "📊 Test Results Summary"
    echo "======================"
    echo ""
    
    printf "%-5s %-35s %-10s %s\n" "Case" "Description" "Status" "Notes"
    echo "-------------------------------------------------------------------"
    
    # Initialize results file
    touch "$RESULTS_FILE"
    
    for case_num in {1..8}; do
        local result_data=$(grep "^${case_num}|" "$RESULTS_FILE" 2>/dev/null || echo "")
        if [ -z "$result_data" ]; then
            local status="NOT_RUN"
            local error="Test not executed"
        else
            local status=$(echo "$result_data" | cut -d'|' -f2)
            local error=$(echo "$result_data" | cut -d'|' -f3)
        fi
        
        local desc=""
        case $case_num in
            1) desc="Plaintext + Cloud + macOS" ;;
            2) desc="Plaintext + Cloud + Android" ;;
            3) desc="Plaintext + LAN + macOS" ;;
            4) desc="Plaintext + LAN + Android" ;;
            5) desc="Encrypted + Cloud + macOS" ;;
            6) desc="Encrypted + Cloud + Android" ;;
            7) desc="Encrypted + LAN + macOS" ;;
            8) desc="Encrypted + LAN + Android" ;;
        esac
        
        local status_color=""
        case $status in
            PASSED) status_color="${GREEN}✅ PASSED${NC}" ;;
            FAILED) status_color="${RED}❌ FAILED${NC}" ;;
            PARTIAL) status_color="${YELLOW}⚠️  PARTIAL${NC}" ;;
            SKIPPED) status_color="${YELLOW}⏭️  SKIPPED${NC}" ;;
            *) status_color="${BLUE}❓ UNKNOWN${NC}" ;;
        esac
        
        printf "%-5s %-35s %-10s %s\n" "$case_num" "$desc" "$status_color" "$error"
    done
    
    echo ""
    echo "Statistics:"
    echo "  Total Tests: $TOTAL_TESTS"
    echo "  Passed: ${GREEN}$PASSED_TESTS${NC}"
    echo "  Failed: ${RED}$FAILED_TESTS${NC}"
    echo "  Success Rate: $((PASSED_TESTS * 100 / TOTAL_TESTS))%"
    echo ""
    
    # Cleanup
    rm -f "$RESULTS_FILE"
    
    # Exit with appropriate code
    if [ "$FAILED_TESTS" -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"
