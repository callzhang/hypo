# Hypo Sync Testing & Debugging Guide

**Last Updated:** December 25, 2025  
**Audience:** Tech Leads, Developers

## Quick Start

### Automated Test Matrix

```bash
./tests/test-sync-matrix.sh
```

Tests all 8 combinations: Plaintext/Encrypted × Cloud/LAN × macOS/Android

### Prerequisites

- macOS with Xcode and Swift
- Android device connected via USB with USB debugging enabled
- OpenJDK 17, Android SDK configured
- `flyctl` installed (for backend deployment)

---

## Log Checking

### macOS Unified Logging

```bash
# Real-time streaming (recommended)
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug --style compact

# View recent logs
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m --level debug --style compact

# Find message by content
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m --level debug | grep -F "content: Case 1:"

# Process-based fallback
log show --predicate 'process == "HypoMenuBar"' --last 5m --style compact
```

### Android Logs

**⚠️ Always filter MIUIInput** - Add `| grep -v "MIUIInput"` to all `adb logcat` commands:

```bash
# Filter by PID (excludes MIUIInput)
adb -s <device_id> logcat --pid=$(adb -s <device_id> shell pidof -s com.hypo.clipboard.debug) | grep -v "MIUIInput" | grep "pattern"

# Simple usage (shows app logs only, no MIUIInput)
adb -s <device_id> logcat -v time "*:S" "com.hypo.clipboard.debug:D" "com.hypo.clipboard:D" | grep -v "MIUIInput"

# With custom grep filters
adb -s <device_id> logcat | grep -v "MIUIInput" | grep -E "SyncEngine|transport"

# View recent logs (filters MIUIInput)
adb -s <device_id> logcat -d -t 300 | grep -v "MIUIInput"

# Find message by content (filters MIUIInput)
adb -s <device_id> logcat -d | grep -v "MIUIInput" | grep -F "content: Case 1:"
```

**Query database (most reliable, no filtering needed)**:
```bash
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview FROM clipboard_items ORDER BY created_at DESC LIMIT 10;'"
```

**Note**: Always add `| grep -v "MIUIInput"` to `adb logcat` commands to filter system noise from Xiaomi devices.

### Backend Logs

```bash
# View recent logs
flyctl logs --app hypo --limit 100

# Check routing
flyctl logs --app hypo --limit 100 | grep -E "\[ROUTING\]|\[SEND_BINARY\]"

# Check connected devices
curl -s https://hypo.fly.dev/health | jq '.connected_devices'
```

---

## Test Script Detection Logic

The `test-sync-matrix.sh` script detects messages by:

1. **Database Query** (Most Reliable)
   - Android: SQLite database check
   - macOS: UserDefaults check

2. **Log Content Search**
   - Searches for `content: <message>` in logs
   - macOS: `log show --predicate 'subsystem == "com.hypo.clipboard"'`
   - Android: `adb -s <device_id> logcat -d | grep -v "MIUIInput" | grep -F "content:"`

3. **Handler Success Logs**
   - macOS: `Received clipboard` or `Inserted entry`
   - Android: `Decoded clipboard event`

4. **Reception Indicators**
   - Cloud: `onMessage` calls
   - LAN: `Binary frame received`

---

## Manual Testing Procedures

### Device Pairing

**LAN Auto-Discovery** (Recommended):
1. Ensure both devices on same Wi-Fi
2. Android: Pair → LAN tab → Tap macOS device
3. Verify pairing completes

**QR Code Pairing**:
1. macOS: Settings → Pair new device → QR tab
2. Android: Pair → Scan QR Code

### Clipboard Sync Testing

**Android → macOS**:
```bash
# Copy text on Android
adb shell input text "Test from Android"

# Monitor logs (filter MIUIInput)
adb -s <device_id> logcat | grep -v "MIUIInput" | grep -E "Clipboard|Sync|transport"
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug | grep -E "Received clipboard|content:"
```

**macOS → Android**:
```bash
# Copy text on macOS
echo "Test from macOS" | pbcopy

# Monitor Android logs (filter MIUIInput)
adb -s <device_id> logcat | grep -v "MIUIInput" | grep -E "Clipboard|Sync|Received"
```

**Verification**:
- Message content is logged: `content: <message>`
- Check UI: macOS history (Cmd+Shift+V), Android history screen
- Query logs: `grep -F "content: <message>"`

---

## Common Issues & Solutions

### Messages Not Detected by Test Script

**Symptoms**: Test script reports FAILED but messages appear in UI

**Debugging**:
```bash
# Check database directly (most reliable)
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview FROM clipboard_items WHERE preview LIKE \"%Case X:%\" LIMIT 1;'"

# Check logs by content (filter MIUIInput)
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep -F "content: Case X:"
adb -s <device_id> logcat -d | grep -v "MIUIInput" | grep -F "content: Case X:"
```

**Solution**: Test script may need time window adjustment or log query refinement

### Decryption Failures (BAD_DECRYPT)

**Causes**:
- Key rotation (devices re-paired)
- Wrong key in test script
- Key not found on receiver

**Debugging**:
```bash
# Check key exists
security find-generic-password -w -s 'com.hypo.clipboard.keys' -a <device_id>

# Check decryption errors (filter MIUIInput)
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep -E "Decryption failed|BAD_DECRYPT"
adb -s <device_id> logcat -d | grep -v "MIUIInput" | grep -E "BAD_DECRYPT|MissingKey"
```

**Solution**:
1. Re-pair devices to get new key
2. Update test script key from keychain (prioritizes keychain over .env)
3. Verify key format matches (64 hex chars)

### Connection Issues

**Check connection status**:
```bash
# Backend health
curl -s https://hypo.fly.dev/health | jq '.connected_devices'

# Android WebSocket (filter MIUIInput)
adb -s <device_id> logcat -d | grep -v "MIUIInput" | grep -E "WebSocket|connected|disconnected"

# macOS WebSocket
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep -E "WebSocket|connected"
```

### Device Not Appearing After Pairing

**Debugging**:
```bash
# Check pairing completion (filter MIUIInput)
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 10m | grep "PairingCompleted"
adb -s <device_id> logcat | grep -v "MIUIInput" | grep "Key saved for device"

# Check device ID format
adb -s <device_id> logcat | grep -v "MIUIInput" | grep "Key saved for device"
```

**Common Causes**:
- Device ID format mismatch (UUID vs "android-UUID")
- Notification not being posted/received
- HistoryStore not processing notification

### Sync Not Working

**Debugging** (filter MIUIInput):
```bash
# Check clipboard events detected
adb -s <device_id> logcat | grep -v "MIUIInput" | grep -E "ClipboardListener|onPrimaryClipChanged"

# Check sync targets
adb -s <device_id> logcat | grep -v "MIUIInput" | grep "Target devices now"

# Check transport.send() called
adb -s <device_id> logcat | grep -v "MIUIInput" | grep "transport.send()"

# Check WebSocket connection
adb -s <device_id> logcat | grep -v "MIUIInput" | grep -E "WebSocket|Connection"
```

**Common Causes**:
- Clipboard permission not granted
- Sync targets not including device ID
- Encryption key missing
- WebSocket connection not established

---

## Crash Report Analysis

### Finding Crash Reports

```bash
# Find recent crash reports
find ~/Library/Logs/DiagnosticReports -name "*HypoMenuBar*" -type f -mtime -1

# Extract crash location
cat ~/Library/Logs/DiagnosticReports/HypoMenuBar-*.ips | \
  grep -A 20 '"faultingThread"' | \
  grep -E '"sourceFile"|"sourceLine"'
```

### Common Crash Patterns

**Array Index Out of Bounds**:
- Symptom: `EXC_BREAKPOINT` at `Data.subscript.getter`
- Fix: Add guard statements before array access

**Force Unwrap Nil**:
- Symptom: `EXC_BREAKPOINT` with `fatalError` in stack
- Fix: Use optional binding or provide default values

**Threading Issues**:
- Symptom: Crashes in async/await code
- Fix: Ensure `@MainActor` for UI operations, use proper synchronization

---

## Key Files

- **macOS crash reports**: `~/Library/Logs/DiagnosticReports/HypoMenuBar-*.ips`
- **macOS unified logs**: `log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug`
- **Android logs**: `adb logcat`
- **Pairing flow**: `macos/Sources/HypoApp/Services/TransportManager.swift`
- **Sync flow**: `macos/Sources/HypoApp/Services/HistoryStore.swift`
- **Incoming handler**: `macos/Sources/HypoApp/Services/IncomingClipboardHandler.swift`
- **WebSocket server**: `macos/Sources/HypoApp/Services/LanWebSocketServer.swift`
- **Android handler**: `android/app/src/main/java/com/hypo/clipboard/sync/IncomingClipboardHandler.kt`

---

## Quick Reference

### One-liners

**Android** (filter MIUIInput):
```bash
adb -s <device_id> logcat -d -t 500 | grep -v "MIUIInput" | grep -F "content:" && \
adb -s <device_id> shell "sqlite3 /data/data/com.hypo.clipboard.debug/databases/clipboard.db 'SELECT preview FROM clipboard_items ORDER BY created_at DESC LIMIT 5;'"
```

**macOS**:
```bash
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep -F "content:" && \
defaults read com.hypo.clipboard history_entries | grep -F "Case"
```

**Backend**:
```bash
flyctl logs --app hypo --limit 100 | grep -E "\[ROUTING\]" && \
curl -s https://hypo.fly.dev/health | jq '.connected_devices'
```

---

## Testing Checklist

- [ ] Devices paired (LAN or QR)
- [ ] Both apps running with latest build
- [ ] Log monitoring set up
- [ ] Test matrix run: `./tests/test-sync-matrix.sh`
- [ ] Android tests: Cases 2, 4, 6, 8 passing
- [ ] macOS tests: Cases 1, 3, 5, 7 verified
- [ ] Message content logged on both platforms
- [ ] Database/UserDefaults verification working
- [ ] No decryption failures
- [ ] Connection status correct

---

## Related Documentation

- `docs/bugs/android_cloud_sync_status.md` - Android cloud sync issues
- `docs/bugs/android_lan_sync_status.md` - Android LAN sync issues
- `docs/bugs/encryption_testing_issue.md` - Encryption testing issues
