#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${JAVA_HOME:-}" ]]; then
  echo "JAVA_HOME must be set before running the transport regression suite" >&2
  exit 1
fi

if [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
  echo "ANDROID_SDK_ROOT must be set before running the transport regression suite" >&2
  exit 1
fi

pushd "$ROOT_DIR" > /dev/null

ANDROID_CMD=("$ROOT_DIR/android/gradlew" -p "$ROOT_DIR/android" testDebugUnitTest --tests "com.hypo.clipboard.transport.TransportMetricsAggregatorTest" --console=plain)
"${ANDROID_CMD[@]}"

pushd "$ROOT_DIR/macos" > /dev/null
swift test --filter TransportMetricsAggregatorTests
popd > /dev/null

popd > /dev/null
