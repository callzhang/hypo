# Hypo Scripts Documentation

This directory contains automation scripts for building, testing, and managing the Hypo clipboard sync project.

## Quick Reference

### Build Scripts
- **`build-android.sh`** - Build and install Android APK on connected devices
- **`build-macos.sh`** - Build and launch macOS menu bar app
- **`build-all.sh`** - Build both Android and macOS apps

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
- **`monitor-pairing.sh`** - Monitor pairing logs (watch/debug/test modes)
  ```bash
  ./scripts/monitor-pairing.sh watch   # Watch pairing logs
  ./scripts/monitor-pairing.sh debug   # Debug pairing issues
  ./scripts/monitor-pairing.sh test    # Test pairing flow
  ```

### Setup Scripts
- **`setup-android-sdk.sh`** - Install Android SDK for headless builds
- **`setup-android-emulator.sh`** - Set up Android emulator
- **`start-android-emulator.sh`** - Start Android emulator

### Utility Scripts
- **`check-android-device.sh`** - Check if Android device is connected
- **`check-accessibility.sh`** - Check Android accessibility service status
- **`reopen-android-app.sh`** - Reopen Android app
- **`timeout.sh`** - Timeout wrapper for long-running commands

### Simulation & Testing Tools
- **`simulate-android-copy.py`** - Simulate Android clipboard sync for testing (see `README-simulate.md`)
  ```bash
  python3 scripts/simulate-android-copy.py --text "Test message"
  ```
- **`simulate-android-relay.py`** - Simulate clipboard sync via cloud relay

### Development/Debugging Tools
These scripts are for specific debugging scenarios and can be kept for ad-hoc use:
- **`screenshot-android.sh`** - Capture Android device cast window screenshots
- **`analyze-screenshot.sh`** - Analyze screenshots with OCR (requires tesseract)
- **`capture-crash.sh`** - Monitor and capture crash logs when manually copying text
- **`focus-cast-window.sh`** - Focus Android cast window for screenshots
- **`list-windows.sh`** - List all macOS windows (debugging utility)
- **`find-cast-window.py`** - Find Android cast window using Python
- **`get-window-bounds.py`** - Get window bounds for screenshot automation

## Usage Examples

### Build and Test Workflow
```bash
# Build both apps
./scripts/build-all.sh

# Run comprehensive sync test
./tests/test-sync.sh

# Monitor pairing during test
./scripts/monitor-pairing.sh debug
```

### Android Development
```bash
# Build and install on connected device
./scripts/build-android.sh

# Check device connection
./scripts/check-android-device.sh

# Check accessibility service
./scripts/check-accessibility.sh
```

### macOS Development
```bash
# Build and launch app
./scripts/build-macos.sh

# App will appear in menu bar
# Click icon to open popup window
```

### Backend Testing
```bash
# Test all backend endpoints
./tests/test-server-all.sh

# Run transport regression tests
./scripts/run-transport-regression.sh
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

**All test scripts are now in the `tests/` directory:**
- `tests/test-sync.sh` - Comprehensive sync testing suite
- `tests/test-sync-matrix.sh` - Comprehensive matrix test (all 8 combinations)
- `tests/test-server-all.sh` - Backend API testing
- `tests/test-clipboard-sync-emulator-auto.sh` - Automated emulator testing
- `tests/test-clipboard-polling.sh` - Tests clipboard polling implementation
- `tests/test-transport-persistence.sh` - Tests transport status persistence

## Notes

- Most scripts automatically detect Android SDK location
- Logs are typically saved to `/tmp/hypo_*` directories
- Scripts use colored output for better readability
- All scripts are bash-compatible and tested on macOS
- See `docs/UUID_FORMAT_ANALYSIS.md` for discussion on device ID format

