# Hypo Scripts Documentation

This directory contains automation scripts for building, testing, and managing the Hypo clipboard sync project.

## Quick Reference

### Build Scripts
- **`build-android.sh`** - Build and install Android APK on connected devices (default: debug)
  ```bash
  ./scripts/build-android.sh              # Build debug (default)
  ./scripts/build-android.sh release     # Build release
  ./scripts/build-android.sh both        # Build both debug and release
  ./scripts/build-android.sh clean       # Clean and build debug
  ```
- **`build-macos.sh`** - Build and launch macOS menu bar app (default: debug)
  ```bash
  ./scripts/build-macos.sh               # Build debug (default)
  ./scripts/build-macos.sh release        # Build release
  ./scripts/build-macos.sh clean         # Clean and build debug
  ```
- **`build-all.sh`** - Build both Android and macOS apps
  ```bash
  ./scripts/build-all.sh                  # Build both platforms (debug)
  ./scripts/build-all.sh deploy           # Build both platforms and deploy backend
  ```
- **`deploy.sh`** - Deploy backend to Fly.io production (defaults to local build for faster deployment)
  ```bash
  ./scripts/deploy.sh deploy              # Full deployment (default, local build)
  ./scripts/deploy.sh test                # Run tests only
  ./scripts/deploy.sh verify              # Verify existing deployment
  ./scripts/deploy.sh info                # Show deployment information
  ```
- **`benchmark-deploy.sh`** - Benchmark local vs remote Fly.io deployments
  ```bash
  ./scripts/benchmark-deploy.sh           # Full benchmark (local + remote comparison)
  ./scripts/benchmark-deploy.sh --quick   # Quick local build benchmark only
  ```

### Testing Scripts
All test scripts are now in the `tests/` directory:

- **`tests/test-sync.sh`** - **Main comprehensive sync testing suite** (recommended)
  ```bash
  ./tests/test-sync.sh                # Full comprehensive test
  ```
- **`tests/test-sync-matrix.sh`** - **Comprehensive matrix test** (tests all 8 combinations: Plaintext/Encrypted × Cloud/LAN × macOS/Android)
  ```bash
  ./tests/test-sync-matrix.sh         # Run all 8 test combinations
  ```
- **`tests/test-server-all.sh`** - Backend server API testing
- **`tests/test-clipboard-sync-emulator-auto.sh`** - Automated emulator testing
- **`tests/test-clipboard-polling.sh`** - Tests clipboard polling implementation
- **`tests/test-transport-persistence.sh`** - Tests transport status persistence

**Test runner scripts (in `scripts/` directory):**
- **`run-transport-regression.sh`** - Cross-platform transport metrics regression tests

### Monitoring Scripts
- **macOS Logs**: Use unified logging system (see `docs/TROUBLESHOOTING.md` for detailed logging guide)
  ```bash
  # View all logs (excluding MIUIInput)
  log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug | grep -v "MIUIInput"
  
  # View error logs only (quick error check)
  log stream --predicate 'subsystem == "com.hypo.clipboard"' --level error --style compact
  ```

### Setup Scripts
- **`setup-android-sdk.sh`** - Install Android SDK for headless builds
- **`setup-android-emulator.sh`** - Set up Android emulator
- **`start-android-emulator.sh`** - Start Android emulator

### Utility Scripts
- **`check-android-device.sh`** - Check if Android device is connected
- **`check-accessibility.sh`** - Check Android accessibility service status
- **`check-notification-status.sh`** - Check Android notification permission and channel status
- **`reopen-android-app.sh`** - Reopen Android app
- **`timeout.sh`** - Timeout wrapper for long-running commands

### Simulation & Testing Tools
- **`simulate-android-copy.py`** - Simulate Android clipboard sync via LAN WebSocket (see `README-simulate.md`)
  ```bash
  python3 scripts/simulate-android-copy.py --text "Test message"
  ```
- **`simulate-android-relay.py`** - Simulate clipboard sync via cloud relay
  ```bash
  python3 scripts/simulate-android-relay.py --text "Test message" --target-device-id <device_id>
  ```
- **`simulate-sms.sh`** - Simulate SMS reception on Android (emulator only)
  ```bash
  ./scripts/simulate-sms.sh <device_id> "+1234567890" "Test SMS message"
  ```
- **`test-sms-clipboard.sh`** - Comprehensive SMS-to-clipboard testing suite
  ```bash
  ./scripts/test-sms-clipboard.sh <device_id>
  ```
- **`clipboard_sender.py`** - Common module providing `send_via_lan()` and `send_via_cloud_relay()` functions

### Development/Debugging Tools
These scripts are for specific debugging scenarios:
- **`diagnose-lan-discovery.sh`** - Comprehensive LAN discovery diagnostic tool (see `DIAGNOSTIC_README.md`)
- **`analyze-routing-logs.sh`** - Analyze backend routing logs from Fly.io
- **`screenshot-android.sh`** - Capture Android device cast window screenshots
- **`analyze-screenshot.sh`** - Analyze screenshots with OCR (requires tesseract)
- **`capture-crash.sh`** - Monitor and capture crash logs when manually copying text

## Usage Examples

### Build and Test Workflow
```bash
# Build both apps (debug)
./scripts/build-all.sh

# Build both apps and deploy backend
./scripts/build-all.sh deploy

# Run comprehensive sync test
./tests/test-sync.sh

# View macOS logs during test
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug | grep -v "MIUIInput"
```

### Android Development
```bash
# Build and install debug APK on connected device (default)
./scripts/build-android.sh

# Build release APK
./scripts/build-android.sh release

# Check device connection
./scripts/check-android-device.sh

# Check accessibility service
./scripts/check-accessibility.sh

# Check notification status
./scripts/check-notification-status.sh <device_id>

# Test SMS-to-clipboard functionality
./scripts/test-sms-clipboard.sh <device_id>
```

### macOS Development
```bash
# Build and launch app (debug, default)
./scripts/build-macos.sh

# Build release version
./scripts/build-macos.sh release

# App will appear in menu bar
# Click icon to open popup window
```

### Backend Testing & Deployment
```bash
# Test all backend endpoints
./tests/test-server-all.sh

# Run transport regression tests
./scripts/run-transport-regression.sh

# Deploy backend to Fly.io (local build by default)
./scripts/deploy.sh deploy

# Run backend tests only
./scripts/deploy.sh test

# Verify deployment
./scripts/deploy.sh verify

# Benchmark deployment strategies
./scripts/benchmark-deploy.sh --quick    # Quick local build benchmark
./scripts/benchmark-deploy.sh           # Full comparison
```

## Script Dependencies

### Required Environment Variables
- `JAVA_HOME` - Java 17+ installation path
- `ANDROID_SDK_ROOT` - Android SDK path (or use `setup-android-sdk.sh`)

### Required Tools
- `adb` - Android Debug Bridge (from Android SDK)
- `swift` - Swift compiler (for macOS builds)
- `cargo` - Rust toolchain (for backend builds)

## Script Consolidation

The following scripts have been consolidated or removed:
- ✅ `test-clipboard.sh` → Merged into `test-sync.sh` (removed - was just a wrapper)
- ✅ `test-clipboard-sync-15s.sh` → Removed (consolidated)
- ✅ `test-pairing-and-sync.sh` → Removed (consolidated)
- ✅ `watch-and-build.sh` → Removed (use IDE features for auto-build)
- ✅ `automate-android-test.sh` → Removed (functionality available via `screenshot-android.sh` + `analyze-screenshot.sh`)
- ✅ `screenshot-simple.sh` → Removed (redundant with `screenshot-android.sh`)
- ✅ `capture-window-auto.sh` → Removed (redundant with `screenshot-android.sh`)
- ✅ `monitor-pairing.sh` → Removed (use unified logging: `log stream --predicate 'subsystem == "com.hypo.clipboard"'`)
- ✅ `generate-icons.sh` → Removed (redundant with `generate-icons.py`, which is used by build scripts)
- ✅ `generate-icons-from-svg.py` → Removed (redundant, `generate-icons.py` is used by build scripts and doesn't require SVG file)
- ✅ `detect-cloud-disconnection.sh` → Removed (hardcoded device ID, use general log monitoring instead)
- ✅ `quick-benchmark.sh` → Merged into `benchmark-deploy.sh` with `--quick` flag
- ✅ `check-macos-errors.sh` → Merged into `docs/TROUBLESHOOTING.md` (see macOS logging section)
- ✅ `create-release.sh` → Merged into `.github/workflows/release.yml` (automated via GitHub Actions)
- ✅ `list-windows.sh` → Removed (no longer needed)
- ✅ `get-window-bounds.py` → Removed (no longer needed)
- ✅ `focus-cast-window.sh` → Removed (no longer needed)
- ✅ `find-cast-window.py` → Removed (no longer needed)

**All test scripts are now in the `tests/` directory:**
- `tests/test-sync.sh` - Comprehensive sync testing suite
- `tests/test-sync-matrix.sh` - Comprehensive matrix test (all 8 combinations)
- `tests/test-server-all.sh` - Backend API testing
- `tests/test-clipboard-sync-emulator-auto.sh` - Automated emulator testing
- `tests/test-clipboard-polling.sh` - Tests clipboard polling implementation
- `tests/test-transport-persistence.sh` - Tests transport status persistence

## Notes

- Most scripts automatically detect Android SDK location
- macOS logs use unified logging: `log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug`
- Build logs may be saved to `/tmp/hypo_build.log` temporarily
- Scripts use colored output for better readability
- All scripts are bash-compatible and tested on macOS
- See `docs/UUID_FORMAT_ANALYSIS.md` for discussion on device ID format

