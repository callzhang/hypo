#!/bin/bash
# Clipboard Sync Test with 15s Wait Window
# Tests end-to-end clipboard sync between Android and macOS with duplicate detection

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Detect Android SDK
if [ -d "$HOME/Library/Android/sdk" ]; then
    ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
elif [ -d "$PROJECT_ROOT/.android-sdk" ]; then
    ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
else
    echo -e "${RED}❌ Android SDK not found${NC}"
    exit 1
fi

ADB="$ANDROID_SDK_ROOT/platform-tools/adb"

# Check devices
echo -e "${BLUE}=== Checking Devices ===${NC}"
DEVICES=$("$ADB" devices 2>/dev/null | grep -v "List" | grep "device" | wc -l | tr -d ' ')
if [ "$DEVICES" -eq 0 ]; then
    echo -e "${RED}❌ No Android device connected${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Android device connected${NC}"

if ! pgrep -f "HypoMenuBar" > /dev/null; then
    echo -e "${RED}❌ macOS app not running. Please start it first.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ macOS app running${NC}"

# Create log files
LOG_DIR="/tmp/hypo_sync_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
ANDROID_LOG="$LOG_DIR/android.log"
MACOS_LOG="$LOG_DIR/macos.log"
COMBINED_LOG="$LOG_DIR/combined.log"

echo -e "${BLUE}=== Test Logs: $LOG_DIR ===${NC}"

# Clear previous logs
"$ADB" logcat -c >/dev/null 2>&1
echo "" > /tmp/hypo_debug.log

# Start log monitoring
echo -e "${CYAN}Starting log monitoring...${NC}"

# Android log monitoring (filtered)
"$ADB" logcat -v time \
    | grep -E "(ClipboardListener|SyncCoordinator|SyncEngine|IncomingClipboardHandler|LanWebSocketClient|RelayWebSocketClient|📤|📥|📋|✅|❌|Syncing|Broadcasting|Received clipboard|Decoded clipboard)" \
    > "$ANDROID_LOG" &
ANDROID_LOG_PID=$!

# macOS log monitoring (filtered)
tail -f /tmp/hypo_debug.log 2>/dev/null \
    | grep -E "(CLIPBOARD|clipboard|IncomingClipboardHandler|SyncEngine|sync|📤|📥|📋|✅|❌|Synced|Received|Decoded)" \
    > "$MACOS_LOG" &
MACOS_LOG_PID=$!

# Combined log for easier viewing
tail -f "$ANDROID_LOG" "$MACOS_LOG" 2>/dev/null > "$COMBINED_LOG" &
COMBINED_LOG_PID=$!

# Function to wait and show countdown
wait_with_countdown() {
    local seconds=$1
    local message=$2
    echo -e "${YELLOW}$message${NC}"
    for i in $(seq $seconds -1 1); do
        echo -ne "\r${CYAN}Waiting ${i}s...${NC}  "
        sleep 1
    done
    echo -ne "\r${GREEN}Ready!${NC}                    \n"
}

# Function to check logs for pattern
check_log_pattern() {
    local pattern=$1
    local log_file=$2
    local timeout=$3
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if grep -q "$pattern" "$log_file" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

test_result() {
    local test_name=$1
    local passed=$2
    
    if [ $passed -eq 0 ]; then
        echo -e "${GREEN}✅ PASS: $test_name${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}❌ FAIL: $test_name${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Test 1: Android → macOS
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Test 1: Android → macOS Clipboard Sync${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

TEST_TEXT_ANDROID="Test from Android $(date +%H:%M:%S)"
echo -e "${CYAN}📱 Please copy this text on Android:${NC}"
echo -e "${YELLOW}   '$TEST_TEXT_ANDROID'${NC}"
echo ""

wait_with_countdown 15 "⏳ You have 15 seconds to copy the text on Android..."

echo ""
echo -e "${CYAN}Checking logs for sync activity...${NC}"
sleep 2

# Check for sync indicators
SYNC_FOUND=1
if check_log_pattern "Syncing|Broadcasting|📤" "$ANDROID_LOG" 5; then
    echo -e "${GREEN}  ✓ Android sent clipboard${NC}"
    SYNC_FOUND=0
else
    echo -e "${RED}  ✗ No sync activity from Android${NC}"
fi

if check_log_pattern "CLIPBOARD RECEIVED|📥|Decoded clipboard" "$MACOS_LOG" 5; then
    echo -e "${GREEN}  ✓ macOS received clipboard${NC}"
    SYNC_FOUND=0
else
    echo -e "${RED}  ✗ macOS did not receive clipboard${NC}"
fi

# Check for duplicate detection
if grep -q "duplicate|Duplicate" "$ANDROID_LOG" "$MACOS_LOG" 2>/dev/null; then
    echo -e "${CYAN}  ℹ Duplicate detection triggered (expected with dual-send)${NC}"
fi

test_result "Android → macOS Sync" $SYNC_FOUND

# Show recent logs
echo ""
echo -e "${CYAN}Recent Android logs:${NC}"
tail -5 "$ANDROID_LOG" | sed 's/^/  /' || echo "  (no logs)"
echo ""
echo -e "${CYAN}Recent macOS logs:${NC}"
tail -5 "$MACOS_LOG" | sed 's/^/  /' || echo "  (no logs)"

# Test 2: macOS → Android
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Test 2: macOS → Android Clipboard Sync${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

TEST_TEXT_MACOS="Test from macOS $(date +%H:%M:%S)"
echo -e "${CYAN}💻 Please copy this text on macOS:${NC}"
echo -e "${YELLOW}   '$TEST_TEXT_MACOS'${NC}"
echo ""

wait_with_countdown 15 "⏳ You have 15 seconds to copy the text on macOS..."

echo ""
echo -e "${CYAN}Checking logs for sync activity...${NC}"
sleep 2

# Check for sync indicators
SYNC_FOUND=1
if check_log_pattern "Synced|sync|📤" "$MACOS_LOG" 5; then
    echo -e "${GREEN}  ✓ macOS sent clipboard${NC}"
    SYNC_FOUND=0
else
    echo -e "${RED}  ✗ No sync activity from macOS${NC}"
fi

if check_log_pattern "Received clipboard|📥|IncomingClipboardHandler" "$ANDROID_LOG" 5; then
    echo -e "${GREEN}  ✓ Android received clipboard${NC}"
    SYNC_FOUND=0
else
    echo -e "${RED}  ✗ Android did not receive clipboard${NC}"
fi

# Check for duplicate detection
if grep -q "duplicate|Duplicate|hasRecentDuplicate" "$ANDROID_LOG" "$MACOS_LOG" 2>/dev/null; then
    echo -e "${CYAN}  ℹ Duplicate detection triggered (expected with dual-send)${NC}"
fi

test_result "macOS → Android Sync" $SYNC_FOUND

# Show recent logs
echo ""
echo -e "${CYAN}Recent macOS logs:${NC}"
tail -5 "$MACOS_LOG" | sed 's/^/  /' || echo "  (no logs)"
echo ""
echo -e "${CYAN}Recent Android logs:${NC}"
tail -5 "$ANDROID_LOG" | sed 's/^/  /' || echo "  (no logs)"

# Test 3: Duplicate Detection (rapid copy)
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Test 3: Duplicate Detection Test${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

TEST_TEXT_DUP="Duplicate test $(date +%H:%M:%S)"
echo -e "${CYAN}📱 Please copy this text on Android TWICE quickly (within 5 seconds):${NC}"
echo -e "${YELLOW}   '$TEST_TEXT_DUP'${NC}"
echo ""

wait_with_countdown 10 "⏳ You have 10 seconds to copy the same text twice on Android..."

echo ""
echo -e "${CYAN}Checking for duplicate detection...${NC}"
sleep 2

DUP_DETECTED=1
if grep -q "duplicate|Duplicate|hasRecentDuplicate|skip.*duplicate" "$ANDROID_LOG" "$MACOS_LOG" 2>/dev/null; then
    echo -e "${GREEN}  ✓ Duplicate detection working${NC}"
    DUP_DETECTED=0
else
    echo -e "${YELLOW}  ⚠ No duplicate detection logs found${NC}"
    echo -e "${CYAN}  ℹ This may be normal if messages were sent >5s apart${NC}"
fi

test_result "Duplicate Detection" $DUP_DETECTED

# Summary
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Tests Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Tests Failed: $TESTS_FAILED${NC}"
echo ""
echo -e "${CYAN}Log files saved to: $LOG_DIR${NC}"
echo -e "${CYAN}  - Android: $ANDROID_LOG${NC}"
echo -e "${CYAN}  - macOS: $MACOS_LOG${NC}"
echo -e "${CYAN}  - Combined: $COMBINED_LOG${NC}"
echo ""

# Stop log monitoring
kill $ANDROID_LOG_PID $MACOS_LOG_PID $COMBINED_LOG_PID 2>/dev/null || true

# Show key log excerpts
echo -e "${BLUE}Key Log Excerpts:${NC}"
echo ""
echo -e "${CYAN}Android Sync Activity:${NC}"
grep -E "(Syncing|Broadcasting|📤|Received clipboard|Decoded)" "$ANDROID_LOG" | tail -10 | sed 's/^/  /' || echo "  (none found)"
echo ""
echo -e "${CYAN}macOS Sync Activity:${NC}"
grep -E "(Synced|CLIPBOARD RECEIVED|📥|Decoded)" "$MACOS_LOG" | tail -10 | sed 's/^/  /' || echo "  (none found)"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ Some tests failed. Check logs above.${NC}"
    exit 1
fi

