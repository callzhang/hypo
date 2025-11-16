#!/bin/bash
# Check if Terminal has Accessibility access

echo "🔍 Checking Accessibility Access..."
echo ""

# Test if we can access window properties
TEST_RESULT=$(osascript << 'EOF' 2>&1
tell application "System Events"
    try
        set proc to first process whose name contains "小米"
        set winCount to count of windows of proc
        return "SUCCESS: " & winCount & " windows accessible"
    on error errMsg
        return "ERROR: " & errMsg
    end try
end tell
EOF
)

if echo "$TEST_RESULT" | grep -q "SUCCESS"; then
    echo "✅ Accessibility access is GRANTED"
    echo "   The screenshot script should work automatically!"
    exit 0
else
    echo "❌ Accessibility access is NOT GRANTED"
    echo ""
    echo "📋 To fix this:"
    echo "   1. Open System Settings"
    echo "   2. Go to: Privacy & Security > Accessibility"
    echo "   3. Find your terminal app (Terminal, iTerm, Cursor, etc.)"
    echo "   4. Toggle it ON"
    echo "   5. Run this check again: ./scripts/check-accessibility.sh"
    echo ""
    echo "🔧 Or run this command to open the settings:"
    echo "   open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
    echo ""
    echo "Error details: $TEST_RESULT"
    exit 1
fi

