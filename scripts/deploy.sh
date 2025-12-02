#!/bin/bash
# Backend Deployment Script for Hypo Relay Server
# Deploys to Fly.io production environment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get project root (script is in scripts/ directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/backend"

# Configuration
APP_NAME="hypo"
FLY_CONFIG="$BACKEND_DIR/fly.toml"
FLYCTL_PATH="${FLYCTL_PATH:-/Users/derek/.fly/bin/flyctl}"
DEPLOY_ENV="${DEPLOY_ENV:-production}"

# Logging functions
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
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_section "Checking Prerequisites"
    
    # Check flyctl
    if [ ! -f "$FLYCTL_PATH" ] && ! command -v flyctl &> /dev/null; then
        log_error "flyctl not found. Please install Fly.io CLI:"
        echo "  curl -L https://fly.io/install.sh | sh"
        exit 1
    fi
    
    # Use flyctl from PATH if available, otherwise use explicit path
    if command -v flyctl &> /dev/null; then
        FLYCTL_CMD="flyctl"
    else
        FLYCTL_CMD="$FLYCTL_PATH"
    fi
    
    log_success "flyctl found: $($FLYCTL_CMD version | head -1)"
    
    # Check fly.toml exists
    if [ ! -f "$FLY_CONFIG" ]; then
        log_error "fly.toml not found at $FLY_CONFIG"
        exit 1
    fi
    
    log_success "Configuration file found: $FLY_CONFIG"
    
    # Check if authenticated
    if ! $FLYCTL_CMD auth whoami &> /dev/null; then
        log_warning "Not authenticated with Fly.io"
        log_info "Running: $FLYCTL_CMD auth login"
        $FLYCTL_CMD auth login
    else
        log_success "Authenticated with Fly.io: $($FLYCTL_CMD auth whoami)"
    fi
}

# Run tests (optional, if cargo is available)
run_tests() {
    log_section "Running Tests"
    
    if command -v cargo &> /dev/null; then
        log_info "Running backend tests..."
        cd "$BACKEND_DIR"
        if cargo test --all-features --locked 2>&1 | tee /tmp/hypo_backend_tests.log; then
            log_success "All tests passed"
            return 0
        else
            log_error "Tests failed. Check /tmp/hypo_backend_tests.log"
            read -p "Continue with deployment anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
            log_warning "Proceeding with deployment despite test failures"
        fi
    else
        log_warning "cargo not available, skipping tests"
        log_info "Tests will run during Docker build"
    fi
}

# Deploy to Fly.io
deploy() {
    log_section "Deploying to Fly.io"
    
    log_info "App: $APP_NAME"
    log_info "Environment: $DEPLOY_ENV"
    log_info "Config: $FLY_CONFIG"
    echo ""
    
    # Deploy with remote-only (builds on Fly.io)
    log_info "Starting deployment (remote build)..."
    echo ""
    
    cd "$BACKEND_DIR"
    if $FLYCTL_CMD deploy \
        --remote-only \
        --config "$FLY_CONFIG" \
        --app "$APP_NAME" \
        2>&1 | tee /tmp/hypo_backend_deploy.log; then
        log_success "Deployment completed successfully"
        return 0
    else
        log_error "Deployment failed. Check /tmp/hypo_backend_deploy.log"
        exit 1
    fi
}

# Verify deployment
verify_deployment() {
    log_section "Verifying Deployment"
    
    local max_attempts=10
    local attempt=1
    local health_url="https://hypo.fly.dev/health"
    
    log_info "Waiting for health check..."
    
    while [ $attempt -le $max_attempts ]; do
        if curl -sf "$health_url" > /dev/null 2>&1; then
            log_success "Health check passed"
            
            # Get health status
            local health_response=$(curl -sf "$health_url" 2>/dev/null || echo "{}")
            log_info "Health status: $health_response"
            
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts: Waiting for server to be ready..."
        sleep 3
        attempt=$((attempt + 1))
    done
    
    log_error "Health check failed after $max_attempts attempts"
    log_warning "Server may still be starting. Check logs with:"
    echo "  $FLYCTL_CMD logs --app $APP_NAME"
    return 1
}

# Show deployment info
show_deployment_info() {
    log_section "Deployment Information"
    
    log_info "App URL: https://hypo.fly.dev"
    log_info "WebSocket: wss://hypo.fly.dev/ws"
    log_info "Health: https://hypo.fly.dev/health"
    log_info "Metrics: https://hypo.fly.dev/metrics"
    echo ""
    
    log_info "Useful commands:"
    echo "  View logs:     $FLYCTL_CMD logs --app $APP_NAME"
    echo "  Check status:  $FLYCTL_CMD status --app $APP_NAME"
    echo "  SSH to app:    $FLYCTL_CMD ssh console --app $APP_NAME"
    echo "  View metrics:  $FLYCTL_CMD metrics --app $APP_NAME"
    echo ""
}

# Main deployment flow
main() {
    echo ""
    log_section "🚀 Hypo Backend Deployment"
    echo ""
    log_info "Deploying to: $DEPLOY_ENV"
    log_info "App: $APP_NAME"
    echo ""
    
    # Confirm deployment (skip by default)
    SKIP_CONFIRM="${SKIP_CONFIRM:-1}"
    if [ "$SKIP_CONFIRM" != "1" ]; then
        read -p "Continue with deployment? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deployment cancelled"
            exit 0
        fi
    fi
    
    # Run deployment steps
    check_prerequisites
    run_tests
    deploy
    verify_deployment
    show_deployment_info
    
    echo ""
    log_success "🎉 Deployment complete!"
    echo ""
}

# Handle script arguments
case "${1:-deploy}" in
    deploy)
        main
        ;;
    test)
        check_prerequisites
        run_tests
        ;;
    verify)
        check_prerequisites
        verify_deployment
        ;;
    info)
        show_deployment_info
        ;;
    *)
        echo "Usage: $0 [deploy|test|verify|info]"
        echo ""
        echo "Commands:"
        echo "  deploy  - Full deployment (default)"
        echo "  test    - Run tests only"
        echo "  verify  - Verify existing deployment"
        echo "  info    - Show deployment information"
        echo ""
        echo "Environment variables:"
        echo "  FLYCTL_PATH  - Path to flyctl binary (default: /Users/derek/.fly/bin/flyctl)"
        echo "  DEPLOY_ENV   - Deployment environment (default: production)"
        echo "  SKIP_CONFIRM - Skip confirmation prompt (set to 1)"
        exit 1
        ;;
esac



