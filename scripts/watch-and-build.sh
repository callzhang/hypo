#!/bin/bash
# Watch for code changes and automatically build Android and macOS apps
# Uses fswatch (install with: brew install fswatch)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get project root
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo -e "${GREEN}🔍 Code Watcher - Auto-build on Changes${NC}"
echo "=============================================="
echo ""
echo -e "${YELLOW}Watching for code changes...${NC}"
echo -e "${BLUE}Press Ctrl+C to stop${NC}"
echo ""

# Check if fswatch is installed
if ! command -v fswatch &> /dev/null; then
    echo -e "${RED}❌ fswatch not found. Install with:${NC}"
    echo "   brew install fswatch"
    exit 1
fi

# Build flags
BUILD_ANDROID=true
BUILD_MACOS=true
BUILD_INSTALL=true  # Auto-install on devices

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-android)
            BUILD_ANDROID=false
            shift
            ;;
        --no-macos)
            BUILD_MACOS=false
            shift
            ;;
        --no-install)
            BUILD_INSTALL=false
            shift
            ;;
        *)
            echo -e "${YELLOW}Unknown option: $1${NC}"
            shift
            ;;
    esac
done

# Directories to watch (exclude build outputs and dependencies)
WATCH_DIRS=(
    "$PROJECT_ROOT/macos/Sources"
    "$PROJECT_ROOT/android/app/src"
    "$PROJECT_ROOT/android/app/build.gradle.kts"
    "$PROJECT_ROOT/android/build.gradle.kts"
)

# File patterns to ignore
IGNORE_PATTERNS=(
    ".*\.swp$"
    ".*\.swp~$"
    ".*~$"
    ".*\.DS_Store$"
    ".*/build/.*"
    ".*/\.gradle/.*"
    ".*/\.idea/.*"
    ".*/\.swiftpm/.*"
    ".*/\.build/.*"
)

# Build function
build_android() {
    echo -e "${YELLOW}📱 Building Android...${NC}"
    # Use clean build if there are build errors (duplicate classes, etc.)
    if "$PROJECT_ROOT/scripts/build-android.sh" > /tmp/hypo-android-build.log 2>&1; then
        echo -e "${GREEN}✅ Android build successful${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️  Build failed, trying clean build...${NC}"
        if "$PROJECT_ROOT/scripts/build-android.sh" clean > /tmp/hypo-android-build.log 2>&1; then
            echo -e "${GREEN}✅ Android build successful (after clean)${NC}"
            return 0
        else
            echo -e "${RED}❌ Android build failed (check /tmp/hypo-android-build.log)${NC}"
            tail -20 /tmp/hypo-android-build.log
            return 1
        fi
    fi
}

build_macos() {
    echo -e "${YELLOW}🍎 Building macOS...${NC}"
    if "$PROJECT_ROOT/scripts/build-macos.sh" > /tmp/hypo-macos-build.log 2>&1; then
        echo -e "${GREEN}✅ macOS build successful${NC}"
        return 0
    else
        echo -e "${RED}❌ macOS build failed (check /tmp/hypo-macos-build.log)${NC}"
        tail -20 /tmp/hypo-macos-build.log
        return 1
    fi
}

# Debounce function - only build if no changes for 2 seconds
LAST_BUILD_TIME=0
DEBOUNCE_DELAY=2

should_build() {
    local current_time=$(date +%s)
    local time_since_last_build=$((current_time - LAST_BUILD_TIME))
    
    if [ $time_since_last_build -ge $DEBOUNCE_DELAY ]; then
        LAST_BUILD_TIME=$current_time
        return 0
    fi
    return 1
}

# Build handler
handle_change() {
    local file="$1"
    
    # Skip if file doesn't exist (might be deleted)
    [ ! -f "$file" ] && [ ! -d "$file" ] && return
    
    # Skip ignored patterns
    for pattern in "${IGNORE_PATTERNS[@]}"; do
        if echo "$file" | grep -qE "$pattern"; then
            return
        fi
    done
    
    # Debounce
    if ! should_build; then
        return
    fi
    
    echo ""
    echo -e "${BLUE}📝 Change detected: ${file#$PROJECT_ROOT/}${NC}"
    
    # Determine which platform to build based on file path
    local build_android_now=false
    local build_macos_now=false
    
    if [[ "$file" == *"/android/"* ]]; then
        build_android_now=true
    elif [[ "$file" == *"/macos/"* ]]; then
        build_macos_now=true
    else
        # Shared code - build both
        build_android_now=true
        build_macos_now=true
    fi
    
    # Build Android
    if [ "$BUILD_ANDROID" = true ] && [ "$build_android_now" = true ]; then
        build_android
    fi
    
    # Build macOS
    if [ "$BUILD_MACOS" = true ] && [ "$build_macos_now" = true ]; then
        build_macos
    fi
    
    echo ""
    echo -e "${YELLOW}👀 Watching for changes...${NC}"
}

# Initial build
echo -e "${YELLOW}🔨 Running initial build...${NC}"
if [ "$BUILD_ANDROID" = true ]; then
    build_android
fi
if [ "$BUILD_MACOS" = true ]; then
    build_macos
fi
echo ""

# Start watching
echo -e "${GREEN}✅ Watching for changes...${NC}"
echo ""

# Use fswatch to watch directories
fswatch -o "${WATCH_DIRS[@]}" | while read -r num; do
    # Get the changed files
    fswatch -1 "${WATCH_DIRS[@]}" | while read -r file; do
        handle_change "$file"
    done
done

