# Hypo Sync Testing Guide

## Automated Testing Script

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

## Manual Testing Checklist

### 1. Build & Install

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

---

### 2. Device Pairing

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

---

### 3. Sync Testing

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

---

### 4. LAN Discovery

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

---

### 5. Transport Tests

#### Test: LAN-First Transport
1. Pair devices on same Wi-Fi
2. Copy text
3. ✅ Check logs show: `"Connected via LAN"` or `"transport=lan"`

#### Test: Cloud Fallback
1. Disconnect devices from Wi-Fi (use cellular on Android)
2. Copy text
3. ✅ Check logs show: `"Connected via cloud"` or `"transport=cloud"`
4. ✅ Check backend logs: `fly logs -a hypo-relay-staging`

---

### 6. Battery Optimization (Android)

#### Test: Screen-Off Idle
1. Copy text to verify sync is working
2. Turn off Android screen
3. ✅ Check Android logs show: `"Screen OFF - idling WebSocket"`
4. Wait 30 seconds
5. Turn on Android screen
6. ✅ Check logs show: `"Screen ON - resuming WebSocket"`
7. Copy text again to verify sync resumes

---

### 7. History & Persistence

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

---

### 8. Error Scenarios

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

---

### 9. Performance Tests

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

---

### 10. Security Tests

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

## Debugging Tips

### macOS Debugging
```bash
# View all logs
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug

# Check keychain keys
security find-generic-password -s "com.hypo.clipboard.keys"

# Monitor pasteboard
while true; do pbpaste | head -c 50; echo ""; sleep 1; done
```

### Android Debugging
```bash
# Full verbose logging
adb logcat -v time "*:V" | grep -i "hypo\|clipboard"

# Check specific component
adb logcat -s "SyncEngine:D"

# Check battery optimization settings
adb shell dumpsys deviceidle whitelist | grep hypo

# Check network state
adb shell dumpsys wifi | grep "Wi-Fi is"
```

### Backend Debugging
```bash
# Live logs
fly logs -a hypo-relay-staging

# Check Redis
fly redis connect
> KEYS *
> GET device:<device-id>

# Health check
curl https://hypo-relay-staging.fly.dev/health

# WebSocket test
wscat -c wss://hypo-relay-staging.fly.dev/ws
```

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

Last Updated: October 12, 2025

