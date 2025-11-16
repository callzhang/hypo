#!/usr/bin/env bash
# Setup Android Emulator for Hypo testing
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
SDK_ROOT=${ANDROID_SDK_ROOT:-${REPO_ROOT}/.android-sdk}
CMDLINE_DIR="${SDK_ROOT}/cmdline-tools/latest"
SDKMANAGER="${CMDLINE_DIR}/bin/sdkmanager"
AVD_NAME="hypo_test_device"

# Set up Java Home (required for avdmanager)
if [ -z "${JAVA_HOME:-}" ]; then
    if [ -d "/opt/homebrew/opt/openjdk@17" ]; then
        export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
        export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
    else
        echo "❌ JAVA_HOME not set and Homebrew OpenJDK 17 not found"
        echo "   Please set JAVA_HOME or install: brew install openjdk@17"
        exit 1
    fi
fi

echo "🔧 Setting up Android Emulator for Hypo..."
echo "=========================================="
echo "   Using Java: ${JAVA_HOME}"

# Ensure SDK is set up
if [[ ! -x "${SDKMANAGER}" ]]; then
    echo "❌ Android SDK not found. Run ./scripts/setup-android-sdk.sh first"
    exit 1
fi

# Accept licenses
echo "📝 Accepting licenses..."
yes | "${SDKMANAGER}" --sdk_root="${SDK_ROOT}" --licenses >/dev/null || true

# Install emulator and system image
echo "📦 Installing emulator packages..."
declare -a packages=(
    "emulator"
    "system-images;android-34;google_apis;x86_64"
    "platform-tools"
)

if ! yes | "${SDKMANAGER}" --sdk_root="${SDK_ROOT}" "${packages[@]}"; then
    exit_code=$?
    if [[ ${exit_code} -ne 0 && ${exit_code} -ne 141 ]]; then
        echo "❌ Failed to install emulator packages"
        exit "${exit_code}"
    fi
fi

# Create AVD if it doesn't exist
EMULATOR="${SDK_ROOT}/emulator/emulator"
AVDMANAGER="${SDK_ROOT}/cmdline-tools/latest/bin/avdmanager"

if [[ ! -d "${HOME}/.android/avd/${AVD_NAME}.avd" ]]; then
    echo "📱 Creating AVD: ${AVD_NAME}..."
    yes | "${AVDMANAGER}" create avd \
        --name "${AVD_NAME}" \
        --package "system-images;android-34;google_apis;x86_64" \
        --device "pixel_5" \
        --force || {
        echo "❌ Failed to create AVD"
        exit 1
    }
    echo "✅ AVD created successfully"
else
    echo "✅ AVD already exists: ${AVD_NAME}"
fi

echo ""
echo "✅ Emulator setup complete!"
echo ""
echo "To start the emulator:"
echo "  ./scripts/start-android-emulator.sh"
echo ""
echo "Or manually:"
echo "  ${EMULATOR} -avd ${AVD_NAME} &"

