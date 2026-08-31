#!/usr/bin/env bash
#
# Runs the tests that read the shared protocol fixtures, in every client, and
# reports which of them agree.
#
# The fixtures under tests/ are the mechanism that stops three independent
# implementations drifting apart: each one encodes a frame, derives a key and
# decompresses a payload from the same bytes. A client that quietly stops
# reading them looks exactly like a client that agrees, which is why this checks
# that every implementation ran the vector tests rather than only that its own
# suite is green.
#
# What this cannot do is put a real clipboard on one device and watch it appear
# on another. That needs two machines and a person; this covers the layer where
# a disagreement would be silent.
#
# Usage:
#   scripts/test-sync-matrix.sh            # all three
#   scripts/test-sync-matrix.sh dotnet     # one of: swift, kotlin, dotnet

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANTED="${1:-all}"

# CommandLineTools has no Testing.framework and no simulators; Xcode's toolchain
# does. See windows/README.md for the whole story.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

declare -a NAMES=() RESULTS=()

record() {
    NAMES+=("$1")
    RESULTS+=("$2")
}

run() {
    local name="$1" dir="$2"
    shift 2

    if [ "$WANTED" != "all" ] && [ "$WANTED" != "$name" ]; then
        record "$name" "skipped"
        return
    fi

    echo "──── $name ────"

    if (cd "$ROOT/$dir" && "$@"); then
        record "$name" "ok"
    else
        record "$name" "FAILED"
    fi
}

# Swift: shared/HypoCore rather than macos/. The vector tests live in the shared
# core, and it is a plain library, so `swift test` works on it -- which it does
# not for the macOS application tests (they need an app bundle).
run swift shared/HypoCore \
    swift test --filter 'CryptoServiceTests|TransportFrameCodecTests'

run kotlin android \
    ./gradlew --quiet testDebugUnitTest \
    --tests '*CryptoServiceTest' \
    --tests '*TransportFrameCodecTest'

run dotnet windows \
    dotnet test tests/Hypo.Core.Tests \
    --filter 'FullyQualifiedName~CryptoService|FullyQualifiedName~TransportFrameCodec|FullyQualifiedName~GzipVector|FullyQualifiedName~RepoFixtures'

echo
echo "──── shared fixtures ────"

failed=0
for i in "${!NAMES[@]}"; do
    printf '%-8s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}"
    [ "${RESULTS[$i]}" = "FAILED" ] && failed=1
done

if [ "$failed" -ne 0 ]; then
    echo
    echo "A client disagrees with tests/crypto_test_vectors.json or"
    echo "tests/transport/frame_vectors.json. Two clients that disagree on these"
    echo "bytes cannot sync, and neither one's own suite will tell you."
    exit 1
fi

echo
echo "All clients agree on the shared fixtures."
