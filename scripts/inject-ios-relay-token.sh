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

if [ -z "$ENV_FILE" ]; then
    echo "warning: no .env found; the app will have no relay auth token and the relay will refuse it"
    exit 0
fi

TOKEN="$(grep -E '^[[:space:]]*RELAY_WS_AUTH_TOKEN[[:space:]]*=' "$ENV_FILE" | head -1 | cut -d= -f2- | xargs || true)"

if [ -z "$TOKEN" ]; then
    echo "warning: RELAY_WS_AUTH_TOKEN is absent or empty in $ENV_FILE; leaving the key out rather than baking in an empty one"
    exit 0
fi

plutil -replace RelayWsAuthToken -string "$TOKEN" "$PLIST"
echo "Injected RelayWsAuthToken into $(basename "$PLIST")"
