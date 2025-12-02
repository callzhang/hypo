# Debugging and Testing Guide

**Last Updated**: December 19, 2025

## Crash Report Analysis

### Finding Crash Reports

macOS stores crash reports in `~/Library/Logs/DiagnosticReports/`:

```bash
# Find recent crash reports
find ~/Library/Logs/DiagnosticReports -name "*HypoMenuBar*" -type f -mtime -1

# List crash reports sorted by time
ls -lt ~/Library/Logs/DiagnosticReports/*.ips | head -5
```

### Reading Crash Reports

Crash reports are JSON files (`.ips` format). Key information:

1. **Exception Type**: `EXC_BREAKPOINT` (SIGTRAP) indicates Swift runtime assertion failure
2. **Crashed Thread**: Thread 0 is usually the main thread
3. **Stack Trace**: Look for `frames` array in the crashed thread
4. **Source Location**: Check `sourceFile` and `sourceLine` in stack frames

```bash
# Extract key crash information
cat ~/Library/Logs/DiagnosticReports/HypoMenuBar-*.ips | \
  grep -A 30 '"faultingThread"' | \
  grep -E '"sourceFile"|"sourceLine"|"symbol"'
```

### Common Crash Patterns

#### Array Index Out of Bounds
- **Symptom**: `EXC_BREAKPOINT` at `Data.subscript.getter`
- **Cause**: Accessing array/Data index without bounds check
- **Fix**: Add guard statements before array access
- **Example**: `LanWebSocketServer.processFrameBuffer` - check buffer count before accessing `buffer[0]`

#### Force Unwrap Nil
- **Symptom**: `EXC_BREAKPOINT` with `fatalError` in stack
- **Cause**: Force unwrapping optional that is nil
- **Fix**: Use optional binding or provide default values

#### Threading Issues
- **Symptom**: Crashes in async/await code
- **Cause**: Accessing non-thread-safe resources from wrong thread
- **Fix**: Ensure `@MainActor` for UI operations, use proper synchronization

## Debug Logging

### macOS App Debug Log

The app writes debug logs to `/tmp/hypo_debug.log`:

```bash
# Monitor debug log in real-time
tail -f /tmp/hypo_debug.log

# Search for specific events
grep -E "PairingCompleted|Connection|Sync" /tmp/hypo_debug.log
```

### Android App Logs

Use `adb logcat` to view Android logs:

```bash
# Filter for specific tags
adb logcat -s LanPairingViewModel:D SyncCoordinator:D SyncEngine:D

# Monitor pairing flow
adb logcat | grep -E "Pairing|Key saved|Target devices"

# Clear logs and start fresh
adb logcat -c && adb logcat
```

### System Console Logs

```bash
# View macOS system logs for HypoMenuBar
log show --predicate 'process == "HypoMenuBar"' --last 10m --style compact

# Search for errors
log show --predicate 'process == "HypoMenuBar"' --last 30m | grep -i error
```

## Testing Workflows

### LAN Discovery & Pairing

**Quick Start:**
```bash
# Use unified pairing monitor (replaces monitor-pairing-debug.sh, watch-pairing-logs.sh)
./scripts/monitor-pairing.sh debug
```

**Test Matrix:**
| ID | Scenario | macOS Result | Android Result | Notes |
|----|----------|--------------|----------------|-------|
| QA-LAN-01 | Bonjour discovery between two peers on same subnet | ✅ Pass | ✅ Pass | Harness replayed cached TXT records |
| QA-LAN-02 | Bonjour publish lifecycle (foreground/terminate) | ✅ Pass | ✅ Pass | Observed advertise/withdraw lifecycle |
| QA-LAN-03 | NSD registration and multicast lock reacquisition | ✅ Pass | ✅ Pass | Exercised via unit tests |
| QA-LAN-04 | TLS WebSocket handshake (LAN) with fingerprint pinning | ✅ Pass | ✅ Pass | Verified handshake succeeds |
| QA-LAN-05 | TLS WebSocket idle watchdog timeout | ✅ Pass | ✅ Pass | Watchdog closes connection after idle |
| QA-LAN-06 | TLS WebSocket frame codec echo | ✅ Pass | ✅ Pass | Encoded payload echoed through loopback |
| QA-LAN-07 | LAN peer auto-pruning after idle | ✅ Pass | ✅ Pass | Stale entries dropped after 5 minutes |

**Manual Steps:**
1. **Start macOS app**:
   ```bash
   cd macos && swift build
   cp .build/arm64-apple-macosx/debug/HypoMenuBar HypoApp.app/Contents/MacOS/HypoMenuBar
   open HypoApp.app
   ```

2. **Verify server is listening**:
   ```bash
   lsof -i :7010 | grep LISTEN
   ```

3. **Start Android app** (emulator or device):
   ```bash
   ./scripts/build-android.sh
   ```

4. **Monitor pairing logs**:
   ```bash
   # macOS
   tail -f /tmp/hypo_debug.log | grep -E "Pairing|Connection"
   
   # Android
   adb logcat | grep -E "Pairing|Key saved"
   ```

5. **Verify device appears**:
   - Check macOS Settings → Paired devices
   - Check Android Settings → Paired devices

### Testing Clipboard Sync

1. **Verify devices are paired and online** (green dot in macOS, "Connected" in Android)

2. **Test Android → macOS sync**:
   ```bash
   # Copy text on Android
   adb shell input text "Test from Android"
   
   # Monitor sync logs
   adb logcat | grep -E "Clipboard|Sync|transport"
   tail -f /tmp/hypo_debug.log | grep -E "Incoming|Sync"
   ```

3. **Test macOS → Android sync**:
   ```bash
   # Copy text on macOS
   echo "Test from macOS" | pbcopy
   
   # Monitor Android logs
   adb logcat | grep -E "Clipboard|Sync|Received"
   ```

4. **Verify in UI**:
   - macOS: Check History tab for new entries
   - Android: Check History screen for new entries

### Testing Connection Status

1. **Check device online status**:
   - macOS: Settings → Paired devices (green/gray dot)
   - Android: Settings → Paired devices (Connected/Offline status)

2. **Test offline detection**:
   - Close macOS app → Android should show device as offline
   - Close Android app → macOS should show device as offline

3. **Test reconnection**:
   - Restart macOS app → Android should detect reconnection
   - Restart Android app → macOS should detect reconnection

## Common Issues and Solutions

### Issue: Device Not Appearing After Pairing

**Symptoms**:
- Android shows "Pairing completed"
- macOS doesn't show device in Settings

**Debugging**:
```bash
# Check if notification was posted
grep "PairingCompleted" /tmp/hypo_debug.log

# Check if notification was received
grep "HistoryStore.*PairingCompleted" /tmp/hypo_debug.log

# Check device ID format
adb logcat | grep "Key saved for device"
```

**Common Causes**:
- Device ID format mismatch (UUID vs "android-UUID")
- Notification not being posted/received
- HistoryStore not processing notification

### Issue: Sync Not Working

**Symptoms**:
- Devices are paired and online
- Copying doesn't sync to other device

**Debugging**:
```bash
# Check if clipboard events are detected
adb logcat | grep -E "ClipboardListener|onPrimaryClipChanged"

# Check if sync targets are set
adb logcat | grep "Target devices now"

# Check if transport.send() is called
adb logcat | grep "transport.send()"

# Check if WebSocket connection is active
adb logcat | grep -E "WebSocket|Connection"
```

**Common Causes**:
- Clipboard permission not granted
- Sync targets not including device ID
- Encryption key missing
- WebSocket connection not established

### Issue: App Crashes on Sync

**Symptoms**:
- App crashes when receiving sync data
- Crash report shows array index out of bounds

**Debugging**:
```bash
# Find latest crash report
ls -lt ~/Library/Logs/DiagnosticReports/HypoMenuBar*.ips | head -1

# Extract crash location
cat ~/Library/Logs/DiagnosticReports/HypoMenuBar-*.ips | \
  grep -A 20 '"faultingThread"' | \
  grep -E '"sourceFile"|"sourceLine"'
```

**Common Causes**:
- Buffer bounds not checked before array access
- Race condition in async code
- Force unwrap of nil optional

## Automated Testing Scripts

### Test Clipboard Sync (Emulator)

```bash
./scripts/test-clipboard-sync-emulator-auto.sh
```

This script:
- Builds and installs Android app
- Starts emulator if needed
- Monitors logs for clipboard events
- Tests bidirectional sync

### Test Transport Persistence

```bash
./scripts/test-transport-persistence.sh
```

This script:
- Pairs devices
- Verifies connection status is saved
- Restarts app
- Verifies status persists

## Debugging Tips

1. **Always check crash reports first** - They contain the exact crash location
2. **Use debug logging** - Write to `/tmp/hypo_debug.log` for persistent logs
3. **Monitor both sides** - Check macOS and Android logs simultaneously
4. **Test incrementally** - Pair first, then test sync separately
5. **Check device IDs** - Ensure consistent format across platforms
6. **Verify permissions** - Clipboard access requires explicit permission on Android 10+

## Key Files for Debugging

- **macOS crash reports**: `~/Library/Logs/DiagnosticReports/HypoMenuBar-*.ips`
- **macOS debug log**: `/tmp/hypo_debug.log`
- **Android logs**: `adb logcat`
- **Pairing flow**: `macos/Sources/HypoApp/Services/TransportManager.swift` (line 847+)
- **Sync flow**: `macos/Sources/HypoApp/Services/HistoryStore.swift` (line 289+)
- **WebSocket server**: `macos/Sources/HypoApp/Services/LanWebSocketServer.swift` (line 383+)

