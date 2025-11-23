#!/bin/bash
# Test script for minimal hotkey app

set -e

echo "🔧 Building hotkey test app..."
cd macos/TestHotkey
swift build

echo ""
echo "✅ Build complete!"
echo ""
echo "🚀 Running test app..."
echo "   - Look for 🔑 icon in menu bar"
echo "   - Press Shift+Cmd+V"
echo "   - You should see an alert if it works"
echo ""
echo "📊 To watch logs in real-time, run in another terminal:"
echo "   log stream --predicate 'process == \"TestHotkey\"' --level debug"
echo ""

# Run the test app
./.build/debug/TestHotkey
