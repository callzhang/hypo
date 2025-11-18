# Hypo Sync Testing Guide

**Last Updated**: December 19, 2025

## Quick Start

### Automated Testing

Run the comprehensive test suite:

```bash
./scripts/test-sync.sh
```

This script will:
1. ✅ **Build** macOS and Android apps (if code changed)
2. ✅ **Deploy** backend to Fly.io (if code changed)
3. ✅ **Start** macOS app with logging
4. ✅ **Monitor** Android logs via ADB
5. ✅ **Test** macOS → Android sync
6. ✅ **Test** Android → macOS sync
7. ✅ **Verify** LAN discovery, encryption, WebSocket, history

### Prerequisites

- macOS with Xcode and Swift
- Android device connected via USB with USB debugging enabled
- OpenJDK 17 installed
- Android SDK configured (via `./scripts/setup-android-sdk.sh`)
- `flyctl` installed (optional, for backend deployment)

### Logs Location

All logs are stored in `/tmp/hypo_test_logs/`:
- `macos.log` - macOS app runtime logs
- `android.log` - Android app logs (filtered)
- `macos_build.log` - macOS build output
- `android_build.log` - Android build output
- `backend_deploy.log` - Backend deployment output

---

## Testing Checklist

### Pre-Test Verification

- [x] macOS WebSocket server listening on port 7010
- [x] Android service running (ClipboardSyncService)
- [x] Both apps built with latest changes
- [x] No compilation errors
- [x] Log monitoring set up

### Test 1: LAN Auto-Discovery Pairing

**Steps:**
1. Open Android app
2. Navigate to Pairing screen → LAN tab
3. Wait for macOS device to appear in list
4. Tap the macOS device

**Expected Results:**
- [ ] Android shows "Pairing..." state
- [ ] Android logs show: `🔵 pairWithDevice called`
- [ ] Android logs show: `Sending pairing challenge to macOS as raw JSON`
- [ ] macOS logs show: `📱 Received pairing challenge from: [device name]`
- [ ] macOS logs show: `🔑 Loading LAN pairing key`
- [ ] macOS logs show: `✅ Generated ACK with challengeId`
- [ ] macOS logs show: `📤 Sending ACK to Android device`
- [ ] Android logs show: `Received pairing ACK from macOS`
- [ ] Android logs show: `✅ Pairing handshake completed! Key saved`
- [ ] Android shows "Pairing Success" message
- [ ] Android logs show: `✅ Key exists in store: [size] bytes`
- [ ] Android logs show: `✅ Target devices now: [device IDs]`

**Verification:**
- [ ] Check Android Settings → Paired Devices (should show macOS device)
- [ ] Check macOS app (should show Android device in paired devices)
- [ ] Verify encryption key was saved (Android logs should confirm)

**Monitoring:**
```bash
# Use unified pairing monitor
./scripts/monitor-pairing.sh debug
```

### Test 2: Android → macOS Clipboard Sync

**Steps:**
1. Ensure devices are paired (from Test 1)
2. Copy text on Android (e.g., "Test from Android - [timestamp]")
3. Wait 2-3 seconds
4. Check macOS clipboard history

**Expected Results:**
- [ ] Android logs show: `📋 NEW clipboard event!`
- [ ] Android logs show: `📨 Received clipboard event`
- [ ] Android logs show: `💾 Upserting item to repository...`
- [ ] Android logs show: `📤 Broadcasting to [N] paired devices`
- [ ] Android logs show: `📤 Syncing to device: [device ID]`
- [ ] Android logs show: `✅ transport.send() completed successfully`
- [ ] macOS logs show: `📥 CLIPBOARD RECEIVED: from connection [ID], [N] bytes`
- [ ] macOS logs show: `✅ Decoded clipboard event: type=text`
- [ ] macOS clipboard history shows the text
- [ ] macOS clipboard content matches Android text

**Verification:**
- [ ] Text appears in macOS history within 2 seconds
- [ ] Device name shows as Android device name (not "macOS")
- [ ] No duplicate entries in history

### Test 3: macOS → Android Clipboard Sync

**Steps:**
1. Ensure devices are paired
2. Copy text on macOS (e.g., "Test from macOS - [timestamp]")
3. Wait 2-3 seconds
4. Check Android clipboard history

**Expected Results:**
- [ ] macOS logs show: `✅ Synced clipboard to device: [device name]`
- [ ] Android logs show: `📥 Received clipboard from deviceId=[ID], deviceName=[name]`
- [ ] Android logs show: `✅ Decoded remote clipboard. Forwarding to SyncCoordinator`
- [ ] Android logs show: `⏭️ Skipping broadcast (received from remote)`
- [ ] Android clipboard history shows the text
- [ ] Android clipboard content matches macOS text

**Verification:**
- [ ] Text appears in Android history within 2 seconds
- [ ] Device name shows as macOS device name (not "This device")
- [ ] No duplicate entries in history
- [ ] No sync loop (item doesn't bounce back to macOS)

### Test 4: Bidirectional Sync (Stress Test)

**Steps:**
1. Rapidly copy text on Android, then macOS, then Android again (3-4 times)
2. Monitor both histories

**Expected Results:**
- [ ] All items appear in both histories
- [ ] Correct device names for each item
- [ ] No duplicates
- [ ] No sync loops
- [ ] Items appear in correct order (most recent first)

### Test 5: Connection Recovery

**Steps:**
1. Pair devices successfully
2. Close macOS app
3. Try to copy on Android
4. Reopen macOS app
5. Try to copy on Android again

**Expected Results:**
- [ ] Android detects connection loss gracefully
- [ ] Android attempts reconnection when macOS app reopens
- [ ] Sync resumes after reconnection
- [ ] No crashes on either side

---

## Manual Testing Procedures

### Build & Install

#### macOS
```bash
cd macos
swift build -c release

# Update the app bundle
cp .build/release/HypoMenuBar HypoApp.app/Contents/MacOS/HypoMenuBar

# Launch the app
open HypoApp.app
```

#### Android
```bash
./scripts/build-android.sh
# Or manually:
cd android
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
export ANDROID_SDK_ROOT="$(pwd)/../.android-sdk"
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

#### Backend (Optional)
```bash
cd backend
flyctl deploy
# Or run locally:
docker compose up redis -d
cargo run
```

### Device Pairing

#### LAN Auto-Discovery Pairing (Recommended)
1. Ensure both devices are on the same Wi-Fi network
2. On macOS: Click menu bar icon → Settings → "Pair new device"
3. Wait for Android device to appear in discovery list
4. Tap the Android device to pair
5. ✅ Check: Pairing completes automatically

#### QR Code Pairing
1. On macOS: Click menu bar icon → Settings → "Pair new device" → QR tab
2. On Android: Open app → Pair → Scan QR Code
3. Scan the QR code displayed on macOS
4. ✅ Check: Pairing completes with "Pairing successful" message

#### Remote Code Pairing
1. On macOS: Click menu bar icon → Settings → "Pair new device" → Remote Code tab
2. Note the 6-digit code
3. On Android: Open app → Pair → Enter Code
4. Enter the code from macOS
5. ✅ Check: Pairing completes

### Sync Testing

#### Test: macOS → Android
1. Copy text on macOS (Cmd+C)
2. ✅ Check: Android shows notification with clipboard preview
3. ✅ Check: Android clipboard contains the same text
4. ✅ Check: Android history shows the item

**Logs to monitor:**
```bash
# macOS
tail -f /tmp/hypo_test_logs/macos.log | grep -i "clipboard\|sync"

# Android
adb logcat -s "ClipboardSyncService:*" "SyncCoordinator:*" "SyncEngine:*"
```

#### Test: Android → macOS
1. Copy text on Android
2. ✅ Check: macOS receives the clipboard (verify with Cmd+V)
3. ✅ Check: macOS history shows the item with "from Android" label

#### Test: Link Sync
1. Copy a URL on either device
2. ✅ Check: Link syncs correctly
3. ✅ Check: Link is clickable on receiving device

#### Test: Image Sync
1. Copy an image on either device
2. ✅ Check: Image data syncs
3. ⚠️ Note: Images > 1MB may be skipped

### LAN Discovery

#### Test: Device Discovery
1. Ensure both devices are on same Wi-Fi
2. ✅ Check macOS logs for: `"Discovered Android device"`
3. ✅ Check Android logs for: `"Discovered macOS device"`

**Manual verification:**
```bash
# Check Bonjour services on macOS
dns-sd -B _hypo._tcp local.

# Check Android NSD
adb logcat -s "LanDiscovery:*"
```

### Transport Tests

#### Test: LAN-First Transport
1. Pair devices on same Wi-Fi
2. Copy text
3. ✅ Check logs show: `"Connected via LAN"` or `"transport=lan"`

#### Test: Cloud Fallback
1. Disconnect devices from Wi-Fi (use cellular on Android)
2. Copy text
3. ✅ Check logs show: `"Connected via cloud"` or `"transport=cloud"`
4. ✅ Check backend logs: `fly logs -a hypo`

### Battery Optimization (Android)

#### Test: Screen-Off Idle
1. Copy text to verify sync is working
2. Turn off Android screen
3. ✅ Check Android logs show: `"Screen OFF - idling WebSocket"`
4. Wait 30 seconds
5. Turn on Android screen
6. ✅ Check logs show: `"Screen ON - resuming WebSocket"`
7. Copy text again to verify sync resumes

### History & Persistence

#### Test: History Storage
1. Copy 5 different items
2. ✅ Check: macOS menu shows all 5 items in history
3. ✅ Check: Android history tab shows all 5 items
4. Restart both apps
5. ✅ Check: History persists across restarts

#### Test: History Search
1. On macOS: Enter search query in history
2. ✅ Check: Results filter correctly
3. On Android: Use search in history tab
4. ✅ Check: Results filter correctly

### Error Scenarios

#### Test: Network Interruption
1. Start sync with text
2. Disconnect Wi-Fi mid-sync
3. ✅ Check: App handles gracefully (no crash)
4. Reconnect Wi-Fi
5. ✅ Check: Sync resumes automatically

#### Test: Unpaired Device
1. Clear paired devices on one side
2. Try to copy text
3. ✅ Check: No sync occurs
4. ⚠️ Check: User is notified (future enhancement)

#### Test: Invalid QR Code
1. Generate QR code on macOS
2. Wait > 5 minutes (expiry time)
3. Try to scan on Android
4. ✅ Check: Shows "QR code expired" error

### Performance Tests

#### Test: Sync Latency
1. Copy text on macOS
2. Time until Android receives it
3. ✅ Target: < 500ms on LAN
4. ✅ Target: < 2s on cloud

#### Test: Large Payload
1. Copy 100KB of text
2. ✅ Check: Syncs successfully
3. Copy 1MB of text
4. ✅ Check: Syncs successfully (compression helps)

#### Test: Rapid Copies
1. Copy 10 items rapidly (within 10 seconds)
2. ✅ Check: All items sync
3. ✅ Check: Order is preserved
4. ✅ Check: No duplicate entries

### Security Tests

#### Test: Encryption
1. Monitor network traffic with Wireshark
2. Copy sensitive text
3. ✅ Check: Payload is encrypted (not readable in packet capture)
4. ✅ Check: Logs show "AES-256-GCM" encryption

#### Test: Key Isolation
1. Pair Device A with Device B
2. Try to decrypt messages from Device A on Device C (unpaired)
3. ✅ Check: Decryption fails (no shared key)

---

## Server Testing

### Test All Server Endpoints

```bash
# Test all backend server endpoints and functions
./scripts/test-server-all.sh

# Test with local server (if running locally)
USE_LOCAL=true ./scripts/test-server-all.sh
```

The server test script validates:
- ✅ Health endpoint
- ✅ Metrics endpoint (Prometheus format)
- ✅ Pairing code creation and claim
- ✅ WebSocket endpoint validation
- ✅ Error handling (404 responses)
- ✅ CORS headers

**Server Test Results**: All 7 endpoint tests passing ✅ (Dec 19, 2025)

---

## Debugging Tips

See [`docs/testing/DEBUGGING.md`](DEBUGGING.md) for comprehensive debugging guide.

---

## CI/CD Integration

The test script can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Run Hypo Sync Tests
  run: |
    ./scripts/test-sync.sh
  env:
    FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

---

## Reporting Issues

When reporting sync issues, include:

1. **Logs**: Attach `/tmp/hypo_test_logs/*.log`
2. **Device Info**: macOS version, Android version, device model
3. **Network**: Wi-Fi vs cellular, same network or not
4. **Test Results**: Output from `./scripts/test-sync.sh`
5. **Steps to Reproduce**: Exact sequence that triggers the issue

---

## Quick Smoke Test

Minimal verification that sync is working:

```bash
# 1. Start apps
open macos/HypoApp.app
# Android app should already be running

# 2. Test basic sync
echo "Test $(date)" | pbcopy
sleep 2
adb shell "am broadcast -a clipper.get" || adb shell "cmd clipboard get-clipboard"

# 3. Check logs
tail /tmp/hypo_test_logs/macos.log | grep -i sync
adb logcat -d -s "SyncCoordinator:*" | tail -n 5
```

✅ If you see "Synced clipboard" in logs, basic sync is working!

---

## Known Issues to Watch For

1. **Signature Verification Error**: Should be resolved with LAN auto-discovery marker
2. **Key Not Found**: Should be resolved with proper key storage during pairing
3. **Sync Loops**: Should be prevented by `skipBroadcast` flag
4. **Device Name Attribution**: Should be correct with `sourceDeviceName` preservation

## Success Criteria

All tests pass if:
- ✅ Pairing completes successfully with key exchange
- ✅ Bidirectional sync works in both directions
- ✅ Device names are correctly attributed
- ✅ No sync loops or duplicates
- ✅ Connection recovery works
- ✅ No crashes or errors in logs

