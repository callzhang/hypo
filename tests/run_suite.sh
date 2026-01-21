#!/bin/bash
# Hypo Test Suite Runner
# Unified entry point for all Hypo tests

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Usage
print_usage() {
    cat << EOF
Usage: $0 [MODE] [OPTIONS]

Modes:
    --all       Run ALL tests (Server, Client, Matrix) - Takes ~30 mins
    --server    Run Backend Server tests (Health, API, WS)
    --client    Run Client Sync tests (Basic smoke test)
    --matrix    Run Matrix Regression tests (Deep coverage: Text/Image/File x Enc/Plain x LAN/Cloud)

Options:
    -h, --help  Show this help message

Environment Variables:
    See tests/README.md for .env configuration (Device IDs, Keys)

EOF
}

# Sub-test runners directly invoking existing scripts
run_server() {
    echo -e "${BLUE}🚀 Running Server Tests...${NC}"
    "$SCRIPT_DIR/test-server-all.sh"
}

run_client() {
    echo -e "${BLUE}🚀 Running Client Sync Tests...${NC}"
    "$SCRIPT_DIR/test-sync.sh"
}

run_matrix() {
    echo -e "${BLUE}🚀 Running Sync Matrix Tests...${NC}"
    "$SCRIPT_DIR/test-sync-matrix.sh"
}

# Main
main() {
    if [ $# -eq 0 ]; then
        print_usage
        exit 1
    fi

    local mode="$1"
    
    case "$mode" in
        --all)
            echo -e "${BLUE}🧪 Starting Full Test Suite...${NC}"
            run_server
            run_client
            run_matrix
            echo -e "${GREEN}✅ Full Suite Completed${NC}"
            ;;
        --server)
            run_server
            ;;
        --client)
            run_client
            ;;
        --matrix)
            run_matrix
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown mode: $mode${NC}"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
