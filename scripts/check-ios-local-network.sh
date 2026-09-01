#!/usr/bin/env bash
#
# Verifies the built iOS app declares what local network access needs.
#
# The permission prompt itself cannot be tested on a simulator — it does not
# enforce local network access, so the prompt never appears and item 4 of the
# phase-2 checklist can only be seen on hardware. What can be checked is the
# thing that actually breaks: without these two keys iOS refuses Bonjour with
# no error, no prompt and no log entry. Devices simply never appear, which
# reads as a networking fault rather than a missing declaration.
#
# Usage: scripts/check-ios-local-network.sh <path to Hypo.app>

set -euo pipefail

APP="${1:?usage: check-ios-local-network.sh <path to Hypo.app>}"
PLIST="$APP/Info.plist"

if [ ! -f "$PLIST" ]; then
    echo "❌ No Info.plist in $APP"
    exit 1
fi

description="$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$PLIST" 2>/dev/null || true)"
if [ -z "$description" ]; then
    echo "❌ NSLocalNetworkUsageDescription is missing; iOS will deny local network access silently"
    exit 1
fi

# xml1, not raw: raw prints nothing useful for an array.
if ! plutil -extract NSBonjourServices xml1 -o - "$PLIST" 2>/dev/null | grep -q "_hypo._tcp"; then
    echo "❌ NSBonjourServices does not list _hypo._tcp; Bonjour will find nothing and say nothing"
    plutil -extract NSBonjourServices xml1 -o - "$PLIST" 2>/dev/null || true
    exit 1
fi

echo "✅ Local network declarations present: NSLocalNetworkUsageDescription and _hypo._tcp"
