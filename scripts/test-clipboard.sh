#!/bin/bash
# Unified Clipboard Sync Testing Script
# Consolidates: test-sync.sh, test-clipboard-sync-15s.sh, test-pairing-and-sync.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# Usage
usage() {
    echo "Usage: $0 [mode]"
    echo ""
    echo "Modes:"
    echo "  quick      - Quick sync test with 15s wait window (default)"
    echo "  full       - Full comprehensive test suite"
    echo "  pairing    - Pairing + sync test"
    echo "  duplicate  - Duplicate detection test"
    echo ""
    exit 1
}

MODE="${1:-quick}"

# Check devices
check_devices() {
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
}

# Quick test mode (15s wait window)
test_quick() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Quick Clipboard Sync Test (15s wait window)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    
    LOG_DIR="/tmp/hypo_sync_test_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$LOG_DIR"
    ANDROID_LOG="$LOG_DIR/android.log"
    MACOS_LOG="$LOG_DIR/macos.log"
    
    "$ADB" logcat -c >/dev/null 2>&1
    echo "" > /tmp/hypo_debug.log
    
    # Start log monitoring
    "$ADB" logcat -v time | grep -E "(ClipboardListener|SyncCoordinator|SyncEngine|IncomingClipboardHandler|📤|📥|📋|✅|❌|Syncing|Broadcasting|Received clipboard|Decoded clipboard)" > "$ANDROID_LOG" &
    ANDROID_LOG_PID=$!
    
    tail -f /tmp/hypo_debug.log 2>/dev/null | grep -E "(CLIPBOARD|clipboard|IncomingClipboardHandler|SyncEngine|sync|📤|📥|📋|✅|❌|Synced|Received|Decoded)" > "$MACOS_LOG" &
    MACOS_LOG_PID=$!
    
    # Test Android → macOS
    echo ""
    echo -e "${CYAN}📱 Test 1: Android → macOS${NC}"
    TEST_TEXT="Test from Android $(date +%H:%M:%S)"
    echo -e "${YELLOW}   Please copy: '$TEST_TEXT'${NC}"
    echo -e "${YELLOW}   You have 15 seconds...${NC}"
    for i in {15..1}; do
        echo -ne "\r${CYAN}Waiting ${i}s...${NC}  "
        sleep 1
    done
    echo -ne "\r${GREEN}Ready!${NC}                    \n"
    sleep 2
    
    if grep -q "Syncing\|Broadcasting\|📤" "$ANDROID_LOG" 2>/dev/null && \
       grep -q "CLIPBOARD RECEIVED\|📥\|Decoded" "$MACOS_LOG" 2>/dev/null; then
        echo -e "${GREEN}✅ Android → macOS sync working${NC}"
    else
        echo -e "${RED}❌ Android → macOS sync failed${NC}"
    fi
    
    # Test macOS → Android
    echo ""
    echo -e "${CYAN}💻 Test 2: macOS → Android${NC}"
    TEST_TEXT="Test from macOS $(date +%H:%M:%S)"
    echo -e "${YELLOW}   Please copy: '$TEST_TEXT'${NC}"
    echo -e "${YELLOW}   You have 15 seconds...${NC}"
    for i in {15..1}; do
        echo -ne "\r${CYAN}Waiting ${i}s...${NC}  "
        sleep 1
    done
    echo -ne "\r${GREEN}Ready!${NC}                    \n"
    sleep 2
    
    if grep -q "Synced\|sync\|📤" "$MACOS_LOG" 2>/dev/null && \
       grep -q "Received clipboard\|📥\|IncomingClipboardHandler" "$ANDROID_LOG" 2>/dev/null; then
        echo -e "${GREEN}✅ macOS → Android sync working${NC}"
    else
        echo -e "${RED}❌ macOS → Android sync failed${NC}"
    fi
    
    kill $ANDROID_LOG_PID $MACOS_LOG_PID 2>/dev/null || true
    echo -e "${CYAN}Logs saved to: $LOG_DIR${NC}"
}

# Full test mode
test_full() {
    echo -e "${BLUE}Running full test suite...${NC}"
    # Use existing test-sync.sh for full suite
    bash "$PROJECT_ROOT/scripts/test-sync.sh"
}

# Pairing test mode
test_pairing() {
    echo -e "${BLUE}Running pairing + sync test...${NC}"
    # Use existing test-pairing-and-sync.sh
    bash "$PROJECT_ROOT/scripts/test-pairing-and-sync.sh"
}

# Duplicate detection test
test_duplicate() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Duplicate Detection Test${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    
    LOG_DIR="/tmp/hypo_dup_test_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$LOG_DIR"
    ANDROID_LOG="$LOG_DIR/android.log"
    MACOS_LOG="$LOG_DIR/macos.log"
    
    "$ADB" logcat -c >/dev/null 2>&1
    echo "" > /tmp/hypo_debug.log
    
    "$ADB" logcat -v time | grep -E "(duplicate|Duplicate|hasRecentDuplicate|skip)" > "$ANDROID_LOG" &
    ANDROID_LOG_PID=$!
    
    tail -f /tmp/hypo_debug.log 2>/dev/null | grep -E "(duplicate|Duplicate|skip|Skipping)" > "$MACOS_LOG" &
    MACOS_LOG_PID=$!
    
    TEST_TEXT="Duplicate test $(date +%H:%M:%S)"
    echo -e "${CYAN}📱 Please copy this text on Android TWICE quickly (within 5 seconds):${NC}"
    echo -e "${YELLOW}   '$TEST_TEXT'${NC}"
    echo -e "${YELLOW}   You have 10 seconds...${NC}"
    for i in {10..1}; do
        echo -ne "\r${CYAN}Waiting ${i}s...${NC}  "
        sleep 1
    done
    echo -ne "\r${GREEN}Ready!${NC}                    \n"
    sleep 2
    
    if grep -q "duplicate\|Duplicate\|hasRecentDuplicate\|skip" "$ANDROID_LOG" "$MACOS_LOG" 2>/dev/null; then
        echo -e "${GREEN}✅ Duplicate detection working${NC}"
    else
        echo -e "${YELLOW}⚠️  No duplicate detection logs (may be normal if >5s apart)${NC}"
    fi
    
    kill $ANDROID_LOG_PID $MACOS_LOG_PID 2>/dev/null || true
    echo -e "${CYAN}Logs saved to: $LOG_DIR${NC}"
}

# Main
case "$MODE" in
    quick)
        check_devices
        test_quick
        ;;
    full)
        check_devices
        test_full
        ;;
    pairing)
        check_devices
        test_pairing
        ;;
    duplicate)
        check_devices
        test_duplicate
        ;;
    *)
        usage
        ;;
esac



