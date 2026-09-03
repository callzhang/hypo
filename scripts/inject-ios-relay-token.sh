#!/usr/bin/env bash
#
# Injects RELAY_WS_AUTH_TOKEN from .env into the built iOS app's Info.plist,
# the same way scripts/build-macos.sh does for the Mac app. Without it the
# relay answers 401 and cloud sync never works.
#
# Run as an Xcode build phase, so every build gets it — including builds
# started from Xcode itself, which no wrapper script would see.
#
# Never writes an empty value. An empty token is worse than none: the app
# sends an X-Auth-Token header that cannot match, and the failure looks like a
# server problem rather than a missing secret. This is the shape of the bug
# that made Android builds from a worktree get 401 forever.

set -euo pipefail

PLIST="${BUILT_PRODUCTS_DIR:?}/${INFOPLIST_PATH:?}"

# .env lives in the repository's main working tree and is not checked in, so a
# git worktree does not have its own copy. --git-common-dir points at the main
# checkout's .git no matter which worktree we are building from.
COMMON_GIT_DIR="$(git -C "${SRCROOT:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
CANDIDATES=()
[ -n "${SRCROOT:-}" ] && CANDIDATES+=("$SRCROOT/../.env")
[ -n "$COMMON_GIT_DIR" ] && CANDIDATES+=("$(dirname "$COMMON_GIT_DIR")/.env")

ENV_FILE=""
for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then
        ENV_FILE="$candidate"
        break
    fi
done

# Fail rather than warn. A warning here produces an app that builds, installs
# and runs, and then cannot reach the relay at all — the only symptom is cloud
# sync quietly not working, which reads as a network or server problem. Finding
# it costs far more than a failed build does. Android's build made the same
# call, with the same escape hatch.
if [ -z "$ENV_FILE" ]; then
    if [ "${ALLOW_MISSING_RELAY_TOKEN:-}" = "1" ]; then
        echo "note: no .env found; building without a relay token because ALLOW_MISSING_RELAY_TOKEN=1"
        exit 0
    fi
    echo "error: no .env found (looked in: ${CANDIDATES[*]})." >&2
    echo "       The app would build with no relay auth token and the relay would refuse every" >&2
    echo "       connection with a 401, visible only as cloud sync not working." >&2
    echo "       Set ALLOW_MISSING_RELAY_TOKEN=1 to build without it anyway." >&2
    exit 1
fi

TOKEN="$(grep -E '^[[:space:]]*RELAY_WS_AUTH_TOKEN[[:space:]]*=' "$ENV_FILE" | head -1 | cut -d= -f2- | xargs || true)"

if [ -z "$TOKEN" ]; then
    if [ "${ALLOW_MISSING_RELAY_TOKEN:-}" = "1" ]; then
        echo "note: RELAY_WS_AUTH_TOKEN is empty in $ENV_FILE; building without it because ALLOW_MISSING_RELAY_TOKEN=1"
        exit 0
    fi
    echo "error: RELAY_WS_AUTH_TOKEN is absent or empty in $ENV_FILE." >&2
    echo "       The relay would refuse this build with a 401 on every connection." >&2
    echo "       Set ALLOW_MISSING_RELAY_TOKEN=1 to build without it anyway." >&2
    exit 1
fi

plutil -replace RelayWsAuthToken -string "$TOKEN" "$PLIST"
echo "Injected RelayWsAuthToken into $(basename "$PLIST")"
