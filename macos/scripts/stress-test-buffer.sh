#!/bin/bash
# Stress test for buffer thread-safety
# Simulates high-throughput concurrent frame processing

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "🧪 Running buffer thread-safety stress test..."

# Build test target
cd macos
swift test --filter LanWebSocketServerBufferTests

echo "✅ Stress test complete"
echo ""
echo "📊 Results:"
echo "   - If tests pass: Buffer operations are thread-safe ✅"
echo "   - If tests fail: Check for race conditions in buffer access ⚠️"
echo ""
echo "💡 Tip: Run with Thread Sanitizer for deeper analysis:"
echo "   ./macos/scripts/run-with-thread-sanitizer.sh"

