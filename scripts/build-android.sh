#!/bin/bash
# Hypo Android Build Script
# Builds the Android APK with proper environment configuration
# 
# Usage:
#   ./scripts/build-android.sh              # Build debug (default)
#   ./scripts/build-android.sh release       # Build release
#   ./scripts/build-android.sh both          # Build both debug and release
#   ./scripts/build-android.sh clean         # Clean and build debug
#   ./scripts/build-android.sh clean release # Clean and build release
#   ./scripts/build-android.sh clean both    # Clean and build both

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔨 Hypo Android Build Script${NC}"
echo "================================"
echo ""

# Get project root (script is in scripts/ directory)
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Check for Java 17
echo -e "${YELLOW}Checking Java...${NC}"
if ! command -v java &> /dev/null; then
    echo -e "${RED}❌ Java not found. Please install OpenJDK 17:${NC}"
    echo "   brew install openjdk@17"
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
if [ "$JAVA_VERSION" != "17" ]; then
    echo -e "${YELLOW}⚠️  Java version is $JAVA_VERSION, but 17 is required.${NC}"
    echo "   Set JAVA_HOME to OpenJDK 17 location"
fi

# Set up environment variables
echo -e "${YELLOW}Setting up environment...${NC}"

# Java Home (try Homebrew location first, then system java_home)
if [ -z "$JAVA_HOME" ]; then
    if [ -d "/opt/homebrew/opt/openjdk@17" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
        export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
        echo "   Using Homebrew OpenJDK 17"
    elif command -v /usr/libexec/java_home &> /dev/null; then
        # Try to find Java 17 via java_home
        JAVA_17_HOME=$(/usr/libexec/java_home -v 17 2>/dev/null || echo "")
        if [ -n "$JAVA_17_HOME" ] && [ -d "$JAVA_17_HOME" ]; then
            export JAVA_HOME="$JAVA_17_HOME"
            echo "   Using system Java 17: $JAVA_HOME"
        else
            echo -e "${RED}❌ JAVA_HOME not set and Java 17 not found${NC}"
            echo "   Install with: brew install openjdk@17"
            exit 1
        fi
    else
        echo -e "${RED}❌ JAVA_HOME not set and Homebrew OpenJDK 17 not found${NC}"
        echo "   Install with: brew install openjdk@17"
        exit 1
    fi
fi

# Android SDK
if [ -z "$ANDROID_SDK_ROOT" ]; then
    if [ -d "$PROJECT_ROOT/.android-sdk" ]; then
        export ANDROID_SDK_ROOT="$PROJECT_ROOT/.android-sdk"
        echo "   Using project Android SDK: $ANDROID_SDK_ROOT"
    elif [ -d "$HOME/Library/Android/sdk" ]; then
        export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
        echo "   Using Android Studio SDK: $ANDROID_SDK_ROOT"
    else
        echo -e "${RED}❌ Android SDK not found. Run setup script:${NC}"
        echo "   ./scripts/setup-android-sdk.sh"
        exit 1
    fi
fi

# Gradle User Home (optional, for reproducible builds)
if [ -z "$GRADLE_USER_HOME" ]; then
    export GRADLE_USER_HOME="$PROJECT_ROOT/android/.gradle"
fi

echo "   JAVA_HOME: $JAVA_HOME"
echo "   ANDROID_SDK_ROOT: $ANDROID_SDK_ROOT"
echo "   GRADLE_USER_HOME: $GRADLE_USER_HOME"
echo ""

# Ensure app icons exist
echo -e "${YELLOW}Checking app icons...${NC}"
ICON_SCRIPT="$PROJECT_ROOT/scripts/generate-icons.py"
ANDROID_RES="$PROJECT_ROOT/android/app/src/main/res"
ICON_CHECK="$ANDROID_RES/mipmap-xxxhdpi/ic_launcher.png"

if [ ! -f "$ICON_CHECK" ]; then
    if [ -f "$ICON_SCRIPT" ]; then
        echo "   Icons not found. Generating..."
        python3 "$ICON_SCRIPT" || echo -e "${YELLOW}⚠️  Icon generation failed, continuing without icons${NC}"
    else
        echo -e "${YELLOW}⚠️  Icon generation script not found. App will build without icons.${NC}"
    fi
elif [ -f "$ICON_SCRIPT" ] && [ "$ICON_SCRIPT" -nt "$ICON_CHECK" ]; then
    echo "   Icon generation script is newer than icons, regenerating..."
    python3 "$ICON_SCRIPT" 2>/dev/null || echo -e "${YELLOW}⚠️  Icon regeneration failed, using existing icons${NC}"
else
    echo "   Icons are up to date"
fi
echo ""

# Build
# Load .env file if it exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    echo -e "${YELLOW}Loading .env file...${NC}"
    set -a  # automatically export all variables
    source "$PROJECT_ROOT/.env"
    set +a  # stop automatically exporting
fi

echo -e "${YELLOW}Building Android APK...${NC}"
cd "$PROJECT_ROOT/android"

# Parse arguments
BUILD_TYPE="debug"  # default: build debug only
CLEAN_BUILD=false

for arg in "$@"; do
    case "$arg" in
        clean)
            CLEAN_BUILD=true
            ;;
        debug)
            BUILD_TYPE="debug"
            ;;
        release)
            BUILD_TYPE="release"
            ;;
        both|all)
            BUILD_TYPE="both"
            ;;
        *)
            echo -e "${YELLOW}⚠️  Unknown argument: $arg${NC}"
            echo "   Usage: $0 [clean] [debug|release|both]"
            echo "   Default: debug"
            ;;
    esac
done

# Clean build if requested
if [ "$CLEAN_BUILD" = true ]; then
    echo "   Running clean build..."
    ./gradlew clean
fi

# Build function
build_apk() {
    local variant=$1
    # Capitalize first letter for Gradle task name
    local capitalized_variant=$(echo "$variant" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    local task="assemble$capitalized_variant"  # assembleDebug or assembleRelease
    
    # Create temp file for build output (mktemp requires Xs at end on macOS)
    local build_log
    build_log=$(mktemp "${TMPDIR:-/tmp}/hypo-build-android-XXXXXX") || {
        echo -e "${RED}❌ Failed to create temp build log${NC}"
        return 1
    }
    
    echo ""
    echo -e "${YELLOW}Building $variant APK...${NC}"
    set +e  # Temporarily disable exit on error to handle return codes
    ./gradlew "$task" --stacktrace 2>&1 | tee "$build_log"
    local build_result=${PIPESTATUS[0]}
    set -e  # Re-enable exit on error
    
    # Check for duplicate class errors (Hilt annotation processor issue)
    if [ $build_result -ne 0 ] && grep -q "is defined multiple times\|duplicate class" "$build_log"; then
        echo -e "${YELLOW}⚠️  Duplicate class error detected, cleaning build...${NC}"
        ./gradlew clean 2>&1 | tee -a "$build_log"
        echo -e "${YELLOW}Rebuilding after clean...${NC}"
        set +e
        ./gradlew "$task" --stacktrace 2>&1 | tee -a "$build_log"
        build_result=${PIPESTATUS[0]}
        set -e
    fi

    # Gradle distribution cache corruption (missing GradleMain)
    if [ $build_result -ne 0 ] && grep -q "ClassNotFoundException: org.gradle.launcher.GradleMain" "$build_log"; then
        echo -e "${YELLOW}⚠️  Gradle distribution appears corrupted, clearing wrapper cache...${NC}"
        ./gradlew --stop >/dev/null 2>&1 || true
        rm -rf "$GRADLE_USER_HOME/wrapper/dists/gradle-"*
        echo -e "${YELLOW}Rebuilding after cache clear...${NC}"
        set +e
        ./gradlew "$task" --stacktrace 2>&1 | tee -a "$build_log"
        build_result=${PIPESTATUS[0]}
        set -e
    fi
    
    # Determine APK path based on variant
    # Note: Both debug and release use the same package name (com.hypo.clipboard)
    if [ "$variant" = "debug" ]; then
        APK_PATH="app/build/outputs/apk/debug/app-debug.apk"
    else
        APK_PATH="app/build/outputs/apk/release/app-release.apk"
    fi
    PACKAGE_NAME="com.hypo.clipboard"
    
    if [ $build_result -eq 0 ] && [ -f "$APK_PATH" ]; then
        APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
        APK_SHA=$(shasum -a 256 "$APK_PATH" | cut -d' ' -f1)
        
        echo ""
        echo -e "${GREEN}✅ $variant build successful!${NC}"
        echo "   APK: android/$APK_PATH"
        echo "   Size: $APK_SIZE"
        echo "   SHA-256: $APK_SHA"
        rm -f "$build_log"
        return 0
    else
        echo ""
        echo -e "${RED}❌ $variant build failed${NC}"
        if [ $build_result -ne 0 ]; then
            echo "   Gradle build returned error code: $build_result"
            if [ $build_result -eq 137 ]; then
                echo "   Gradle was killed (137). Try reducing heap:"
                echo "   ORG_GRADLE_PROJECT_org.gradle.jvmargs='-Xmx2048m -Dfile.encoding=UTF-8' \\"
                echo "   ./scripts/build-android.sh release"
            fi
            echo ""
            echo -e "${YELLOW}Last 30 lines of build output:${NC}"
            tail -n 30 "$build_log" | sed 's/^/   /'
        fi
        if [ ! -f "$APK_PATH" ]; then
            echo "   APK not found at: $APK_PATH"
        fi
        rm -f "$build_log"
        return 1
    fi
}

# Build based on BUILD_TYPE
BUILD_SUCCESS=true

if [ "$BUILD_TYPE" = "debug" ] || [ "$BUILD_TYPE" = "both" ]; then
    if ! build_apk "debug"; then
        BUILD_SUCCESS=false
    fi
fi

if [ "$BUILD_TYPE" = "release" ] || [ "$BUILD_TYPE" = "both" ]; then
    if ! build_apk "release"; then
        BUILD_SUCCESS=false
    fi
fi

if [ "$BUILD_SUCCESS" = false ]; then
    exit 1
fi

# Auto-install APK if device is connected (always, regardless of build type)
echo ""
# Auto-install and reopen app if device is connected
# Try system-wide adb first (from Homebrew), then fallback to SDK adb
if command -v adb &> /dev/null; then
    ADB="adb"
elif [ -f "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
    ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
else
    ADB=""
fi

if [ -n "$ADB" ]; then
    # Get list of connected devices
    DEVICES=$("$ADB" devices 2>/dev/null | grep "device$" | awk '{print $1}')
    DEVICE_COUNT=$(echo "$DEVICES" | grep -c . || echo "0")
    
    if [ "$DEVICE_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}Found $DEVICE_COUNT connected device(s)${NC}"
        
        # Determine which APK(s) to install based on build type
        APKS_TO_INSTALL=()
        if [ "$BUILD_TYPE" = "debug" ] || [ "$BUILD_TYPE" = "both" ]; then
            DEBUG_APK_PATH="app/build/outputs/apk/debug/app-debug.apk"
            if [ -f "$DEBUG_APK_PATH" ]; then
                APKS_TO_INSTALL+=("debug:$DEBUG_APK_PATH")
            fi
        fi
        
        if [ "$BUILD_TYPE" = "release" ] || [ "$BUILD_TYPE" = "both" ]; then
            RELEASE_APK_PATH="app/build/outputs/apk/release/app-release.apk"
            if [ -f "$RELEASE_APK_PATH" ]; then
                APKS_TO_INSTALL+=("release:$RELEASE_APK_PATH")
            fi
        fi
        
        if [ ${#APKS_TO_INSTALL[@]} -eq 0 ]; then
            echo "No APKs found to install"
        else
            # Install and launch on each device
            for DEVICE_ID in $DEVICES; do
                DEVICE_NAME=$("$ADB" -s "$DEVICE_ID" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "unknown")
                
                # Install each APK that was built
                for APK_INFO in "${APKS_TO_INSTALL[@]}"; do
                    APK_TYPE=$(echo "$APK_INFO" | cut -d':' -f1)
                    APK_PATH=$(echo "$APK_INFO" | cut -d':' -f2-)
                    
                    echo ""
                    echo -e "${YELLOW}Installing $APK_TYPE APK on device: $DEVICE_ID ($DEVICE_NAME)...${NC}"
                    
                    if "$ADB" -s "$DEVICE_ID" install -r "$PROJECT_ROOT/android/$APK_PATH" 2>/dev/null; then
                        echo -e "${GREEN}✅ Installed $APK_TYPE APK successfully on $DEVICE_ID${NC}"
                        
                        # Wait a moment for installation to fully complete
                        sleep 1
                        
                        # Launch the app (both debug and release use the same package name)
                        PACKAGE_NAME="com.hypo.clipboard"
                        echo -e "${YELLOW}Opening Hypo app on $DEVICE_ID...${NC}"
                        
                        # Try multiple methods to launch the app
                        LAUNCH_SUCCESS=false
                        
                        # Method 1: Use explicit activity name with dot notation
                        if "$ADB" -s "$DEVICE_ID" shell am start -n "$PACKAGE_NAME/.MainActivity" >/dev/null 2>&1; then
                            LAUNCH_SUCCESS=true
                        # Method 2: Use launcher intent with explicit activity
                        elif "$ADB" -s "$DEVICE_ID" shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "$PACKAGE_NAME/.MainActivity" >/dev/null 2>&1; then
                            LAUNCH_SUCCESS=true
                        # Method 3: Use monkey (most reliable fallback)
                        elif "$ADB" -s "$DEVICE_ID" shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
                            LAUNCH_SUCCESS=true
                        # Method 4: Try with full activity path
                        elif "$ADB" -s "$DEVICE_ID" shell am start -n "$PACKAGE_NAME/com.hypo.clipboard.MainActivity" >/dev/null 2>&1; then
                            LAUNCH_SUCCESS=true
                        fi
                        
                        if [ "$LAUNCH_SUCCESS" = true ]; then
                            echo -e "${GREEN}✅ App opened on $DEVICE_ID${NC}"
                        else
                            echo -e "${YELLOW}⚠️  Could not auto-open app on $DEVICE_ID${NC}"
                            echo "   Try manually: $ADB -s $DEVICE_ID shell am start -n $PACKAGE_NAME/.MainActivity"
                            # Show error for debugging
                            echo -e "${YELLOW}   Debug: Testing launch command...${NC}"
                            "$ADB" -s "$DEVICE_ID" shell am start -n "$PACKAGE_NAME/.MainActivity" 2>&1 | head -5 | sed 's/^/   /' || true
                        fi
                        
                        # Only launch once per device (use the first installed APK)
                        break
                    else
                        echo -e "${RED}❌ Installation failed on $DEVICE_ID${NC}"
                        echo "   Try manually: $ADB -s $DEVICE_ID install -r android/$APK_PATH"
                    fi
                done
            done
        fi
    else
        echo "No devices connected. To install manually:"
        if [ "$BUILD_TYPE" = "debug" ] || [ "$BUILD_TYPE" = "both" ]; then
            echo "   $ADB install -r android/app/build/outputs/apk/debug/app-debug.apk"
        fi
        if [ "$BUILD_TYPE" = "release" ] || [ "$BUILD_TYPE" = "both" ]; then
            echo "   $ADB install -r android/app/build/outputs/apk/release/app-release.apk"
        fi
    fi
else
    echo "To install on connected device:"
    if [ "$BUILD_TYPE" = "debug" ] || [ "$BUILD_TYPE" = "both" ]; then
        echo "   adb install -r android/app/build/outputs/apk/debug/app-debug.apk"
    fi
    if [ "$BUILD_TYPE" = "release" ] || [ "$BUILD_TYPE" = "both" ]; then
        echo "   adb install -r android/app/build/outputs/apk/release/app-release.apk"
    fi
fi

echo ""
echo -e "${GREEN}✅ All builds completed!${NC}"
