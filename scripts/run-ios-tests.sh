#!/usr/bin/env bash
#
# Run a Swift package's tests on the iOS Simulator and actually fail when they
# fail.
#
# xcodebuild prints "** TEST SUCCEEDED **" and exits 0 even when Swift Testing
# tests fail. It tallies XCTest results, and these packages have no XCTest
# cases, so it sees zero failures. Verified on Xcode 26.5: a deliberately
# failing expectation printed
#
#     ✘ Test run with 15 tests failed after 1.272 seconds with 1 issue.
#     ** TEST SUCCEEDED **
#
# followed by exit code 0. Every iOS test step must therefore check the Swift
# Testing summary itself rather than trusting xcodebuild's exit status.
#
# Usage: scripts/run-ios-tests.sh <package-dir> <scheme> [simulator-name]

set -euo pipefail

PACKAGE_DIR="${1:?usage: run-ios-tests.sh <package-dir> <scheme> [simulator-name]}"
SCHEME="${2:?usage: run-ios-tests.sh <package-dir> <scheme> [simulator-name]}"
SIMULATOR="${3:-iPhone 16}"

LOG="$(mktemp -t hypo-ios-tests-XXXXXX)"
trap 'rm -f "$LOG"' EXIT

cd "$PACKAGE_DIR"

set +e
xcodebuild test \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -skipMacroValidation \
    -enableCodeCoverage NO \
    -parallel-testing-enabled NO \
    2>&1 | tee "$LOG"
xcodebuild_status=${PIPESTATUS[0]}
set -e

# A non-zero status still means something real went wrong (build failure,
# simulator unavailable), so keep honouring it.
if [ "$xcodebuild_status" -ne 0 ]; then
    echo "❌ xcodebuild exited $xcodebuild_status for scheme $SCHEME"
    exit "$xcodebuild_status"
fi

if grep -qE '^✘ Test run with' "$LOG"; then
    echo "❌ Swift Testing reported failures for scheme $SCHEME, despite xcodebuild exiting 0:"
    grep -E '^✘' "$LOG" | head -50
    exit 1
fi

# No summary at all means the suite never ran — green for the wrong reason.
if ! grep -qE '^✔ Test run with' "$LOG"; then
    echo "❌ No Swift Testing summary found for scheme $SCHEME; the suite did not run."
    exit 1
fi

grep -E '^✔ Test run with' "$LOG"
