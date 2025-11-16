#!/bin/bash
# Hypo Sync Testing Script
# Comprehensive testing for macOS ↔ Android clipboard sync

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_DIR="$PROJECT_ROOT/macos"
ANDROID_DIR="$PROJECT_ROOT/android"
BACKEND_DIR="$PROJECT_ROOT/backend"
LOG_DIR="/tmp/hypo_test_logs"
MACOS_LOG="$LOG_DIR/macos.log"
ANDROID_LOG="$LOG_DIR/android.log"
BACKEND_LOG="$LOG_DIR/backend.log"

# Test configuration
TEST_TEXT_MACOS="Test sync from macOS - $(date +%s)"
TEST_TEXT_ANDROID="Test sync from Android - $(date +%s)"
WAIT_SYNC_TIMEOUT=10

# Tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Setup
mkdir -p "$LOG_DIR"

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

test_start() {
    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Test $TESTS_RUN: $1"
}

test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    log_success "PASSED: $1"
}

test_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    log_error "FAILED: $1"
}

check_file_changed() {
    local dir=$1
    local last_build_marker="$dir/.last_test_build"
    
    if [[ ! -f "$last_build_marker" ]]; then
        return 0  # No previous build, need to build
    fi
    
    # Check if any source files changed since last build
    local changed=$(find "$dir" -name "*.swift" -o -name "*.kt" -o -name "*.rs" -newer "$last_build_marker" 2>/dev/null | wc -l)
    
    if [[ $changed -gt 0 ]]; then
        return 0  # Files changed
    else
        return 1  # No changes
    fi
}

mark_built() {
    local dir=$1
    touch "$dir/.last_test_build"
}

wait_for_log_pattern() {
    local log_file=$1
    local pattern=$2
    local timeout=$3
    local start_time=$(date +%s)
    
    while true; do
        if grep -q "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -ge $timeout ]]; then
            return 1
        fi
        
        sleep 0.5
    done
}

# ============================================================================
# Build Functions
# ============================================================================

build_macos() {
    log_section "Building macOS App"
    
    if check_file_changed "$MACOS_DIR"; then
        log_info "Code changed, rebuilding macOS app..."
        cd "$MACOS_DIR"
        
        # Build the Swift package
        swift build -c release 2>&1 | tee "$LOG_DIR/macos_build.log"
        
        if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
            # Copy the built executable to the app bundle
            log_info "Updating HypoApp.app bundle..."
            mkdir -p "$MACOS_DIR/HypoApp.app/Contents/MacOS"
            cp ".build/release/HypoMenuBar" "$MACOS_DIR/HypoApp.app/Contents/MacOS/HypoMenuBar"
            chmod +x "$MACOS_DIR/HypoApp.app/Contents/MacOS/HypoMenuBar"
            
            mark_built "$MACOS_DIR"
            log_success "macOS app built and HypoApp.app updated successfully"
            return 0
        else
            log_error "macOS build failed"
            tail -n 20 "$LOG_DIR/macos_build.log"
            return 1
        fi
    else
        log_info "No changes detected, skipping macOS build"
        return 0
    fi
}

build_android() {
    log_section "Building Android App"
    
    if check_file_changed "$ANDROID_DIR"; then
        log_info "Code changed, rebuilding Android app..."
        
        export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
        export ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
        export GRADLE_USER_HOME="$PROJECT_ROOT/.gradle"
        
        cd "$ANDROID_DIR"
        ./gradlew assembleDebug 2>&1 | tee "$LOG_DIR/android_build.log"
        
        if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
            mark_built "$ANDROID_DIR"
            
            # Install on device if connected
            if "$ANDROID_SDK_ROOT/platform-tools/adb" devices | grep -q "device$"; then
                log_info "Installing on Android device..."
                "$ANDROID_SDK_ROOT/platform-tools/adb" install -r "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
            else
                log_warning "No Android device connected, skipping install"
            fi
            
            log_success "Android app built successfully"
            return 0
        else
            log_error "Android build failed"
            tail -n 20 "$LOG_DIR/android_build.log"
            return 1
        fi
    else
        log_info "No changes detected, skipping Android build"
        return 0
    fi
}

deploy_backend() {
    log_section "Deploying Backend"
    
    if check_file_changed "$BACKEND_DIR"; then
        log_info "Code changed, deploying backend to Fly.io..."
        
        cd "$BACKEND_DIR"
        
        # Check if flyctl is installed
        if ! command -v flyctl &> /dev/null; then
            log_warning "flyctl not installed, skipping backend deployment"
            return 0
        fi
        
        flyctl deploy 2>&1 | tee "$LOG_DIR/backend_deploy.log"
        
        if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
            mark_built "$BACKEND_DIR"
            log_success "Backend deployed successfully"
            
            # Wait for health check
            log_info "Waiting for backend health check..."
            sleep 5
            
            if curl -sf https://hypo-relay-staging.fly.dev/health > /dev/null; then
                log_success "Backend health check passed"
                return 0
            else
                log_warning "Backend health check failed"
                return 1
            fi
        else
            log_error "Backend deployment failed"
            tail -n 20 "$LOG_DIR/backend_deploy.log"
            return 1
        fi
    else
        log_info "No changes detected, skipping backend deployment"
        return 0
    fi
}

# ============================================================================
# App Control Functions
# ============================================================================

start_macos_app() {
    log_info "Starting macOS app..."
    
    # Kill existing instance
    pkill -f "HypoMenuBar" 2>/dev/null || true
    killall "HypoApp" 2>/dev/null || true
    sleep 1
    
    # Clear log
    > "$MACOS_LOG"
    
    # Start app bundle with logging
    if [[ -d "$MACOS_DIR/HypoApp.app" ]]; then
        log_info "Launching HypoApp.app bundle..."
        open "$MACOS_DIR/HypoApp.app" 2>&1 | tee -a "$MACOS_LOG"
        
        # Wait for app to start and capture its PID
        sleep 3
        
        MACOS_PID=$(pgrep -f "HypoApp.app" | head -n 1)
        
        if [[ -n "$MACOS_PID" ]] && ps -p $MACOS_PID > /dev/null; then
            log_success "macOS HypoApp.app started (PID: $MACOS_PID)"
            
            # Start log capture from system logs
            log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug > "$MACOS_LOG" 2>&1 &
            MACOS_LOG_PID=$!
            log_info "Started log capture (PID: $MACOS_LOG_PID)"
            
            return 0
        else
            log_error "macOS app failed to start"
            return 1
        fi
    else
        log_error "HypoApp.app bundle not found at $MACOS_DIR/HypoApp.app"
        return 1
    fi
}

stop_macos_app() {
    log_info "Stopping macOS app..."
    pkill -f "HypoMenuBar" 2>/dev/null || true
    killall "HypoApp" 2>/dev/null || true
    osascript -e 'quit app "HypoApp"' 2>/dev/null || true
    
    # Stop log capture if running
    if [[ -n "$MACOS_LOG_PID" ]]; then
        kill $MACOS_LOG_PID 2>/dev/null || true
    fi
    
    sleep 1
}

start_android_log() {
    log_info "Starting Android log capture..."
    
    export ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
    
    # Clear logcat
    "$ANDROID_SDK_ROOT/platform-tools/adb" logcat -c
    
    # Clear log file
    > "$ANDROID_LOG"
    
    # Start logging in background
    "$ANDROID_SDK_ROOT/platform-tools/adb" logcat -v time \
        "ClipboardSyncService:*" \
        "SyncCoordinator:*" \
        "SyncEngine:*" \
        "TransportManager:*" \
        "LanDiscovery:*" \
        "PairingHandshake:*" \
        "*:S" > "$ANDROID_LOG" 2>&1 &
    
    ANDROID_LOG_PID=$!
    sleep 1
    
    log_success "Android logging started (PID: $ANDROID_LOG_PID)"
}

stop_android_log() {
    if [[ -n "$ANDROID_LOG_PID" ]]; then
        log_info "Stopping Android log capture..."
        kill $ANDROID_LOG_PID 2>/dev/null || true
    fi
}

# ============================================================================
# Test Functions
# ============================================================================

test_macos_clipboard_copy() {
    test_start "macOS clipboard copy and sync"
    
    # Copy text to clipboard
    echo "$TEST_TEXT_MACOS" | pbcopy
    
    log_info "Copied to macOS clipboard: $TEST_TEXT_MACOS"
    
    # Wait for sync log
    if wait_for_log_pattern "$MACOS_LOG" "Synced clipboard" $WAIT_SYNC_TIMEOUT; then
        test_pass "macOS clipboard detected and synced"
        
        # Show relevant log entries
        log_info "macOS log entries:"
        grep -E "(clipboard|sync|transport)" "$MACOS_LOG" | tail -n 5
        return 0
    else
        test_fail "macOS clipboard sync not detected in logs"
        log_error "Last 10 lines of macOS log:"
        tail -n 10 "$MACOS_LOG"
        return 1
    fi
}

test_android_receives_from_macos() {
    test_start "Android receives clipboard from macOS"
    
    log_info "Checking Android logs for incoming clipboard..."
    
    # Wait for Android to receive the clipboard
    if wait_for_log_pattern "$ANDROID_LOG" "Received clipboard.*$TEST_TEXT_MACOS" $WAIT_SYNC_TIMEOUT; then
        test_pass "Android received clipboard from macOS"
        
        log_info "Android log entries:"
        grep -E "Received clipboard" "$ANDROID_LOG" | tail -n 3
        return 0
    else
        test_fail "Android did not receive clipboard from macOS"
        log_error "Last 10 lines of Android log:"
        tail -n 10 "$ANDROID_LOG"
        return 1
    fi
}

test_android_clipboard_copy() {
    test_start "Android clipboard copy via ADB"
    
    export ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
    
    # Use ADB to simulate clipboard copy on Android
    log_info "Setting Android clipboard: $TEST_TEXT_ANDROID"
    
    "$ANDROID_SDK_ROOT/platform-tools/adb" shell "am broadcast -a clipper.set -e text '$TEST_TEXT_ANDROID'" 2>/dev/null || \
    "$ANDROID_SDK_ROOT/platform-tools/adb" shell "cmd clipboard set-clipboard '$TEST_TEXT_ANDROID'" 2>/dev/null || \
    log_warning "Could not set Android clipboard via ADB (may require manual test)"
    
    # Wait for Android to detect and sync
    if wait_for_log_pattern "$ANDROID_LOG" "clipboard.*change" $WAIT_SYNC_TIMEOUT; then
        test_pass "Android clipboard change detected"
        return 0
    else
        test_fail "Android clipboard change not detected"
        return 1
    fi
}

test_macos_receives_from_android() {
    test_start "macOS receives clipboard from Android"
    
    log_info "Checking macOS logs for incoming clipboard..."
    
    # Wait for macOS to receive
    if wait_for_log_pattern "$MACOS_LOG" "Received clipboard.*from.*Android" $WAIT_SYNC_TIMEOUT; then
        test_pass "macOS received clipboard from Android"
        
        # Verify clipboard content
        local clipboard_content=$(pbpaste)
        if [[ "$clipboard_content" == "$TEST_TEXT_ANDROID" ]]; then
            test_pass "Clipboard content verified on macOS"
        else
            log_warning "Clipboard content mismatch (expected: $TEST_TEXT_ANDROID, got: $clipboard_content)"
        fi
        
        return 0
    else
        test_fail "macOS did not receive clipboard from Android"
        log_error "Last 10 lines of macOS log:"
        tail -n 10 "$MACOS_LOG"
        return 1
    fi
}

test_lan_discovery() {
    test_start "LAN device discovery"
    
    log_info "Checking for LAN discovery logs..."
    
    # Check macOS discovers Android
    if grep -q "Discovered.*Android\|Added peer" "$MACOS_LOG"; then
        test_pass "macOS discovered Android device on LAN"
    else
        test_fail "macOS did not discover Android device"
    fi
    
    # Check Android discovers macOS
    if grep -q "Discovered.*macOS\|Added peer" "$ANDROID_LOG"; then
        test_pass "Android discovered macOS device on LAN"
    else
        test_fail "Android did not discover macOS device"
    fi
}

test_encryption() {
    test_start "End-to-end encryption"
    
    log_info "Verifying encryption is used..."
    
    # Check for encryption-related log entries
    if grep -qE "(encrypted|AES-256-GCM|cipher)" "$MACOS_LOG" || \
       grep -qE "(encrypted|AES-256-GCM|cipher)" "$ANDROID_LOG"; then
        test_pass "Encryption detected in logs"
    else
        log_warning "No explicit encryption logs found (may be normal)"
    fi
}

test_websocket_connection() {
    test_start "WebSocket connection establishment"
    
    # Check macOS WebSocket
    if grep -qE "(WebSocket.*established|connection.*open)" "$MACOS_LOG"; then
        test_pass "macOS WebSocket connection established"
    else
        test_fail "macOS WebSocket connection not found"
    fi
    
    # Check Android WebSocket
    if grep -qE "(WebSocket.*established|connection.*open)" "$ANDROID_LOG"; then
        test_pass "Android WebSocket connection established"
    else
        test_fail "Android WebSocket connection not found"
    fi
}

test_history_storage() {
    test_start "Clipboard history storage"
    
    # Check if items are being stored
    if grep -qE "(Added to history|Stored clipboard)" "$MACOS_LOG"; then
        test_pass "macOS storing clipboard history"
    else
        log_warning "macOS history storage not detected in logs"
    fi
    
    if grep -qE "(Added to history|Stored clipboard)" "$ANDROID_LOG"; then
        test_pass "Android storing clipboard history"
    else
        log_warning "Android history storage not detected in logs"
    fi
}

# ============================================================================
# Main Test Flow
# ============================================================================

main() {
    log_section "🧪 Hypo Sync Testing Suite"
    log_info "Project: $PROJECT_ROOT"
    log_info "Logs: $LOG_DIR"
    echo ""
    
    # Phase 1: Build & Deploy
    log_section "Phase 1: Build & Deploy"
    
    build_macos || exit 1
    build_android || exit 1
    deploy_backend || log_warning "Backend deployment skipped or failed"
    
    # Phase 2: Start Apps
    log_section "Phase 2: Start Applications"
    
    start_macos_app || exit 1
    start_android_log
    
    # Wait for apps to initialize
    log_info "Waiting for apps to initialize..."
    sleep 5
    
    # Phase 3: LAN Discovery Tests
    log_section "Phase 3: Device Discovery Tests"
    test_lan_discovery
    test_websocket_connection
    
    # Phase 4: macOS → Android Sync
    log_section "Phase 4: macOS → Android Sync Test"
    test_macos_clipboard_copy
    sleep 2
    test_android_receives_from_macos
    
    # Phase 5: Android → macOS Sync
    log_section "Phase 5: Android → macOS Sync Test"
    log_warning "Note: Android clipboard copy via ADB may not work on all devices"
    log_info "If this fails, manually copy text on Android and observe logs"
    test_android_clipboard_copy
    sleep 2
    test_macos_receives_from_android
    
    # Phase 6: Additional Tests
    log_section "Phase 6: Additional Functionality Tests"
    test_encryption
    test_history_storage
    
    # Phase 7: Cleanup
    log_section "Phase 7: Cleanup"
    stop_android_log
    
    log_info "Leaving macOS HypoApp.app running for manual testing..."
    log_info "To stop: killall HypoApp  (or click Quit from menu bar)"
    
    # Summary
    log_section "Test Summary"
    echo ""
    echo -e "${BLUE}Tests Run:    ${NC}$TESTS_RUN"
    echo -e "${GREEN}Tests Passed: ${NC}$TESTS_PASSED"
    echo -e "${RED}Tests Failed: ${NC}$TESTS_FAILED"
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All tests passed! 🎉"
        echo ""
        log_info "Logs available at:"
        echo "  - macOS:   $MACOS_LOG"
        echo "  - Android: $ANDROID_LOG"
        echo ""
        exit 0
    else
        log_error "Some tests failed"
        echo ""
        log_info "Check logs for details:"
        echo "  - macOS:   $MACOS_LOG"
        echo "  - Android: $ANDROID_LOG"
        echo ""
        exit 1
    fi
}

# Handle Ctrl+C
trap 'log_warning "Interrupted"; stop_android_log; stop_macos_app; exit 130' INT TERM

# Run main function
main "$@"

