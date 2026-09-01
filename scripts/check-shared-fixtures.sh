#!/usr/bin/env bash
#
# Checks that every client still reads the shared protocol fixtures.
#
# Each client's own CI job runs its vector tests, so a client that *disagrees*
# with the fixtures already fails. What nothing catches is a client that stops
# reading them — a deleted test, a renamed file, a suite that quietly drifted to
# its own constants. That build is green, and stays green while the three
# implementations walk apart.
#
# This is deliberately shallow: it asks whether each suite still names the
# fixtures, not whether it agrees with them. scripts/test-sync-matrix.sh runs
# the tests themselves, on a machine with all three toolchains.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0

require_file() {
    if [ ! -f "$1" ]; then
        echo "MISSING  $1"
        fail=1
    else
        echo "ok       $1"
    fi
}

require_reader() {
    local client="$1" path="$2" pattern="$3"

    if grep -rqE "$pattern" "$path" 2>/dev/null; then
        echo "ok       $client reads the shared fixtures"
    else
        echo "MISSING  $client no longer reads the shared fixtures ($path)"
        fail=1
    fi
}

echo "──── fixtures ────"
require_file tests/crypto_test_vectors.json
require_file tests/transport/frame_vectors.json

echo
echo "──── readers ────"
require_reader swift  shared/HypoCore/Tests  'crypto_test_vectors\.json|frame_vectors\.json'
require_reader kotlin android/app/src/test   'crypto_test_vectors\.json|frame_vectors\.json'
require_reader dotnet windows/tests          'crypto_test_vectors\.json|frame_vectors\.json'

echo
if [ "$fail" -ne 0 ]; then
    echo "The shared fixtures are what stop three independent clients drifting"
    echo "apart. A client that stops reading them cannot be caught by its own"
    echo "suite, which is why this exists. Restore the reader, or delete the"
    echo "fixture deliberately and say so here."
    exit 1
fi

echo "All three clients still read tests/crypto_test_vectors.json and"
echo "tests/transport/frame_vectors.json."
