#!/bin/bash
# Build both Android and macOS apps

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get project root
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo -e "${GREEN}🔨 Building All Platforms${NC}"
echo "=========================="
echo ""

# Build Android
echo -e "${YELLOW}📱 Building Android...${NC}"
if "$PROJECT_ROOT/scripts/build-android.sh" "$@"; then
    echo -e "${GREEN}✅ Android build successful${NC}"
else
    echo -e "${RED}❌ Android build failed${NC}"
    exit 1
fi

echo ""

# Build macOS
echo -e "${YELLOW}🍎 Building macOS...${NC}"
if "$PROJECT_ROOT/scripts/build-macos.sh" "$@"; then
    echo -e "${GREEN}✅ macOS build successful${NC}"
else
    echo -e "${RED}❌ macOS build failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ All builds successful!${NC}"

