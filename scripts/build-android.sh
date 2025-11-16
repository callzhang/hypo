#!/bin/bash
# Hypo Android Build Script
# Builds the Android APK with proper environment configuration

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

# Java Home (try Homebrew location first)
if [ -z "$JAVA_HOME" ]; then
    if [ -d "/opt/homebrew/opt/openjdk@17" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
        export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
        echo "   Using Homebrew OpenJDK 17"
    else
        echo -e "${RED}❌ JAVA_HOME not set and Homebrew OpenJDK 17 not found${NC}"
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
    export GRADLE_USER_HOME="$PROJECT_ROOT/.gradle"
fi

echo "   JAVA_HOME: $JAVA_HOME"
echo "   ANDROID_SDK_ROOT: $ANDROID_SDK_ROOT"
echo "   GRADLE_USER_HOME: $GRADLE_USER_HOME"
echo ""

# Build
echo -e "${YELLOW}Building Android APK...${NC}"
cd "$PROJECT_ROOT/android"

# Clean build if requested
if [ "$1" == "clean" ]; then
    echo "   Running clean build..."
    ./gradlew clean
fi

./gradlew assembleDebug --stacktrace

# Check output
APK_PATH="app/build/outputs/apk/debug/app-debug.apk"
if [ -f "$APK_PATH" ]; then
    APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
    APK_SHA=$(shasum -a 256 "$APK_PATH" | cut -d' ' -f1)
    
    echo ""
    echo -e "${GREEN}✅ Build successful!${NC}"
    echo "   APK: android/$APK_PATH"
    echo "   Size: $APK_SIZE"
    echo "   SHA-256: $APK_SHA"
    echo ""
    
    # Auto-install and reopen app if device is connected
    ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
    if [ -f "$ADB" ]; then
        DEVICE_CHECK=$("$ADB" devices 2>/dev/null | grep -q "device$" && echo "yes" || echo "no")
        if [ "$DEVICE_CHECK" = "yes" ]; then
            echo -e "${YELLOW}Installing on connected device...${NC}"
            if "$ADB" install -r "$PROJECT_ROOT/android/$APK_PATH" 2>/dev/null; then
                echo -e "${GREEN}✅ Installed successfully${NC}"
                
                # Reopen the app using the dedicated script
                if [ -f "$PROJECT_ROOT/scripts/reopen-android-app.sh" ]; then
                    echo -e "${YELLOW}Opening Hypo app...${NC}"
                    "$PROJECT_ROOT/scripts/reopen-android-app.sh" 2>/dev/null || echo -e "${YELLOW}⚠️  Could not auto-open app. Please open manually.${NC}"
                else
                    # Fallback: try direct adb commands
                    echo -e "${YELLOW}Opening Hypo app...${NC}"
                    "$ADB" shell am start -n com.hypo.clipboard/.MainActivity 2>/dev/null || \
                    "$ADB" shell monkey -p com.hypo.clipboard -c android.intent.category.LAUNCHER 1 2>/dev/null || \
                    echo -e "${YELLOW}⚠️  Could not auto-open app. Please open manually.${NC}"
                fi
            else
                echo -e "${RED}❌ Installation failed${NC}"
                echo "   Try manually: $ADB install -r android/$APK_PATH"
            fi
        else
            echo "To install on connected device:"
            echo "   $ADB install -r android/$APK_PATH"
        fi
    else
        echo "To install on connected device:"
        echo "   \$ANDROID_SDK_ROOT/platform-tools/adb install -r android/$APK_PATH"
    fi
else
    echo -e "${RED}❌ Build failed - APK not found${NC}"
    exit 1
fi

