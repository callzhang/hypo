#!/bin/bash
# Build all platforms (Android, macOS) and optionally deploy backend

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get project root
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Check if deploy argument is provided
DEPLOY_BACKEND=false
BUILD_ARGS=()
for arg in "$@"; do
    if [ "$arg" = "deploy" ] || [ "$arg" = "--deploy" ]; then
        DEPLOY_BACKEND=true
    else
        BUILD_ARGS+=("$arg")
    fi
done

echo -e "${GREEN}🔨 Building All Platforms${NC}"
echo "=========================="
echo ""

# Build Android
echo -e "${YELLOW}📱 Building Android...${NC}"
if "$PROJECT_ROOT/scripts/build-android.sh" "${BUILD_ARGS[@]}"; then
    echo -e "${GREEN}✅ Android build successful${NC}"
else
    echo -e "${RED}❌ Android build failed${NC}"
    exit 1
fi

echo ""

# Build macOS
echo -e "${YELLOW}🍎 Building macOS...${NC}"
if "$PROJECT_ROOT/scripts/build-macos.sh" "${BUILD_ARGS[@]}"; then
    echo -e "${GREEN}✅ macOS build successful${NC}"
else
    echo -e "${RED}❌ macOS build failed${NC}"
    exit 1
fi

echo ""

# Deploy backend if requested
if [ "$DEPLOY_BACKEND" = true ]; then
    echo -e "${YELLOW}🚀 Deploying backend...${NC}"
    if "$PROJECT_ROOT/scripts/deploy.sh" deploy; then
        echo -e "${GREEN}✅ Backend deployment successful${NC}"
    else
        echo -e "${RED}❌ Backend deployment failed${NC}"
        exit 1
    fi
    echo ""
fi

echo -e "${GREEN}✅ All builds successful!${NC}"

