#!/bin/bash
# Comprehensive Sync Matrix Test Script
# Tests all 8 combinations: Plaintext/Encrypted × Cloud/LAN × macOS/Android
#
# This is an INTEGRATION test that uses REAL device keys from .env or keychain.
# For unit tests with deterministic test vectors, see:
#   - tests/crypto_test_vectors.json (used by CryptoServiceTest.kt, CryptoServiceTests.swift)
#   - backend/src/crypto/test_vectors.rs

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
# Device IDs are loaded from .env file (fallback to defaults for backward compatibility)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Simulation scripts are in scripts/ directory
SIM_SCRIPTS_DIR="$PROJECT_ROOT/scripts"

# Determine which Android device to use (prefer physical device over emulator)
ANDROID_ADB_DEVICE="${ANDROID_ADB_DEVICE:-}"
if [ -z "$ANDROID_ADB_DEVICE" ]; then
    # Auto-detect: prefer physical device (not emulator)
    # First try to find a non-emulator device
    ANDROID_ADB_DEVICE=$(adb devices 2>/dev/null | grep "device$" | grep -v "emulator" | head -1 | awk '{print $1}' || echo "")
    # If no physical device found, fall back to any device
    if [ -z "$ANDROID_ADB_DEVICE" ]; then
        ANDROID_ADB_DEVICE=$(adb devices 2>/dev/null | grep "device$" | head -1 | awk '{print $1}' || echo "")
    fi
    if [ -z "$ANDROID_ADB_DEVICE" ]; then
        echo "⚠️  No Android device found. Using default adb (may fail if multiple devices)"
    else
        # Check if it's an emulator
        if echo "$ANDROID_ADB_DEVICE" | grep -q "emulator"; then
            echo "⚠️  Warning: Using emulator ($ANDROID_ADB_DEVICE). Prefer physical device for LAN tests."
        else
            echo "📱 Using Android device: $ANDROID_ADB_DEVICE"
        fi
    fi
fi

# ADB command with device selection
adb_cmd() {
    if [ -n "$ANDROID_ADB_DEVICE" ]; then
        adb -s "$ANDROID_ADB_DEVICE" "$@"
    else
        adb "$@"
    fi
}

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

log_section() {
    echo ""
    echo -e "${BLUE}$1${NC}"
    echo ""
}

# Load environment variables from .env file
load_env_file() {
    local env_file="$PROJECT_ROOT/.env"
    if [ -f "$env_file" ]; then
        # Export variables from .env file using set -a (auto-export)
        # This is the most compatible way to load .env files
        set -a
        # Source the file, but only lines that look like KEY=VALUE (not comments)
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            # Only process lines with = sign
            [[ "$line" =~ = ]] || continue
            # Export the line (bash will handle quoting automatically)
            export "$line" 2>/dev/null || true
        done < "$env_file"
        set +a
    fi
}

# Load .env file early to get device IDs and encryption keys
load_env_file

# Device IDs (from .env or placeholder defaults)
# NOTE: Default values are PLACEHOLDER UUIDs for testing only.
# Real device IDs should be configured in .env file.
# These placeholders will not work with real devices - they're just for script syntax validation.
ANDROID_DEVICE_ID="${ANDROID_DEVICE_ID:-00000000-0000-0000-0000-000000000001}"
MACOS_DEVICE_ID="${MACOS_DEVICE_ID:-00000000-0000-0000-0000-000000000002}"

# Get encryption key for a device
# Priority: 1) .env file, 2) macOS keychain
get_encryption_key() {
    local target_device_id=$1
    local target_platform=$2
    
    # Load .env file if it exists (only once, at script start)
    if [ -z "${ENV_LOADED:-}" ]; then
        load_env_file
        export ENV_LOADED=1
    fi
    
    # Convert device ID to env var format (replace hyphens with underscores)
    local env_var_id=$(echo "$target_device_id" | tr '-' '_')
    local key=""
    
    if [ "$target_platform" = "android" ]; then
        # PRIORITY: Keychain first (source of truth after key rotation), then .env file
        # Try keychain first
        key=$(security find-generic-password -w -s 'com.hypo.clipboard.keys' -a "$target_device_id" 2>/dev/null | xxd -p -c 32 | head -1 | tr -d '\n' || echo "")
        if [ -z "$key" ] || [ ${#key} -lt 64 ]; then
            key=$(security find-generic-password -w -s 'com.hypo.clipboard.keys' -a "android-${target_device_id}" 2>/dev/null | xxd -p -c 32 | head -1 | tr -d '\n' || echo "")
        fi
        
        # If not found in keychain, try .env file (for backward compatibility)
        if [ -z "$key" ] || [ ${#key} -ne 64 ]; then
            # Try Android-specific env var
            local env_var_name="ANDROID_KEY_${env_var_id}"
            # Use eval to get the value of the dynamically named variable
            key=$(eval "echo \"\$$env_var_name\"")
            
            # If not found, try generic TEST_ENCRYPTION_KEY
            if [ -z "$key" ] || [ ${#key} -ne 64 ]; then
                key="${TEST_ENCRYPTION_KEY:-}"
            fi
        fi
    elif [ "$target_platform" = "macos" ]; then
        # For macOS target: get the key that macOS has for Android (the sender)
        # PRIORITY: Keychain first (source of truth after key rotation), then .env file
        # Try keychain first (macOS stores key under Android's device ID)
        key=$(security find-generic-password -w -s 'com.hypo.clipboard.keys' -a "$ANDROID_DEVICE_ID" 2>/dev/null | xxd -p -c 32 | head -1 | tr -d '\n' || echo "")
        if [ -z "$key" ] || [ ${#key} -lt 64 ]; then
            key=$(security find-generic-password -w -s 'com.hypo.clipboard.keys' -a "android-${ANDROID_DEVICE_ID}" 2>/dev/null | xxd -p -c 32 | head -1 | tr -d '\n' || echo "")
        fi
        
        # If not found in keychain, try .env file (for backward compatibility)
        if [ -z "$key" ] || [ ${#key} -ne 64 ]; then
            # Try macOS-specific env var
            local env_var_name="MACOS_KEY_${env_var_id}"
            key=$(eval "echo \"\${${env_var_name}:-}\"")
            
            # If not found, try Android key (macOS uses Android's key for decryption)
            if [ -z "$key" ] || [ ${#key} -ne 64 ]; then
                local android_env_var_id=$(echo "$ANDROID_DEVICE_ID" | tr '-' '_')
                env_var_name="ANDROID_KEY_${android_env_var_id}"
                key=$(eval "echo \"\${${env_var_name}:-}\"")
            fi
            
            # If still not found, try generic TEST_ENCRYPTION_KEY
            if [ -z "$key" ] || [ ${#key} -ne 64 ]; then
                key="${TEST_ENCRYPTION_KEY:-}"
            fi
        fi
    fi
    
    # Verify key is 64 hex chars (32 bytes)
    if [ -n "$key" ] && [ ${#key} -eq 64 ]; then
        echo "$key"
    else
        echo ""
    fi
}

# Check Android reception
check_android_reception() {
    local test_case=$1
    local message_text=$2
    local timeout=${3:-10}
    local max_retries=${4:-2}
    
    local attempt=0
    local onmessage_count=0
    local handler_success=0
    local handler_failure=0
    local message_found=0
    local db_found=0
    
    while [ $attempt -lt $max_retries ]; do
        sleep "$timeout"
        
        # Check for onMessage() call with improved pattern matching
        onmessage_count=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "🔥🔥🔥.*onMessage.*CALLED" || echo "0")
        
        # Check for handler processing
        handler_success=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "IncomingClipboardHandler.*✅.*Decoded clipboard event" || echo "0")
        handler_failure=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "IncomingClipboardHandler.*❌.*Failed" || echo "0")
        
        # Check for specific message text in logs (if plaintext)
        message_found=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -c "$message_text" || echo "0")
        
        # Fallback: Check database via SQLite query
        db_found=$(adb_cmd shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT COUNT(*) FROM clipboard_items WHERE preview LIKE \"%${message_text}%\" OR content LIKE \"%${message_text}%\" LIMIT 1;' 2>/dev/null" | tr -d '\r\n' || echo "0")
        
        # If we found evidence, break early
        if [ "$onmessage_count" -gt 0 ] || [ "$handler_success" -gt 0 ] || [ "$db_found" -gt 0 ]; then
            break
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_retries ]; then
            log_info "  Retry attempt $((attempt + 1))/$max_retries..."
        fi
    done
    
    echo "$onmessage_count|$handler_success|$handler_failure|$message_found|$db_found"
}

# Check macOS reception (if app is running)
check_macos_reception() {
    local test_case=$1
    local message_text=$2
    local timeout=${3:-5}
    
    sleep "$timeout"
    
    # Check if macOS app is running (try multiple process name patterns)
    if ! pgrep -f "HypoMenuBar\|HypoApp\|Hypo.*MenuBar" > /dev/null && \
       ! pgrep -f "com\.hypo\|hypo" > /dev/null && \
       ! ps aux | grep -i "hypo" | grep -v grep | grep -v "test-sync" > /dev/null; then
        echo "not_running"
        return
    fi
    
    # Check debug log file for specific case number
    if [ -f "/tmp/hypo_debug.log" ]; then
        # Look for the specific case number in the log
        local case_pattern="Case $test_case:"
        local log_entries=$(grep -c "$case_pattern" /tmp/hypo_debug.log 2>/dev/null | tr -d '\n' || echo "0")
        # Ensure it's a valid number
        log_entries=$(echo "$log_entries" | grep -o '[0-9]*' | head -1 || echo "0")
        
        # For encrypted messages, also check for successful decryption and insertion
        # Encrypted messages might be decrypted and inserted without the exact "Case X:" pattern
        # Check multiple indicators:
        # 1. "Inserted entry" that contains the message text (first 30 chars)
        # 2. "CLIPBOARD DECODED" followed by recent "Inserted entry" (within last 10 lines)
        if [ "$log_entries" = "0" ]; then
            local message_prefix=$(echo "$message_text" | cut -c1-30)
            # Check for inserted entry with message prefix
            local inserted_count=$(grep "Inserted entry.*$message_prefix" /tmp/hypo_debug.log 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            inserted_count=$(echo "$inserted_count" | grep -o '[0-9]*' | head -1 || echo "0")
            
            # If still 0, check for recent CLIPBOARD DECODED + Inserted entry pattern
            # This handles encrypted messages that are successfully decrypted
            if [ "$inserted_count" = "0" ]; then
                # Check if there's a recent CLIPBOARD DECODED followed by Inserted entry
                # Look at last 20 lines for this pattern
                local recent_decoded=$(tail -20 /tmp/hypo_debug.log | grep -c "CLIPBOARD DECODED" 2>/dev/null || echo "0")
                local recent_inserted=$(tail -20 /tmp/hypo_debug.log | grep -c "Inserted entry" 2>/dev/null || echo "0")
                # If we see both decoded and inserted recently, likely the message was received
                if [ "$recent_decoded" -gt 0 ] && [ "$recent_inserted" -gt 0 ]; then
                    inserted_count="1"
                fi
            fi
            
            if [ "$inserted_count" -gt 0 ]; then
                log_entries="$inserted_count"
            fi
        fi
        
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
    local mode="${6:-send_and_check}"  # "send_only" or "send_and_check"
    
    if [ "$mode" != "send_only" ]; then
        TOTAL_TESTS=$((TOTAL_TESTS + 1))
    fi
    
    log_info "Running Case $case_num: $description"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 Test Case $case_num Details:"
    echo "   Description: $description"
    echo "   Encryption: $encryption"
    echo "   Transport: $transport"
    echo "   Target Platform: $target_platform"
    echo ""
    
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
    
    echo "   Test ID: $test_id"
    echo "   Target Device ID: $target_device_id"
    echo "   Message Text: $message_text"
    echo ""
    
    # Get encryption key if needed
    # Keys are symmetric: the key macOS has for Android = the key Android has for macOS
    # When sending to Android: use macOS's key for Android, set device_id to macOS (sender)
    # When sending to macOS: use macOS's key for Android, set device_id to Android (sender)
    local encryption_key=""
    local encryption_device_id=""
    if [ "$encryption" = "encrypted" ]; then
        if [ "$target_platform" = "android" ]; then
            # Sending to Android: Android will decrypt using macOS's device ID (the sender)
            echo "   🔑 Retrieving shared encryption key (macOS has for Android = Android has for macOS)..."
            encryption_key=$(get_encryption_key "$ANDROID_DEVICE_ID" "macos")
            encryption_device_id="$MACOS_DEVICE_ID"  # Sender's device ID for key lookup on Android
        else
            # Sending to macOS: macOS will decrypt using Android's device ID (the sender)
            echo "   🔑 Retrieving shared encryption key (macOS has for Android = Android has for macOS)..."
            encryption_key=$(get_encryption_key "$ANDROID_DEVICE_ID" "macos")
            encryption_device_id="$ANDROID_DEVICE_ID"  # Sender's device ID for key lookup on macOS
        fi
        if [ -z "$encryption_key" ]; then
            log_warning "  Encryption key not found, using plaintext"
            encryption="plaintext"
            echo "   ⚠️  No encryption key found, falling back to plaintext"
        else
            echo "   ✅ Encryption key found: ${encryption_key:0:16}...${encryption_key: -16} (64 chars)"
            echo "   📝 Using sender device ID in envelope: $encryption_device_id (for key lookup on receiver)"
        fi
    else
        echo "   📝 Using plaintext mode (no encryption)"
    fi
    echo ""
    
    # Clear logcat buffer only if not in send_only mode (will be cleared once at start)
    if [ "$mode" != "send_only" ]; then
        echo "   🧹 Clearing Android logcat buffer..."
        adb logcat -c > /dev/null 2>&1 || true
        sleep 1
    fi
    
    # Get baseline counts (should be 0 after clearing)
    local android_baseline=0
    local handler_baseline=0
    
    # Run the test
    echo "   📤 Sending message..."
    echo "   ──────────────────────────────────────────────────────────────────────────"
    if [ "$transport" = "cloud" ]; then
        # Cloud relay test
        echo "   Transport: Cloud Relay (wss://hypo.fly.dev/ws)"
        local cmd="python3 $SIM_SCRIPTS_DIR/simulate-android-relay.py"
        cmd="$cmd --text \"$message_text\""
        # Use test UUID for WebSocket session (to avoid backend conflicts)
        # Real device ID will be used in envelope payload for key lookup
        local test_session_id="test-$(date +%s)-${case_num}"
        cmd="$cmd --device-id \"$test_session_id\""
        cmd="$cmd --device-name \"[SIM] Test Device\""
        
        # Always use --target-device-id (required)
        cmd="$cmd --target-device-id \"$target_device_id\""
        echo "   Target: $target_platform device ($target_device_id)"
        
        # Use fake UUID for WebSocket session to avoid conflicts with real device
        # But use sender's device ID in envelope payload for key lookup on receiver
        local test_session_id="test-$(date +%s)-${case_num}"
        cmd="$cmd --session-device-id \"$test_session_id\""
        echo "   📝 Using fake UUID for WebSocket session: $test_session_id (to avoid conflicts)"
        
        if [ "$encryption" = "encrypted" ] && [ -n "$encryption_key" ] && [ -n "$encryption_device_id" ]; then
            # Use sender's device ID and key - device_id in envelope must match stored key on receiver
            cmd="$cmd --encrypted --key \"$encryption_key\""
            # Use sender's device ID for encryption key lookup (receiver will decrypt using this)
            cmd="$cmd --encryption-device-id \"$encryption_device_id\""
            echo "   🔑 Using sender device ID in envelope: $encryption_device_id (for key lookup on receiver)"
            echo "   Encryption: AES-256-GCM (using sender's device ID and key)"
        else
            # For plaintext, still use sender's device ID in envelope (for consistency)
            if [ "$target_platform" = "android" ]; then
                cmd="$cmd --encryption-device-id \"$MACOS_DEVICE_ID\""
                echo "   🔑 Using sender device ID in envelope: $MACOS_DEVICE_ID"
            else
                cmd="$cmd --encryption-device-id \"$ANDROID_DEVICE_ID\""
                echo "   🔑 Using sender device ID in envelope: $ANDROID_DEVICE_ID"
            fi
            echo "   Encryption: None (plaintext)"
        fi
        
        echo "   Command: $cmd"
        echo ""
        
        if eval "$cmd" > /tmp/test_case_${case_num}.log 2>&1; then
            log_success "  Message sent via cloud relay"
            echo "   ✅ Send successful - check /tmp/test_case_${case_num}.log for details"
        else
            log_error "  Failed to send message"
            error_msg="Send failed"
            result="FAILED"
            echo "   ❌ Send failed - check /tmp/test_case_${case_num}.log for errors"
        fi
    else
        # LAN test
        # For macOS target: send to macOS's actual IP address (not localhost, to avoid confusion)
        # For Android target: send to Android's IP address (Android server)
        local lan_host=""
        local lan_port=7010
        
        if [ "$target_platform" = "android" ]; then
            # Get Android device IP address
            ANDROID_IP=$(adb_cmd shell "ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" 2>/dev/null | tr -d '\r\n' || echo "")
            if [ -z "$ANDROID_IP" ]; then
                # Fallback: try to get IP from other interfaces
                ANDROID_IP=$(adb_cmd shell "ip addr show | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print \$2}' | cut -d/ -f1" 2>/dev/null | tr -d '\r\n' || echo "")
            fi
            if [ -n "$ANDROID_IP" ]; then
                lan_host="$ANDROID_IP"
                echo "   Transport: LAN WebSocket (ws://$lan_host:$lan_port) - Android server"
            else
                log_warning "  Could not get Android IP, using localhost (may fail)"
                lan_host="localhost"
                echo "   Transport: LAN WebSocket (ws://localhost:$lan_port) - fallback"
            fi
        else
            # Get macOS IP address (use actual IP, not localhost)
            MACOS_IP=$(ifconfig | grep -E 'inet.*broadcast' | awk '{print $2}' | head -1 | tr -d '\r\n' || echo "")
            if [ -n "$MACOS_IP" ]; then
                lan_host="$MACOS_IP"
                echo "   Transport: LAN WebSocket (ws://$lan_host:$lan_port) - macOS server"
            else
                log_warning "  Could not get macOS IP, using localhost (may fail)"
                lan_host="localhost"
                echo "   Transport: LAN WebSocket (ws://localhost:$lan_port) - macOS server (fallback)"
            fi
        fi
        
        local cmd="python3 $SIM_SCRIPTS_DIR/simulate-android-copy.py"
        cmd="$cmd --text \"$message_text\""
        # Use fake UUID for WebSocket session to avoid conflicts
        # But use real device ID in envelope payload for key lookup
        local test_session_id="test-$(date +%s)-${case_num}"
        cmd="$cmd --session-device-id \"$test_session_id\""
        echo "   📝 Using fake UUID for WebSocket session: $test_session_id (to avoid conflicts)"
        cmd="$cmd --device-name \"[SIM] Test Device\""
        # Use appropriate host based on target platform
        cmd="$cmd --host $lan_host"
        cmd="$cmd --port $lan_port"
        
        # Always use --target-device-id (required)
        cmd="$cmd --target-device-id \"$target_device_id\""
        echo "   Target: $target_platform device ($target_device_id) at $lan_host:$lan_port"
        
        if [ "$encryption" = "encrypted" ] && [ -n "$encryption_key" ] && [ -n "$encryption_device_id" ]; then
            # Use sender's device ID and key - device_id in envelope must match stored key on receiver
            cmd="$cmd --encrypted --key \"$encryption_key\""
            # Use sender's device ID for encryption key lookup (receiver will decrypt using this)
            cmd="$cmd --encryption-device-id \"$encryption_device_id\""
            echo "   🔑 Using sender device ID in envelope: $encryption_device_id (for key lookup on receiver)"
            echo "   Encryption: AES-256-GCM (using sender's device ID and key)"
        else
            # For plaintext, still use sender's device ID in envelope (for consistency)
            if [ "$target_platform" = "android" ]; then
                cmd="$cmd --encryption-device-id \"$MACOS_DEVICE_ID\""
                echo "   🔑 Using sender device ID in envelope: $MACOS_DEVICE_ID"
            else
                cmd="$cmd --encryption-device-id \"$ANDROID_DEVICE_ID\""
                echo "   🔑 Using sender device ID in envelope: $ANDROID_DEVICE_ID"
            fi
            echo "   Encryption: None (plaintext)"
        fi
        
        echo "   Command: $cmd"
        echo ""
        
        if eval "$cmd" > /tmp/test_case_${case_num}.log 2>&1; then
            log_success "  Message sent via LAN"
            echo "   ✅ Send successful - check /tmp/test_case_${case_num}.log for details"
        else
            log_error "  Failed to send message"
            error_msg="Send failed"
            result="FAILED"
            echo "   ❌ Send failed - check /tmp/test_case_${case_num}.log for errors"
        fi
    fi
    echo "   ──────────────────────────────────────────────────────────────────────────"
    
    # Check reception (only if not in send_only mode)
    if [ "$mode" = "send_only" ]; then
        echo "   ✅ Message sent (reception will be checked later)"
        return
    fi
    
    # Check reception
    if [ "$result" != "FAILED" ]; then
        echo ""
        echo "   ⏳ Waiting 5 seconds for message to arrive and be processed..."
        sleep 5
        echo "   🔍 Checking reception status..."
        
        if [ "$target_platform" = "android" ]; then
            # Check Android reception - look for messages after sending
            local onmessage_count=$(adb_cmd logcat -d 2>/dev/null | grep -c "🔥🔥🔥.*onMessage.*CALLED" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
            local handler_success=$(adb_cmd logcat -d 2>/dev/null | grep -c "IncomingClipboardHandler.*✅ Decoded clipboard event" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
            local handler_failure=$(adb_cmd logcat -d 2>/dev/null | grep -c "IncomingClipboardHandler.*❌ Failed" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
            
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
                    local handler_success_retry=$(adb_cmd logcat -d 2>/dev/null | grep -c "IncomingClipboardHandler.*✅ Decoded clipboard event" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
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

# Check reception for a single test case (after all messages sent)
check_test_case_reception() {
    local case_num=$1
    local encryption=$2
    local transport=$3
    local target_platform=$4
    local description="$5"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    log_info "Checking Case $case_num: $description"
    
    local message_text="Case $case_num: $description"
    local result="UNKNOWN"
    local error_msg=""
    
    # Determine target device ID
    local target_device_id=""
    if [ "$target_platform" = "android" ]; then
        target_device_id="$ANDROID_DEVICE_ID"
    else
        target_device_id="$MACOS_DEVICE_ID"
    fi
    
    echo "   Target: $target_platform ($target_device_id)"
    echo "   Looking for message containing: $message_text"
    
    # Check reception
    if [ "$target_platform" = "android" ]; then
        # Check Android reception - look for SPECIFIC case number in logs
        # Extract case number from message text (format: "Case X: Description")
        local case_pattern="Case $case_num:"
        
        # Improved detection: Check multiple sources with better patterns
        # 1. Check database FIRST (most reliable) - look for case number in preview
        local db_found=$(adb_cmd shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT COUNT(*) FROM clipboard_items WHERE preview LIKE \"%Case $case_num:%\" OR content LIKE \"%Case $case_num:%\" LIMIT 1;' 2>/dev/null" | tr -d '\r\n' || echo "0")
        if [ "${db_found:-0}" = "0" ] 2>/dev/null; then
            # Fallback to release package name
            db_found=$(adb_cmd shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT COUNT(*) FROM clipboard_items WHERE preview LIKE \"%Case $case_num:%\" OR content LIKE \"%Case $case_num:%\" LIMIT 1;' 2>/dev/null" | tr -d '\r\n' || echo "0")
        fi
        
        # 2. Check logcat for case pattern in preview/content (database entries show this)
        local case_found=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "Case $case_num:|preview=Case $case_num:" 2>/dev/null || echo "0")
        
        # 3. Check for handler success - look for "Decoded clipboard event" or "Upserting item" with case number
        local handler_success=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "✅.*Decoded clipboard event|IncomingClipboardHandler.*✅.*Decoded|Upserting item.*Case $case_num:" 2>/dev/null || echo "0")
        
        # 4. Check for handler failure (decryption errors)
        local handler_failure=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "❌.*Failed.*Case $case_num:|IncomingClipboardHandler.*❌.*Failed|BAD_DECRYPT" 2>/dev/null || echo "0")
        
        # 5. Check for message reception indicators (onMessage, binary frames, etc.)
        # For cloud: look for onMessage calls around the test time window
        # For LAN: look for binary frame received and handler invocation
        local onmessage_count=0
        if [ "$transport" = "cloud" ]; then
            onmessage_count=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "🔥🔥🔥.*onMessage.*CALLED.*wss://hypo.fly.dev|✅ Decoded envelope.*type=CLIPBOARD" 2>/dev/null || echo "0")
        else
            onmessage_count=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "LanWebSocketServer.*Binary frame received|TransportManager.*Invoking incoming clipboard handler" 2>/dev/null || echo "0")
        fi
        
        # Ensure numeric values and convert to integers
        case_found=$(echo "${case_found:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
        handler_success=$(echo "${handler_success:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
        handler_failure=$(echo "${handler_failure:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
        onmessage_count=$(echo "${onmessage_count:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
        db_found=$(echo "${db_found:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
        
        # For LAN messages, also check for binary frame received logs (new Java-WebSocket implementation)
        # This detects messages even if case pattern isn't in logs
        # Check for binary frames in the time window after messages were sent (not filtered by case pattern)
        local binary_frame_received=0
        if [ "$transport" = "lan" ]; then
            # For LAN messages, check for any binary frames received (they don't have case pattern in logs)
            binary_frame_received=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "LanWebSocketServer.*Binary frame received|TransportManager.*Invoking incoming clipboard handler|✅ Decoded envelope.*type=CLIPBOARD" 2>/dev/null || echo "0")
        else
            # For cloud messages, check for onMessage calls (WebSocket client) or decoded envelope logs
            binary_frame_received=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "🔥🔥🔥.*onMessage.*CALLED|✅ Decoded envelope.*type=CLIPBOARD|📥 Received binary message.*fly.dev" 2>/dev/null || echo "0")
        fi
        binary_frame_received=$(echo "${binary_frame_received:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
        
        echo "   📊 Android detection: case_found=$case_found, success=$handler_success, failure=$handler_failure, onMessage=$onmessage_count, binary_frames=$binary_frame_received, db_found=$db_found"
        
        # Check if THIS specific case was received
        # Priority: 1) Database entry (most reliable), 2) Handler success, 3) Case pattern in logs, 4) Reception indicators
        # Database check is the most reliable - if message is stored, it was received
        if [ "${db_found:-0}" -gt 0 ] 2>/dev/null; then
            # Message is in database - definitely received
            local handler_success_any=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "✅.*Decoded clipboard event|IncomingClipboardHandler.*✅.*Decoded" 2>/dev/null || echo "0")
            handler_success_any=$(echo "${handler_success_any:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
            
            if [ "$handler_success_any" -gt 0 ] || [ "$handler_success" -gt 0 ]; then
                log_success "  Android received and processed message (found in database)"
                result="PASSED"
                PASSED_TESTS=$((PASSED_TESTS + 1))
            elif [ "$handler_failure" -gt 0 ]; then
                if [ "$encryption" = "encrypted" ]; then
                    log_warning "  Android received message but decryption failed (found in database but decryption error)"
                    result="PARTIAL"
                    error_msg="Decryption failed (key may have rotated - re-pair devices)"
                else
                    log_warning "  Android received message but processing failed"
                    result="PARTIAL"
                    error_msg="Processing failed (check logs)"
                fi
            else
                log_success "  Android received message (found in database)"
                result="PASSED"
                PASSED_TESTS=$((PASSED_TESTS + 1))
            fi
        elif [ "${handler_success:-0}" -gt 0 ] 2>/dev/null || [ "${case_found:-0}" -gt 0 ] 2>/dev/null || [ "${onmessage_count:-0}" -gt 0 ] 2>/dev/null; then
            # Check if handler successfully processed (even if case pattern not in logs)
            # Handler success can be detected from logs without case pattern
            local handler_success_any=$(adb_cmd logcat -d -t 500 2>/dev/null | grep -cE "IncomingClipboardHandler.*✅.*Decoded clipboard event|✅.*Decoded clipboard event.*type=" 2>/dev/null || echo "0")
            handler_success_any=$(echo "${handler_success_any:-0}" | grep -o '[0-9]*' | head -1 || echo "0")
            
            if [ "$handler_success" -gt 0 ] || [ "$handler_success_any" -gt 0 ]; then
                log_success "  Android received and processed message"
                result="PASSED"
                PASSED_TESTS=$((PASSED_TESTS + 1))
            elif [ "$handler_failure" -gt 0 ]; then
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
                log_warning "  Android received message but handler not invoked"
                result="PARTIAL"
                error_msg="Handler not invoked"
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
    
    # Store result
    echo "$case_num|$result|$error_msg" >> "$RESULTS_FILE"
    
    echo ""
}

# Detailed log verification for a specific test case
verify_test_case_logs() {
    local case_num=$1
    local encryption=$2
    local transport=$3
    local target_platform=$4
    local test_id=$5
    
    log_section "🔍 Detailed Log Verification for Case $case_num"
    echo ""
    
    if [ "$target_platform" = "android" ]; then
        echo "1️⃣  Checking for binary frame reception (LAN server)..."
        local binary_frame=$(adb_cmd logcat -d -t 200 2>/dev/null | grep -cE "LanWebSocketServer.*Binary frame received|📥 Binary frame received" 2>/dev/null | wc -l | tr -d ' \n\r' || echo "0")
        if [ "${binary_frame:-0}" -gt 0 ] 2>/dev/null; then
            log_success "Binary frame received on LAN server"
            adb_cmd logcat -d -t 200 2>/dev/null | grep -E "LanWebSocketServer.*Binary frame received|📥 Binary frame received" | tail -1
        else
            log_error "No binary frame received"
        fi
        echo ""
        
        echo "2️⃣  Checking for handler invocation..."
        local handler_invoke=$(adb_cmd logcat -d -t 200 2>/dev/null | grep -cE "TransportManager.*Invoking incoming clipboard handler" 2>/dev/null | wc -l | tr -d ' \n\r' || echo "0")
        if [ "${handler_invoke:-0}" -gt 0 ] 2>/dev/null; then
            log_success "Handler invoked"
            adb_cmd logcat -d -t 200 2>/dev/null | grep -E "TransportManager.*Invoking incoming clipboard handler" | tail -1
        else
            log_error "Handler not invoked"
        fi
        echo ""
        
        echo "3️⃣  Checking for decoded envelope..."
        local decoded_envelope=$(adb_cmd logcat -d -t 200 2>/dev/null | grep -cE "✅ Decoded envelope.*type=CLIPBOARD" 2>/dev/null | wc -l | tr -d ' \n\r' || echo "0")
        if [ "${decoded_envelope:-0}" -gt 0 ] 2>/dev/null; then
            log_success "Envelope decoded"
            adb_cmd logcat -d -t 200 2>/dev/null | grep -E "✅ Decoded envelope.*type=CLIPBOARD" | tail -1
        else
            log_error "Envelope not decoded"
        fi
        echo ""
        
        echo "4️⃣  Checking for handler success..."
        local handler_success=$(adb_cmd logcat -d -t 200 2>/dev/null | grep -cE "IncomingClipboardHandler.*✅.*Decoded clipboard event" 2>/dev/null | wc -l | tr -d ' \n\r' || echo "0")
        if [ "${handler_success:-0}" -gt 0 ] 2>/dev/null; then
            log_success "Handler successfully processed message"
            adb_cmd logcat -d -t 200 2>/dev/null | grep -E "IncomingClipboardHandler.*✅.*Decoded clipboard event" | tail -1
        else
            log_warning "Handler success not found (checking for failures...)"
        fi
        echo ""
        
        echo "5️⃣  Checking for decryption failures..."
        local decryption_failure=$(adb_cmd logcat -d -t 200 2>/dev/null | grep -cE "IncomingClipboardHandler.*❌.*Failed|BAD_DECRYPT|decryption.*failed" 2>/dev/null | wc -l | tr -d ' \n\r' || echo "0")
        if [ "${decryption_failure:-0}" -gt 0 ] 2>/dev/null; then
            log_error "Decryption failed!"
            adb_cmd logcat -d -t 200 2>/dev/null | grep -E "IncomingClipboardHandler.*❌.*Failed|BAD_DECRYPT|decryption.*failed" | tail -3
            echo ""
            log_warning "💡 Possible causes:"
            echo "      - Key rotation: Devices were re-paired and key changed"
            echo "      - Wrong key: Test script using incorrect key"
            echo "      - Key not found: Key missing from Android keychain"
        else
            log_success "No decryption failures"
        fi
        echo ""
        
        echo "6️⃣  Checking database for message..."
        local db_found=$(adb_cmd shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT COUNT(*) FROM clipboard_items WHERE preview LIKE \"%$test_id%\" OR content LIKE \"%$test_id%\" LIMIT 1;' 2>/dev/null" | tr -d '\r\n' || echo "0")
        if [ "${db_found:-0}" = "0" ] 2>/dev/null; then
            db_found=$(adb_cmd shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT COUNT(*) FROM clipboard_items WHERE preview LIKE \"%$test_id%\" OR content LIKE \"%$test_id%\" LIMIT 1;' 2>/dev/null" | tr -d '\r\n' || echo "0")
        fi
        
        if [ "${db_found:-0}" -gt 0 ] 2>/dev/null; then
            log_success "Message found in database"
            echo "   Querying message details..."
            adb_cmd shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview, created_at FROM clipboard_items WHERE preview LIKE \"%$test_id%\" ORDER BY created_at DESC LIMIT 1;' 2>/dev/null" || \
            adb_cmd shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT preview, created_at FROM clipboard_items WHERE preview LIKE \"%$test_id%\" ORDER BY created_at DESC LIMIT 1;' 2>/dev/null"
        else
            log_error "Message not found in database"
        fi
        echo ""
        
        echo "7️⃣  Checking for database insertion log..."
        local upsert_log=$(adb_cmd logcat -d -t 200 2>/dev/null | grep -cE "Upserting item.*$test_id|ClipboardRepository.*💾.*$test_id" 2>/dev/null | wc -l | tr -d ' \n\r' || echo "0")
        if [ "${upsert_log:-0}" -gt 0 ] 2>/dev/null; then
            log_success "Database insertion logged"
            adb_cmd logcat -d -t 200 2>/dev/null | grep -E "Upserting item.*$test_id|ClipboardRepository.*💾.*$test_id" | tail -1
        else
            log_warning "Database insertion log not found (may be in different format)"
        fi
        echo ""
    else
        # macOS verification
        echo "Checking macOS logs..."
        if [ -f "/tmp/hypo_debug.log" ]; then
            local log_entries=$(grep -c "$test_id" /tmp/hypo_debug.log 2>/dev/null | tr -d '\n' || echo "0")
            if [ "${log_entries:-0}" -gt 0 ]; then
                log_success "Message found in macOS logs ($log_entries entries)"
                grep "$test_id" /tmp/hypo_debug.log | tail -3
            else
                log_error "Message not found in macOS logs"
            fi
        else
            log_warning "macOS debug log not found at /tmp/hypo_debug.log"
        fi
        echo ""
    fi
}

# Print usage information
print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -c, --case NUM          Run specific test case (1-8)
    -v, --verify            Run detailed log verification after test
    -a, --all               Run all 8 test cases (default)
    -h, --help              Show this help message

Examples:
    $0                      # Run all 8 test cases
    $0 -c 8                 # Run only case 8 (Encrypted LAN Android)
    $0 -c 8 -v              # Run case 8 with detailed log verification
    $0 -v                   # Run all cases with detailed verification

Test Cases:
    1. Plaintext + Cloud + macOS
    2. Plaintext + Cloud + Android
    3. Plaintext + LAN + macOS
    4. Plaintext + LAN + Android
    5. Encrypted + Cloud + macOS
    6. Encrypted + Cloud + Android
    7. Encrypted + LAN + macOS
    8. Encrypted + LAN + Android

EOF
}

# Main test execution
main() {
    local test_case=""
    local verify_mode=false
    local run_all=true
    
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--case)
                test_case="$2"
                run_all=false
                shift 2
                ;;
            -v|--verify)
                verify_mode=true
                shift
                ;;
            -a|--all)
                run_all=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
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
    if ! adb devices 2>/dev/null | grep -q "device$"; then
        log_error "Android device not connected"
        exit 1
    fi
    
    # Auto-detect Android device if not set (prefer physical device)
    if [ -z "$ANDROID_ADB_DEVICE" ]; then
        # Prefer physical device over emulator
        ANDROID_ADB_DEVICE=$(adb devices 2>/dev/null | grep "device$" | grep -v "emulator" | head -1 | awk '{print $1}' || echo "")
        if [ -z "$ANDROID_ADB_DEVICE" ]; then
            ANDROID_ADB_DEVICE=$(adb devices 2>/dev/null | grep "device$" | head -1 | awk '{print $1}' || echo "")
        fi
        if [ -n "$ANDROID_ADB_DEVICE" ]; then
            if echo "$ANDROID_ADB_DEVICE" | grep -q "emulator"; then
                log_warning "Auto-detected emulator: $ANDROID_ADB_DEVICE (prefer physical device for LAN tests)"
            else
                log_info "Auto-detected Android device: $ANDROID_ADB_DEVICE"
            fi
        fi
    fi
    
    log_info "Starting test matrix..."
    echo ""
    
    # Clear logcat buffer once at the start
    echo "🧹 Clearing Android logcat buffer..."
    adb_cmd logcat -c > /dev/null 2>&1 || true
    sleep 1
    
    if [ "$run_all" = true ]; then
        # Phase 1: Send all messages first
        log_section "📤 Phase 1: Sending All Messages"
        echo ""
        echo "Sending all 8 test messages in sequence..."
        echo ""
        
        # Send all messages (send_only mode)
        run_test_case 1 "plaintext" "cloud" "macos" "Plaintext Cloud macOS" "send_only"
        sleep 0.5
        run_test_case 2 "plaintext" "cloud" "android" "Plaintext Cloud Android" "send_only"
        sleep 0.5
        run_test_case 3 "plaintext" "lan" "macos" "Plaintext LAN macOS" "send_only"
        sleep 0.5
        run_test_case 4 "plaintext" "lan" "android" "Plaintext LAN Android" "send_only"
        sleep 0.5
        run_test_case 5 "encrypted" "cloud" "macos" "Encrypted Cloud macOS" "send_only"
        sleep 0.5
        run_test_case 6 "encrypted" "cloud" "android" "Encrypted Cloud Android" "send_only"
        sleep 0.5
        run_test_case 7 "encrypted" "lan" "macos" "Encrypted LAN macOS" "send_only"
        sleep 0.5
        run_test_case 8 "encrypted" "lan" "android" "Encrypted LAN Android" "send_only"
        
        echo ""
        log_info "All messages sent. Waiting 10 seconds for delivery and processing..."
        sleep 10
        echo ""
        
        # Phase 2: Check all receptions
        log_section "📥 Phase 2: Checking Reception for All Messages"
        echo ""
        
        # Check each test case reception
        check_test_case_reception 1 "plaintext" "cloud" "macos" "Plaintext Cloud macOS"
        check_test_case_reception 2 "plaintext" "cloud" "android" "Plaintext Cloud Android"
        check_test_case_reception 3 "plaintext" "lan" "macos" "Plaintext LAN macOS"
        check_test_case_reception 4 "plaintext" "lan" "android" "Plaintext LAN Android"
        check_test_case_reception 5 "encrypted" "cloud" "macos" "Encrypted Cloud macOS"
        check_test_case_reception 6 "encrypted" "cloud" "android" "Encrypted Cloud Android"
        check_test_case_reception 7 "encrypted" "lan" "macos" "Encrypted LAN macOS"
        check_test_case_reception 8 "encrypted" "lan" "android" "Encrypted LAN Android"
        
        # Detailed verification if requested
        if [ "$verify_mode" = true ]; then
            echo ""
            log_section "🔍 Detailed Log Verification"
            echo ""
            for case_num in {1..8}; do
                local encryption=""
                local transport=""
                local target=""
                local description=""
                case $case_num in
                    1) encryption="plaintext"; transport="cloud"; target="macos"; description="Plaintext Cloud macOS" ;;
                    2) encryption="plaintext"; transport="cloud"; target="android"; description="Plaintext Cloud Android" ;;
                    3) encryption="plaintext"; transport="lan"; target="macos"; description="Plaintext LAN macOS" ;;
                    4) encryption="plaintext"; transport="lan"; target="android"; description="Plaintext LAN Android" ;;
                    5) encryption="encrypted"; transport="cloud"; target="macos"; description="Encrypted Cloud macOS" ;;
                    6) encryption="encrypted"; transport="cloud"; target="android"; description="Encrypted Cloud Android" ;;
                    7) encryption="encrypted"; transport="lan"; target="macos"; description="Encrypted LAN macOS" ;;
                    8) encryption="encrypted"; transport="lan"; target="android"; description="Encrypted LAN Android" ;;
                esac
                local test_id="Case $case_num:"
                verify_test_case_logs "$case_num" "$encryption" "$transport" "$target" "$test_id"
            done
        fi
    else
        # Run single test case
        if [ -z "$test_case" ] || ! [[ "$test_case" =~ ^[1-8]$ ]]; then
            log_error "Invalid test case: $test_case (must be 1-8)"
            print_usage
            exit 1
        fi
        
        local encryption=""
        local transport=""
        local target=""
        local description=""
        
        case $test_case in
            1) encryption="plaintext"; transport="cloud"; target="macos"; description="Plaintext Cloud macOS" ;;
            2) encryption="plaintext"; transport="cloud"; target="android"; description="Plaintext Cloud Android" ;;
            3) encryption="plaintext"; transport="lan"; target="macos"; description="Plaintext LAN macOS" ;;
            4) encryption="plaintext"; transport="lan"; target="android"; description="Plaintext LAN Android" ;;
            5) encryption="encrypted"; transport="cloud"; target="macos"; description="Encrypted Cloud macOS" ;;
            6) encryption="encrypted"; transport="cloud"; target="android"; description="Encrypted Cloud Android" ;;
            7) encryption="encrypted"; transport="lan"; target="macos"; description="Encrypted LAN macOS" ;;
            8) encryption="encrypted"; transport="lan"; target="android"; description="Encrypted LAN Android" ;;
        esac
        
        log_section "🧪 Running Test Case $test_case: $description"
        echo ""
        
        # Send message
        run_test_case "$test_case" "$encryption" "$transport" "$target" "$description" "send_only"
        
        echo ""
        log_info "Message sent. Waiting 5 seconds for delivery and processing..."
        sleep 5
        echo ""
        
        # Check reception
        check_test_case_reception "$test_case" "$encryption" "$transport" "$target" "$description"
        
        # Detailed verification if requested
        if [ "$verify_mode" = true ]; then
            echo ""
            local test_id="Case $test_case:"
            verify_test_case_logs "$test_case" "$encryption" "$transport" "$target" "$test_id"
        fi
        
        # Exit early (don't print full summary)
        exit 0
    fi
    
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
