#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="9477386"
ANDROID_PLATFORM="platforms;android-34"
ANDROID_BUILD_TOOLS="build-tools;34.0.0"
ANDROID_PLATFORM_TOOLS="platform-tools"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SDK_ROOT=${ANDROID_SDK_ROOT:-${REPO_ROOT}/.android-sdk}
CMDLINE_DIR="${SDK_ROOT}/cmdline-tools/latest"

mkdir -p "${SDK_ROOT}"

if [[ ! -x "${CMDLINE_DIR}/bin/sdkmanager" ]]; then
  echo "Downloading Android command-line tools..."
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "${TMP_DIR}"' EXIT
  ZIP_PATH="${TMP_DIR}/commandlinetools-linux-${SDK_VERSION}_latest.zip"
  curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${SDK_VERSION}_latest.zip" -o "${ZIP_PATH}"
  unzip -q "${ZIP_PATH}" -d "${TMP_DIR}"
  mkdir -p "${SDK_ROOT}/cmdline-tools"
  rm -rf "${CMDLINE_DIR}"
  mv "${TMP_DIR}/cmdline-tools" "${CMDLINE_DIR}"
  rm -rf "${TMP_DIR}"
  trap - EXIT
fi

SDKMANAGER="${CMDLINE_DIR}/bin/sdkmanager"

# Accept licenses automatically
yes | "${SDKMANAGER}" --sdk_root="${SDK_ROOT}" --licenses >/dev/null || true

declare -a packages=(
  "${ANDROID_PLATFORM}"
  "${ANDROID_BUILD_TOOLS}"
  "${ANDROID_PLATFORM_TOOLS}"
)

if ! yes | "${SDKMANAGER}" --sdk_root="${SDK_ROOT}" "${packages[@]}"; then
  exit_code=$?
  if [[ ${exit_code} -ne 0 && ${exit_code} -ne 141 ]]; then
    exit "${exit_code}"
  fi
fi

echo "Android SDK installed at ${SDK_ROOT}"

echo "To use it, export ANDROID_SDK_ROOT=${SDK_ROOT} and rerun ./gradlew tasks as needed."
