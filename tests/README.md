# Hypo Test Suite

This directory contains integration and end-to-end tests for the Hypo clipboard sync system.

## Overview

The test suite covers:
- **Clipboard Sync**: Bidirectional sync between macOS and Android
- **Transport Layer**: LAN and Cloud relay functionality
- **Encryption**: End-to-end encryption with real device keys
- **Backend API**: Server endpoints and WebSocket handling
- **Platform Features**: Polling, persistence, and platform-specific behaviors

## Test Scripts

### Main Test Suites

#### `test-sync.sh` - Comprehensive Sync Test (Recommended for Quick Testing)
**Purpose**: General integration test covering basic sync functionality

**What it tests**:
- Builds macOS and Android apps
- Starts applications
- LAN discovery and WebSocket connection
- macOS → Android clipboard sync
- Android → macOS clipboard sync
- Encryption verification
- History storage

**Usage**:
```bash
./tests/test-sync.sh
```

**When to use**: Quick verification that sync is working end-to-end

**Prerequisites**:
- macOS app buildable
- Android device connected via USB
- Backend accessible (optional)

---

#### `test-sync-matrix.sh` - Comprehensive Matrix Test (Recommended for Full Coverage)
**Purpose**: Exhaustive test covering all combinations of sync scenarios

**What it tests**:
- **16 test cases total**:
  - **Text sync (8 cases)**: Plaintext/Encrypted × Cloud/LAN × macOS/Android
  - **Image sync (8 cases)**: Plaintext/Encrypted × Cloud/LAN × macOS/Android

**Usage**:
```bash
./tests/test-sync-matrix.sh
```

**Configuration**:
- Device IDs loaded from `.env` file (fallback to defaults)
- Uses real device keys from keychain/.env
- Prefers physical device over emulator for LAN tests

**When to use**: 
- Before releases
- When testing new transport features
- When verifying encryption works across all paths
- Comprehensive regression testing

**Prerequisites**:
- `.env` file with device IDs and encryption keys (see below)
- macOS app running
- Android device connected (physical device preferred for LAN tests)
- Backend accessible for cloud tests

**Output**: Detailed results for each of the 16 test cases

---

### Specialized Tests

#### `test-clipboard-polling.sh` - Clipboard Polling Test
**Purpose**: Tests clipboard polling implementation on Android

**What it tests**:
- Clipboard change detection via polling
- Polling frequency and reliability
- Manual clipboard copy detection

**Usage**:
```bash
./tests/test-clipboard-polling.sh
```

**When to use**: When testing or debugging clipboard polling behavior

**Note**: Requires manual interaction - you'll be prompted to copy text on the device

---

#### `test-clipboard-sync-emulator-auto.sh` - Automated Emulator Test
**Purpose**: Automated clipboard sync test specifically for Android emulator

**What it tests**:
- Emulator-specific sync functionality
- Automated clipboard copy via ADB
- Sync verification

**Usage**:
```bash
./tests/test-clipboard-sync-emulator-auto.sh
```

**When to use**: 
- CI/CD pipelines
- Automated testing without physical device
- Development when physical device unavailable

**Prerequisites**:
- Android emulator running or will be started automatically
- Android SDK configured

---

#### `test-server-all.sh` - Backend API Test
**Purpose**: Tests all backend server endpoints and functionality

**What it tests**:
- Health endpoint (`/health`)
- Status endpoint (`/status`)
- Metrics endpoint (`/metrics`)
- Pairing endpoints (`/pairing/create`, `/pairing/claim`)
- WebSocket connectivity
- Error handling

**Usage**:
```bash
# Test production server
./tests/test-server-all.sh

# Test local server
USE_LOCAL=true ./tests/test-server-all.sh
```

**Configuration**:
- `SERVER_URL`: Production server URL (default: `https://hypo.fly.dev`)
- `LOCAL_URL`: Local server URL (default: `http://localhost:8080`)
- `USE_LOCAL`: Set to `true` to test local server

**When to use**: 
- After backend deployments
- When testing backend changes
- Verifying server health

---

#### `test-transport-persistence.sh` - Transport Status Persistence Test
**Purpose**: Verifies transport status persists across app restarts

**What it tests**:
- Transport status saved to SharedPreferences
- Status restored after app restart
- No "No SharedPreferences available" warnings

**Usage**:
```bash
./tests/test-transport-persistence.sh
```

**When to use**: When testing transport layer persistence fixes

**Prerequisites**:
- Android device connected
- App buildable and installable

---

## Test Data Files

### `crypto_test_vectors.json`
Test vectors for cryptographic operations. Used by:
- `android/app/src/test/java/com/hypo/clipboard/crypto/CryptoServiceTest.kt`
- `macos/Tests/HypoAppTests/CryptoServiceTests.swift`
- `backend/src/crypto/test_vectors.rs`

**Note**: This is for unit tests with deterministic test vectors. Integration tests use real device keys from `.env` or keychain.

### `transport/` Directory
Transport layer test data:
- `cloud_metrics.json` - Cloud transport metrics
- `frame_vectors.json` - WebSocket frame test vectors
- `lan_loopback_metrics.json` - LAN transport loopback metrics

Used by `scripts/run-transport-regression.sh` for cross-platform transport regression testing.

---

## Configuration

### Environment Variables

For `test-sync-matrix.sh`, create a `.env` file in the project root:

```bash
# Device IDs (UUIDs without platform prefix)
MACOS_DEVICE_ID=007e4a95-0e1a-4b10-91fa-87942efaa68e
ANDROID_DEVICE_ID=0d50ce95-628a-4271-bffb-f41c87017c8c

# Encryption keys (64 hex characters, from keychain or device)
MACOS_DEVICE_KEY=<64-char-hex-key>
ANDROID_DEVICE_KEY=<64-char-hex-key>
```

**Getting encryption keys**:
- **macOS**: `security find-generic-password -w -s 'com.hypo.clipboard.keys' -a <device_id>`
- **Android**: Check app logs or SharedPreferences

**Note**: Keys are sensitive - never commit `.env` file to git.

### Android Device Selection

Tests automatically detect Android devices:
1. Prefers physical device over emulator (for LAN tests)
2. Falls back to emulator if no physical device found
3. Uses `ANDROID_ADB_DEVICE` environment variable if set

---

## Test Execution Order

### Recommended Test Sequence

1. **Quick Verification** (5 minutes):
   ```bash
   ./tests/test-sync.sh
   ```

2. **Backend Health Check** (1 minute):
   ```bash
   ./tests/test-server-all.sh
   ```

3. **Full Matrix Test** (15-20 minutes):
   ```bash
   ./tests/test-sync-matrix.sh
   ```

4. **Specialized Tests** (as needed):
   ```bash
   ./tests/test-clipboard-polling.sh
   ./tests/test-transport-persistence.sh
   ```

### CI/CD Integration

For automated testing:
```bash
# Start emulator
./scripts/start-android-emulator.sh

# Run automated emulator test
./tests/test-clipboard-sync-emulator-auto.sh

# Run backend tests
./tests/test-server-all.sh
```

---

## Test Results

### Output Locations

- **Logs**: `/tmp/hypo_test_logs/` (for `test-sync.sh`)
- **Results**: Console output + `/tmp/test_results_*.txt` (for `test-sync-matrix.sh`)

### Interpreting Results

**test-sync-matrix.sh**:
- ✅ **PASSED**: Test case completed successfully
- ❌ **FAILED**: Test case failed (check logs for details)
- ⚠️ **PARTIAL**: Test case partially passed (e.g., LAN failed but Cloud succeeded)
- ⏭️ **SKIPPED**: Test case skipped (e.g., device not connected)

**Common Failure Reasons**:
- Device not connected or not paired
- Network connectivity issues (LAN/Cloud)
- Encryption key mismatch
- Backend server unreachable
- App not running or crashed

---

## Troubleshooting

### Tests Fail to Find Devices

```bash
# Check device connection
./scripts/check-android-device.sh

# Verify device IDs in .env match actual devices
adb devices
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep "device ID"
```

### Encryption Key Errors

```bash
# macOS: Check keychain
security find-generic-password -s 'com.hypo.clipboard.keys' -a <device_id>

# Android: Check logs
adb logcat | grep -v "MIUIInput" | grep "Key saved\|encryption"
```

### Network Issues

```bash
# Test LAN connectivity
ping <android-ip-address>

# Test backend connectivity
curl https://hypo.fly.dev/health

# Check firewall settings
# macOS: System Settings → Network → Firewall
```

### Log Analysis

All tests provide detailed logging. For specific issues:

```bash
# macOS logs
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 10m

# Android logs (filter MIUIInput noise)
adb logcat | grep -vE "MIUIInput|SKIA|VRI|RenderThread"

# Backend logs
flyctl logs --app hypo
```

---

## Test Coverage

### What's Tested

✅ **Clipboard Sync**
- Text sync (plaintext and encrypted)
- Image sync (plaintext and encrypted)
- Bidirectional sync (macOS ↔ Android)
- Multiple transport paths (LAN and Cloud)

✅ **Transport Layer**
- LAN WebSocket connections
- Cloud relay connections
- Transport status persistence
- Connection recovery

✅ **Encryption**
- End-to-end encryption with real keys
- Key exchange and storage
- Decryption verification

✅ **Backend**
- Health and status endpoints
- Pairing endpoints
- WebSocket message routing
- Error handling

✅ **Platform Features**
- Clipboard polling (Android)
- History storage
- Device discovery

### What's Not Tested (Unit Tests)

These are covered by platform-specific unit tests:
- Cryptographic operations (see `crypto_test_vectors.json`)
- Data structures and models
- Individual component logic

See:
- `android/app/src/test/` - Android unit tests
- `macos/Tests/` - macOS unit tests
- `backend/tests/` - Backend integration tests

---

## Contributing

When adding new tests:

1. **Follow naming convention**: `test-<feature>.sh`
2. **Include prerequisites**: Document what's needed to run
3. **Provide clear output**: Use colors and structured logging
4. **Handle errors gracefully**: Don't exit on first failure
5. **Document in this README**: Add entry with purpose and usage

### Test Script Template

```bash
#!/bin/bash
# Test <feature name>
# Purpose: <what it tests>

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Helper functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Test implementation
main() {
    log_info "Starting test..."
    # Test code here
    log_success "Test passed!"
}

main "$@"
```

---

## Notes

- **MIUIInput Filtering**: Always filter `MIUIInput` from Android logs when debugging
- **Real Keys**: Integration tests use real device keys, not test vectors
- **Network Requirements**: LAN tests require devices on same network
- **Timing**: Some tests include delays for network operations - adjust if needed
- **Device Preferences**: Physical devices preferred over emulators for LAN tests

---

**Last Updated**: December 2025  
**Test Suite Version**: 1.0

