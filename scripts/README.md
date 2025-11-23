# Hypo Scripts Documentation

This directory contains automation scripts for building, testing, and managing the Hypo clipboard sync project.

## Quick Reference

### Build Scripts
- **`build-android.sh`** - Build and install Android APK on connected devices
- **`build-macos.sh`** - Build and launch macOS menu bar app
- **`build-all.sh`** - Build both Android and macOS apps

### Testing Scripts
- **`test-clipboard.sh`** - **Unified clipboard sync testing** (recommended)
  ```bash
  ./scripts/test-clipboard.sh          # Quick test (15s wait window)
  ./scripts/test-clipboard.sh quick    # Quick test
  ./scripts/test-clipboard.sh full     # Full comprehensive test
  ./scripts/test-clipboard.sh pairing  # Pairing + sync test
  ./scripts/test-clipboard.sh duplicate # Duplicate detection test
  ```
- **`test-sync.sh`** - Comprehensive sync testing suite (used by `test-clipboard.sh full`)
- **`test-pairing-and-sync.sh`** - Pairing flow + sync test (used by `test-clipboard.sh pairing`)
- **`test-server-all.sh`** - Backend server API testing
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

### Specialized Scripts
- **`test-clipboard-sync-emulator-auto.sh`** - Automated emulator testing (starts emulator, builds, installs, tests)
- **`simulate-android-copy.py`** - Simulate Android clipboard sync for testing (see `README-simulate.md`)
- **`simulate-android-relay.py`** - Simulate clipboard sync via cloud relay

### Development/Debugging Tools
These scripts are for specific debugging scenarios and can be kept for ad-hoc use:
- **`capture-crash.sh`**, **`capture-window-auto.sh`** - Screen capture utilities
- **`screenshot-*.sh`**, **`analyze-screenshot.sh`** - Screenshot analysis tools
- **`focus-cast-window.sh`**, **`list-windows.sh`** - Window management utilities
- **`find-cast-window.py`**, **`get-window-bounds.py`** - Python utilities for window operations

## Usage Examples

### Build and Test Workflow
```bash
# Build both apps
./scripts/build-all.sh

# Run quick sync test
./scripts/test-clipboard.sh quick

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
./scripts/test-server-all.sh

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

The following scripts have been consolidated into `test-clipboard.sh`:
- ✅ `test-clipboard-sync-15s.sh` → `test-clipboard.sh quick` (removed)
- ✅ `test-clipboard-polling.sh` → Merged into test suite (removed)
- ✅ `test-transport-persistence.sh` → Covered by `test-sync.sh` (removed)
- ✅ `watch-and-build.sh` → Use IDE features (removed)
- ✅ `automate-android-test.sh` → Use `test-clipboard.sh` (removed)

## Notes

- Most scripts automatically detect Android SDK location
- Logs are typically saved to `/tmp/hypo_*` directories
- Scripts use colored output for better readability
- All scripts are bash-compatible and tested on macOS
- See `docs/UUID_FORMAT_ANALYSIS.md` for discussion on device ID format

