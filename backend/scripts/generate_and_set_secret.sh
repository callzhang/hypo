#!/usr/bin/env bash
set -euo pipefail

# Define colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No content

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS_FILE="$PROJECT_ROOT/.secrets"

echo -e "${YELLOW}🔑 Generating new RELAY_WS_AUTH_TOKEN...${NC}"

# Generate a 32-byte hex secret (64 characters)
SECRET=$(openssl rand -hex 32)
echo -e "Generated secret: ${GREEN}${SECRET}${NC}"

# 1. Save to .secrets
echo -e "\n${YELLOW}💾 Saving to ${SECRETS_FILE}...${NC}"
if [ -f "$SECRETS_FILE" ]; then
    # Remove existing RELAY_WS_AUTH_TOKEN if present
    # Use distinct temporary file for sed to avoid race conditions/empty file issues on macOS
    sed -i '' '/^RELAY_WS_AUTH_TOKEN=/d' "$SECRETS_FILE" || true
    echo "RELAY_WS_AUTH_TOKEN=$SECRET" >> "$SECRETS_FILE"
else
    echo "RELAY_WS_AUTH_TOKEN=$SECRET" > "$SECRETS_FILE"
fi
chmod 600 "$SECRETS_FILE"
echo -e "${GREEN}✅ Saved to .secrets${NC}"

# 2. Set on Fly.io
echo -e "\n${YELLOW}☁️  Setting secret on Fly.io (app: hypo)...${NC}"
# Check if flyctl is available and authorized
if ! command -v flyctl &> /dev/null; then
    echo -e "${RED}❌ flyctl not found. Please install flyctl to set server secrets.${NC}"
    exit 1
fi

if flyctl secrets set "RELAY_WS_AUTH_TOKEN=$SECRET" --app hypo --config "$PROJECT_ROOT/backend/fly.toml"; then
    echo -e "${GREEN}✅ Secret set on Fly.io server${NC}"
    echo -e "${YELLOW}⚠️  The server will restart automatically to apply changes.${NC}"
else
    echo -e "${RED}❌ Failed to set secret on Fly.io${NC}"
    exit 1
fi

echo -e "\n${GREEN}🎉 Done! Use this secret in your local .env file as well if needed.${NC}"
