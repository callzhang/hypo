#!/bin/bash
# Benchmark script to compare local vs remote Fly.io deployments
# Measures build time, upload time, and total deployment time

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/backend"

# Configuration
APP_NAME="hypo"
FLY_CONFIG="$BACKEND_DIR/fly.toml"
FLYCTL_CMD="${FLYCTL_CMD:-flyctl}"

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
    
    if ! command -v $FLYCTL_CMD &> /dev/null; then
        log_error "flyctl not found. Please install Fly.io CLI"
        exit 1
    fi
    
    log_success "flyctl found: $($FLYCTL_CMD version | head -1)"
    
    if ! command -v docker &> /dev/null; then
        log_warning "Docker not found - local builds won't be possible"
        return 1
    fi
    
    if ! docker info &> /dev/null; then
        log_warning "Docker not running - local builds won't be possible"
        return 1
    fi
    
    log_success "Docker is available and running"
    return 0
}

# Get system info
get_system_info() {
    log_section "System Information"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "Unknown")
        MEMORY_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)}' || echo "Unknown")
        log_info "CPU: $CPU_MODEL ($CPU_CORES cores)"
        log_info "Memory: ${MEMORY_GB}GB"
    else
        log_info "System: $(uname -a)"
    fi
    
    # Check Docker image size
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        log_info "Docker: $(docker --version)"
    fi
    
    echo ""
}

# Benchmark local build
benchmark_local() {
    log_section "Benchmarking Local Build"
    
    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        log_warning "Skipping local build - Docker not available"
        return 1
    fi
    
    log_info "Starting local build benchmark..."
    echo ""
    
    cd "$BACKEND_DIR"
    
    # Measure Docker build time
    log_info "Building Docker image locally..."
    DOCKER_START=$(date +%s)
    
    if docker build -t hypo-benchmark:local -f Dockerfile . 2>&1 | tee /tmp/hypo_local_build.log; then
        DOCKER_END=$(date +%s)
        DOCKER_TIME=$((DOCKER_END - DOCKER_START))
        
        # Get image size
        IMAGE_SIZE=$(docker images hypo-benchmark:local --format "{{.Size}}" 2>/dev/null || echo "Unknown")
        log_success "Docker build completed in ${DOCKER_TIME}s"
        log_info "Image size: $IMAGE_SIZE"
        
        # Measure upload time (dry run - don't actually deploy)
        log_info "Measuring upload time (simulated)..."
        UPLOAD_START=$(date +%s)
        
        # Estimate upload time based on image size
        # Rough estimate: 10-50 MB/s depending on connection
        if [[ "$IMAGE_SIZE" =~ ([0-9.]+)(MB|GB) ]]; then
            SIZE_VALUE="${BASH_REMATCH[1]}"
            SIZE_UNIT="${BASH_REMATCH[2]}"
            
            if [ "$SIZE_UNIT" = "GB" ]; then
                SIZE_MB=$(echo "$SIZE_VALUE * 1024" | bc)
            else
                SIZE_MB="$SIZE_VALUE"
            fi
            
            # Estimate: 20 MB/s average upload speed
            ESTIMATED_UPLOAD=$(echo "scale=1; $SIZE_MB / 20" | bc)
            UPLOAD_TIME=$(echo "scale=0; $ESTIMATED_UPLOAD" | bc)
        else
            UPLOAD_TIME=30  # Default estimate
        fi
        
        UPLOAD_END=$(date +%s)
        
        TOTAL_TIME=$((DOCKER_TIME + UPLOAD_TIME))
        
        echo ""
        log_success "Local Build Results:"
        echo "  Docker build time: ${DOCKER_TIME}s"
        echo "  Estimated upload time: ${UPLOAD_TIME}s"
        echo "  Total estimated time: ${TOTAL_TIME}s"
        echo ""
        
        # Save results
        echo "local,$DOCKER_TIME,$UPLOAD_TIME,$TOTAL_TIME" > /tmp/hypo_benchmark_local.csv
        
        return 0
    else
        log_error "Local build failed"
        return 1
    fi
}

# Benchmark remote build (simulated - just measure time)
benchmark_remote() {
    log_section "Benchmarking Remote Build"
    
    log_info "Note: Remote build benchmark requires actual deployment"
    log_info "This will measure the total deployment time..."
    echo ""
    
    read -p "Do you want to proceed with actual remote deployment? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Skipping remote build benchmark"
        return 1
    fi
    
    cd "$BACKEND_DIR"
    
    log_info "Starting remote build (this may take several minutes)..."
    REMOTE_START=$(date +%s)
    
    if $FLYCTL_CMD deploy \
        --remote-only \
        --config "$FLY_CONFIG" \
        --app "$APP_NAME" \
        --no-cache \
        2>&1 | tee /tmp/hypo_remote_build.log; then
        REMOTE_END=$(date +%s)
        REMOTE_TIME=$((REMOTE_END - REMOTE_START))
        
        echo ""
        log_success "Remote Build Results:"
        echo "  Total deployment time: ${REMOTE_TIME}s"
        echo ""
        
        # Save results
        echo "remote,0,0,$REMOTE_TIME" > /tmp/hypo_benchmark_remote.csv
        
        return 0
    else
        log_error "Remote build failed"
        return 1
    fi
}

# Compare results
compare_results() {
    log_section "Benchmark Comparison"
    
    if [ ! -f /tmp/hypo_benchmark_local.csv ] && [ ! -f /tmp/hypo_benchmark_remote.csv ]; then
        log_warning "No benchmark results to compare"
        return 1
    fi
    
    echo "Build Strategy Comparison:"
    echo ""
    printf "%-15s %-20s %-20s %-20s\n" "Strategy" "Build Time" "Upload Time" "Total Time"
    echo "─────────────────────────────────────────────────────────────────────────"
    
    if [ -f /tmp/hypo_benchmark_local.csv ]; then
        IFS=',' read -r strategy build upload total < /tmp/hypo_benchmark_local.csv
        printf "%-15s %-20s %-20s %-20s\n" "Local" "${build}s" "${upload}s (est)" "${total}s (est)"
    fi
    
    if [ -f /tmp/hypo_benchmark_remote.csv ]; then
        IFS=',' read -r strategy build upload total < /tmp/hypo_benchmark_remote.csv
        printf "%-15s %-20s %-20s %-20s\n" "Remote" "N/A" "N/A" "${total}s"
    fi
    
    echo ""
    
    if [ -f /tmp/hypo_benchmark_local.csv ] && [ -f /tmp/hypo_benchmark_remote.csv ]; then
        IFS=',' read -r _ _ _ local_total < /tmp/hypo_benchmark_local.csv
        IFS=',' read -r _ _ _ remote_total < /tmp/hypo_benchmark_remote.csv
        
        if [ "$local_total" -lt "$remote_total" ]; then
            SPEEDUP=$(echo "scale=2; $remote_total / $local_total" | bc)
            log_success "Local build is ${SPEEDUP}x faster!"
        else
            SLOWDOWN=$(echo "scale=2; $local_total / $remote_total" | bc)
            log_warning "Remote build is ${SLOWDOWN}x faster (unusual)"
        fi
    fi
    
    echo ""
}

# Quick benchmark (local build only, no deployment)
benchmark_quick() {
    log_section "Quick Build Benchmark"
    
    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        log_error "Docker not available for quick benchmark"
        return 1
    fi
    
    # System info
    if [[ "$OSTYPE" == "darwin"* ]]; then
        CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "Unknown")
        log_info "CPU Cores: $CPU_CORES"
    fi
    
    log_info "Docker: $(docker --version)"
    echo ""
    
    # Clean build (no cache)
    log_info "Building Docker image (no cache)..."
    log_info "This measures a clean build time..."
    echo ""
    
    cd "$BACKEND_DIR"
    
    START=$(date +%s)
    if docker build --no-cache -t hypo-benchmark:quick -f Dockerfile . 2>&1 | tee /tmp/hypo_quick_build.log; then
        END=$(date +%s)
        BUILD_TIME=$((END - START))
        
        # Get image size
        IMAGE_SIZE=$(docker images hypo-benchmark:quick --format "{{.Size}}" 2>/dev/null || echo "Unknown")
        
        echo ""
        log_success "Build Complete!"
        echo "  Build Time: ${BUILD_TIME} seconds ($(echo "scale=1; $BUILD_TIME / 60" | bc) minutes)"
        echo "  Image Size: $IMAGE_SIZE"
        echo ""
        
        # Estimate upload time (rough: 20 MB/s)
        if [[ "$IMAGE_SIZE" =~ ([0-9.]+)(MB|GB) ]]; then
            SIZE_VALUE="${BASH_REMATCH[1]}"
            SIZE_UNIT="${BASH_REMATCH[2]}"
            
            if [ "$SIZE_UNIT" = "GB" ]; then
                SIZE_MB=$(echo "$SIZE_VALUE * 1024" | bc)
            else
                SIZE_MB="$SIZE_VALUE"
            fi
            
            UPLOAD_TIME=$(echo "scale=0; $SIZE_MB / 20" | bc)
            TOTAL_TIME=$((BUILD_TIME + UPLOAD_TIME))
            
            echo "  Estimated Upload Time: ${UPLOAD_TIME}s (at 20 MB/s)"
            echo "  Total Estimated Time: ${TOTAL_TIME}s ($(echo "scale=1; $TOTAL_TIME / 60" | bc) minutes)"
            echo ""
            log_info "💡 Remote builds typically take 3-5 minutes"
            if [ "$TOTAL_TIME" -lt 180 ]; then
                log_success "Local build would be faster!"
            elif [ "$TOTAL_TIME" -lt 300 ]; then
                log_warning "Local build is comparable to remote"
            else
                log_warning "Remote build might be faster"
            fi
        fi
        
        return 0
    else
        log_error "Quick build failed"
        return 1
    fi
}

# Main
main() {
    # Check for --quick flag
    if [ "${1:-}" = "--quick" ]; then
        benchmark_quick
        return $?
    fi
    
    echo ""
    log_section "🚀 Fly.io Deployment Benchmark"
    echo ""
    
    check_prerequisites
    DOCKER_AVAILABLE=$?
    
    get_system_info
    
    # Run benchmarks
    LOCAL_SUCCESS=0
    REMOTE_SUCCESS=0
    
    if [ $DOCKER_AVAILABLE -eq 0 ]; then
        if benchmark_local; then
            LOCAL_SUCCESS=1
        fi
    fi
    
    # Ask about remote benchmark
    echo ""
    read -p "Benchmark remote build? (requires actual deployment) (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if benchmark_remote; then
            REMOTE_SUCCESS=1
        fi
    fi
    
    # Compare results
    if [ $LOCAL_SUCCESS -eq 1 ] || [ $REMOTE_SUCCESS -eq 1 ]; then
        compare_results
    fi
    
    echo ""
    log_info "Benchmark complete!"
    log_info "Results saved to: /tmp/hypo_benchmark_*.csv"
    echo ""
}

main "$@"

