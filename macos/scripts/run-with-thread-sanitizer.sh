#!/bin/bash
# Run macOS app with Thread Sanitizer enabled
# This detects data races and threading issues

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT/macos"

echo "🔍 Building with Thread Sanitizer..."

# Build with Thread Sanitizer
swift build -c debug \
    -Xswiftc -sanitize=thread \
    -Xswiftc -Xfrontend \
    -Xswiftc -validate-tbd-against-ir=none

echo "✅ Build complete"
echo "🚀 Running with Thread Sanitizer..."
echo "   (Watch for data race warnings in output)"

# Run the app
.build/debug/HypoMenuBar

