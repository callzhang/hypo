# Hypo Troubleshooting Guide

**Comprehensive troubleshooting for Hypo clipboard sync**  
**Version**: 1.1.0  
**Last Updated**: January 13, 2026

> **Note**: As of November 2025, all critical bugs have been resolved. The system is production-ready. If you encounter issues, they are likely related to network configuration or device-specific settings.

---

## 🚨 Quick Fixes (Try These First)

### The "Have You Tried Turning It Off and On Again?" Checklist

1. **Restart Both Apps**
   - macOS: Menu bar → Quit → Reopen from Applications
   - Android: Force stop app → Reopen and start sync

2. **Check Network Connection**
   - Both devices connected to Wi-Fi
   - Internet connectivity working
   - Same network for LAN sync

3. **Verify Pairing Status**
   - Both apps show "Connected" or "Paired" status
   - Try re-pairing if showing "Disconnected"

4. **Test Basic Functionality**
   - Copy simple text on one device
   - Check if it appears on the other within 10 seconds

**If these don't work, continue to specific troubleshooting sections below.**

---

## 📋 Viewing Logs

Hypo uses `os_log` (via `HypoLogger`) for system-integrated logging on macOS. All logs are visible in Console.app and via the `log` command-line tool.

### macOS Unified Logging

#### Method 1: Console.app (Recommended)

1. Open **Console.app** (Applications → Utilities → Console)
2. In the sidebar, select your Mac under "Devices"
3. Use the search bar to filter logs:
   - **Subsystem**: `com.hypo.clipboard`
   - **Category**: Filter by specific categories (e.g., `LanWebSocketServer`, `TransportManager`, `SyncEngine`)
   - **Search terms**: Use keywords like "pairing", "connection", "error", etc.

**Tips:**
- Enable "Include Info Messages" and "Include Debug Messages" in Console preferences
- Use the filter bar to narrow down by subsystem/category
- Logs are color-coded by level (debug=gray, info=blue, error=red)

#### Method 2: Command Line (`log` command)

```bash
# Real-time streaming (recommended)
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug --style compact

# View recent logs
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m --level debug --style compact

# Find message by content
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m --level debug | grep -F "content: Case 1:"

# Process-based fallback
log show --predicate 'process == "HypoMenuBar"' --last 5m --style compact

# View logs for a specific category
log show --predicate 'subsystem == "com.hypo.clipboard" && category == "LanWebSocketServer"' --last 1h

# View only errors (quick error check)
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level error --style compact
```

#### Method 3: Filter by Process

```bash
# Find the process ID
ps aux | grep HypoMenuBar

# Stream logs for that process
log stream --predicate 'processID == <PID>' --level debug
```

### Android Logs

**⚠️ Always filter MIUIInput** - All commands below include filtering for system noise.

**📝 Subsystem Name**: Android uses the same subsystem name `"com.hypo.clipboard"` as macOS for consistency. Debug and release builds use the same application ID (`com.hypo.clipboard`), allowing them to share the same database.

```bash
# Step 1: Get your device ID
# Automatically get the first connected device ID
device_id=$(adb devices | grep -E "device$" | head -1 | awk '{print $1}' | tr -d '\r')
echo "✅ Using device: $device_id"

# Step 2: View logs

# Method 1: Pure app logs (tag-based filtering - only logs written by app code)
# This shows ONLY logs that the app code writes, excluding ALL system framework logs
# This is the closest equivalent to macOS "log stream --predicate 'process == \"HypoApp\"'"
# All app log tags (automatically collected from source code)
# Using "*:S" to silence all logs, then only show our app tags (quoted to prevent shell glob expansion)
adb logcat "*:S" AccessibilityServiceChecker:D ClipboardAccessChecker:D ClipboardAccessibilityService:D ClipboardListener:D ClipboardParser:D ClipboardRepository:D ClipboardSyncService:D ConnectionStatusProber:D CryptoService:D IncomingClipboardHandler:D LanDiscoveryRepository:D LanPairingViewModel:D LanRegistrationManager:D LanWebSocketServer:D MainActivity:D MiuiAdapter:D MiuiClipboardHistory:D PairingHandshake:D ProcessTextActivity:D RelayWebSocketClient:D ScreenStateReceiver:D ShareImageActivity:D SmsReceiver:D StorageManager:D SyncCoordinator:D SyncEngine:D TempFileManager:D TransportManager:D WebSocketTransportClient:D

# Alternative: If you want to see ALL logs from the app process (including system framework logs)
# Use PID-based filtering (may include MIUIInput, VRI, etc. from system framework)
APP_PID=$(adb -s $device_id shell "pgrep -f com.hypo.clipboard")
if [ -n "$APP_PID" ]; then
    echo "⚠️  Note: PID-based filtering includes system framework logs (MIUIInput, VRI, etc.)"
    echo "   Use tag-based filtering (Method 1) for pure app logs only"
    # Uncomment to see all process logs:
    adb -s $device_id logcat "*:D" --pid="$APP_PID"
fi

# Method 2: Filtered logs (removes system noise, but keeps app logs)
# Use this if you want to exclude system framework logs that are triggered by the app
# System noise patterns to filter (includes Android framework UI logs, GC logs, graphics errors, input system, and system initialization)
NOISE_PATTERNS=" V/|MIUI*|SKIA|VRI|RenderThread|SkJpeg|JpegXm|HWUI|ContentCatcher|HandWriting|ImeTracker|SecurityManager|InsetsController|Activity.*Resume|ProfileInstaller|FinalizerDaemon|ViewRootImpl|Choreographer|WindowOnBackDispatcher|Binder.*destroyed|弹出式窗口|Cleared Reference|sticky GC|non sticky GC|maxfree|minfree|FrameInsert|MiInputConsumer|Zygote|nativeloader|AssetManager2|ApplicationLoaders|ViewContentFactory|CompatChangeReporter|libc.*Access denied|TurboSchedMonitor|MiuiDownscaleImpl|MiuiMonitorThread|ResMonitorStub|MiuiAppAdaptationStubsControl|MiuiProcessManagerServiceStub|MiuiNBIManagerImpl|DecorViewImmersiveImpl|WM-WrkMgrInitializer|WM-PackageManagerHelper|WM-Schedulers|Adreno|Vulkan|libEGL|AdrenoVK|AdrenoUtils|SnapAlloc|qdgralloc|RenderLite|FramePredict|DecorView|ActivityThread.*HardwareRenderer|ActivityThread.*Miui Feature|ActivityThread.*TrafficStats|ActivityThread.*currentPkg|DesktopModeFlags|FirstFrameSpeedUp|ComputilityLevel|SLF4J|Sentry.*auto-init|Sentry.*Retrieving|AppScoutStateMachine|FlingPromotion|ForceDarkHelper|MiuiForceDarkConfig|vulkan.*searching|libEGL.*shader cache|Perf.*Connecting|NativeTurboSchedManager|ashmem.*Pinning|EpFrameworkFactory"

APP_PID=$(adb -s $device_id shell "pgrep -f com.hypo.clipboard")
echo "✅ Using APP_PID: $APP_PID (with noise filtering)"
adb -s $device_id logcat "*:D" --pid="$APP_PID" | grep --color=always -vE "$NOISE_PATTERNS"
```


**Query database**:
```bash
# Query database (debug and release use the same application ID)
adb -s $device_id shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT preview FROM clipboard_items ORDER BY created_at DESC LIMIT 10;'"
```

### Backend Logs

```bash
# View recent logs
flyctl logs --app hypo --limit 100

# Check routing
flyctl logs --app hypo --limit 100 | grep -E "\[ROUTING\]|\[SEND_BINARY\]"

# Check connected devices
curl -s https://hypo.fly.dev/health | jq '.connected_devices'
```

### Log Categories

Each component has its own category for easier filtering:

| Category | Component |
|----------|-----------|
| `LanWebSocketServer` | WebSocket server for LAN connections |
| `TransportManager` | Transport layer management |
| `SyncEngine` | Clipboard sync engine |
| `ClipboardMonitor` | Clipboard change monitoring |
| `ConnectionStatusProber` | Network connectivity checking |
| `HistoryStore` | Clipboard history storage |
| `PairingSession` | Device pairing |
| `IncomingClipboardHandler` | Incoming clipboard data handler |

### Log Levels

- **Debug**: Detailed diagnostic information (verbose)
- **Info**: General informational messages (default)
- **Notice**: Important but not error conditions
- **Warning**: Warning conditions
- **Error**: Error conditions
- **Fault**: Critical errors

### Filtering Examples

```bash
# View pairing-related logs
log show --predicate 'subsystem == "com.hypo.clipboard" && composedMessage CONTAINS "pairing"' --last 1h

# View connection errors
log show --predicate 'subsystem == "com.hypo.clipboard" && (eventType == "errorEvent" || composedMessage CONTAINS "error")' --last 1h

# View WebSocket server activity
log stream --predicate 'subsystem == "com.hypo.clipboard" && category == "LanWebSocketServer"' --level debug

# Export logs to file
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 1h > hypo_logs.txt
```

### Log Privacy

All log messages use `.public` privacy level, meaning they're fully visible in logs. Sensitive data (like device IDs, keys) are logged but can be filtered if needed.

### Log Troubleshooting

**Logs not appearing?**
1. Ensure the app is running
2. Check that you're filtering by the correct subsystem: `com.hypo.clipboard`
3. Enable debug-level logging if looking for debug messages
4. Check Console.app preferences to ensure all log levels are enabled

**Too many logs?**
- Use category filters to narrow down (e.g., `category == "LanWebSocketServer"`)
- Filter by log level (e.g., `eventType == "errorEvent"` for errors only)
- Use time-based filtering with `--last` option

---

## 🔗 Connection Issues

### Problem: "Devices Won't Connect"

**Symptoms**: Apps show "Disconnected" or "Pairing Failed"

**Diagnostic Steps**:

1. **Check Network Configuration**
   ```bash
   # macOS: Check network interface
   ifconfig | grep "inet "
   
   # Android: Settings → Wi-Fi → Advanced → IP address
   ```
   
   Both devices should be on same subnet (e.g., 192.168.1.x)

2. **Test Network Connectivity**
   ```bash
   # From macOS, ping Android device
   ping <android-ip-address>
   
   # Should show successful pings
   ```

3. **Check Firewall Settings**
   
   **macOS Firewall**:
   ```
   System Settings → Network → Firewall → Options
   → Add Hypo to allowed apps
   ```
   
   **Router/Network Firewall**:
   - Ensure mDNS/Bonjour traffic allowed
   - Port range 1024-65535 open for local communication

4. **Check Connection Status**
   ```bash
   # Backend health
   curl -s https://hypo.fly.dev/health | jq '.connected_devices'
   
   # Android WebSocket: See [Android Logs](#android-logs) section above, then filter for WebSocket
   
   # macOS WebSocket
   log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep -E "WebSocket|connected"
   ```

**Solutions**:

**Level 1: Basic Fixes**
- Restart both devices' Wi-Fi
- Move devices closer to router
- Switch to 5GHz Wi-Fi if available

**Level 2: Network Fixes**
- Reset network settings on Android
- Flush DNS on macOS: `sudo dscacheutil -flushcache`
- Try different Wi-Fi network

**Level 3: Advanced Fixes**
- Check for VPN interference (disable temporarily)
- Verify router supports multicast/mDNS
- Use cloud relay as fallback

### Problem: "Connection Keeps Dropping"

**Symptoms**: Devices connect then disconnect frequently

**Diagnostic Steps**:
1. Check Wi-Fi signal strength on both devices
2. Monitor connection logs in both apps
3. Test during different times of day

**Solutions**:
- Update router firmware
- Change Wi-Fi channel (avoid 1, 6, 11 congestion)
- Increase router's multicast rate
- Disable Wi-Fi power saving on devices

### Problem: "Cloud Relay Not Working"

**Symptoms**: LAN sync fails and cloud fallback doesn't activate

**Diagnostic Steps**:
```bash
# Test relay server connectivity
curl -I https://hypo.fly.dev/health

# Should return HTTP 200 OK
```

**Solutions**:
- Check internet connectivity on both devices
- Verify relay server status at status.hypo.app
- Clear app cache and restart
- Re-pair devices to refresh cloud credentials

### Problem: "Item Too Large to Copy" Notification

**Symptoms**: System notification appears when trying to copy large images or files

**Explanation**:
- Hypo enforces a **50MB limit** for copying items to clipboard
- This is separate from the **10MB sync limit** (items can be synced but not copied if too large)
- Prevents excessive disk space usage from temporary files

**Solutions**:
- Use smaller images/files (compress or resize before copying)
- Copy items individually rather than in bulk
- The item will still be synced to other devices (if under 10MB), but won't be copied to local clipboard

**Size Limits** (defined in `SizeConstants` on both platforms):
- **Sync Limit**: 10MB - Maximum size for items synced between devices (raw content before base64 encoding)
- **Copy Limit**: 50MB - Maximum size for copying items to clipboard
- **Transport Frame**: 20MB - Maximum frame payload size (accounts for base64 encoding, JSON structure, and encryption overhead. 10MB images become ~18MB after encoding, so 20MB provides safety margin)
- **Compression Target**: 7.5MB - Target raw size for image compression (75% of sync limit)
- **Max Image Dimension**: 2560px - Images with longest side >2560px are automatically scaled down

### Problem: "Android App Crashes with Large Images/Files in History"

**Symptoms**: App crashes when opening history containing large image or file items

**Root Cause**: Android Room database has a 2MB limit per row in CursorWindow. Large base64-encoded images/files exceed this limit.

**Solution**: ✅ **Fixed in v1.0.3**
- App now uses lazy loading for IMAGE/FILE types
- Content is excluded from list queries and loaded on-demand when copying
- If you still experience crashes, clear app data and restart:
  ```bash
  adb shell pm clear com.hypo.clipboard
  ```

**Diagnostic Steps**:
```bash
# Check for SQLiteBlobTooBigException errors
# Use Android logs from [Android Logs](#android-logs) section above, then filter:
# | grep -E "SQLiteBlobTooBigException|CursorWindow"
```

### Problem: "Disk Space Being Consumed by Temp Files"

**Symptoms**: Disk space gradually decreases, especially after copying large images/files

**Explanation**:
- Hypo creates temporary files when copying images/files to clipboard
- Files are automatically cleaned up after 30 seconds or when clipboard changes
- Periodic cleanup removes files older than 5 minutes

**Solutions**:
- ✅ **Automatic**: Temp files are automatically managed (v1.0.3+)
- Manual cleanup: Clear app cache/data if needed
  - **Android**: Settings → Apps → Hypo → Storage → Clear Cache
  - **macOS**: Files in `~/Library/Caches/` are automatically managed by system

**Verification**:
```bash
# Android: Check temp file count
adb shell ls -la /data/data/com.hypo.clipboard/cache/ | grep hypo_

# macOS: Check temp directory
ls -la ~/Library/Caches/ | grep hypo_
```

### Problem: "Device Not Appearing After Pairing"

**Debugging**:
```bash
# Check pairing completion (filter MIUIInput)
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 10m | grep "PairingCompleted"
# For Android logs, see [Android Logs](#android-logs) section above, then filter for "Key saved for device"
```

**Common Causes**:
- Device ID format mismatch (Must be pure UUID)
- Notification not being posted/received
- HistoryStore not processing notification

---

## ⏱️ Performance Issues

### Problem: "Slow Sync (>5 seconds)"

**Symptoms**: Clipboard takes too long to sync between devices

**Performance Benchmarking**:
```
Target Performance:
- LAN Sync: <500ms (P95)
- Cloud Sync: <3s (P95)
- History Load: <1s
```

**Diagnostic Steps**:

1. **Measure Actual Performance**
   - macOS: Menu Bar → Debug → Performance Monitor
   - Android: Settings → Developer Options → Sync Performance
   
2. **Network Speed Test**
   ```bash
   # Test local network speed between devices
   iperf3 -s  # On one device
   iperf3 -c <target-ip>  # On other device
   ```

3. **Check Resource Usage**
   - macOS: Activity Monitor → Hypo CPU/Memory usage
   - Android: Settings → Battery → App usage details

**Solutions by Cause**:

**Network Bottleneck**:
- Switch to 5GHz Wi-Fi
- Reduce network traffic from other devices
- Use ethernet connection for router
- Update router firmware

**Device Performance**:
- Close other memory-intensive apps
- Restart devices to clear RAM
- Check available storage space
- Update device OS

**App Configuration**:
- Reduce history size (Settings → History → Limit to 100)
- Lower image quality (Settings → Sync → Compress images)
- Disable unnecessary content types

### Problem: "High Battery Usage (Android)"

**Target**: <2% battery drain per day

**Diagnostic Steps**:
```bash
# Check actual battery usage
adb shell dumpsys batterystats | grep hypo

# Check wake locks
adb shell dumpsys power | grep -i wake
```

**Solutions**:

**Optimize Sync Settings**:
- Settings → Sync → Adaptive mode (reduces frequency when idle)
- Disable sync during battery saver mode
- Reduce history retention period

**System-Level Optimization**:
- Ensure Doze mode whitelisting
- Check for background app refresh settings
- Monitor for other apps causing wake locks

### Problem: "High Memory Usage"

**Symptoms**: App using >100MB RAM consistently

**Memory Profiling**:
- macOS: Instruments → Memory profiling
- Android: Android Studio → Memory Profiler

**Solutions**:
- Clear clipboard history regularly
- Reduce image cache size
- Restart app weekly
- Check for memory leaks (report to developers)

---

## 📱 Platform-Specific Issues

### macOS Issues

#### Problem: "Menu Bar Icon Missing"

**Causes**: App crashed or permission denied

**Solutions**:
```bash
# Check if process is running
ps aux | grep Hypo

# Restart from command line
open /Applications/Hypo.app

# Reset preferences if corrupted
defaults delete com.hypo
```

#### Problem: "Clipboard Access Denied"

**Symptoms**: App can't read/write clipboard

**Fix Accessibility Permission**:
```
System Settings → Privacy & Security → Accessibility
→ Remove Hypo → Re-add Hypo → Restart app
```

**Alternative Method**:
```bash
# Reset TCC database (requires SIP disabled)
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "DELETE FROM access WHERE client='com.hypo.HypoApp';"
```

#### Problem: "Notarization Issues"

**Symptoms**: "App cannot be verified" error

**Solutions**:
```bash
# Remove quarantine attribute
sudo xattr -rd com.apple.quarantine /Applications/Hypo.app

# Allow unidentified developer
sudo spctl --master-disable
```

### Android Issues

#### Problem: "App Killed by System"

**Symptoms**: Sync stops working after phone sleeps

**Diagnostic Commands**:
```bash
# Check if app was killed
adb shell dumpsys activity processes | grep hypo

# Check doze whitelist
adb shell dumpsys deviceidle whitelist | grep hypo
```

**Manufacturer-Specific Solutions**:

**Samsung**:
```
Settings → Device care → Battery → Background app limits
→ Never sleeping apps → Add Hypo
```

**Xiaomi (MIUI)**:
```
Settings → Apps → Manage apps → Hypo
→ Other permissions → Display pop-up windows while running in background
→ Autostart → Enable
→ Battery saver → No restrictions
```

**OnePlus**:
```
Settings → Battery → Battery optimization → Advanced optimization
→ Sleep standby optimization → Off for Hypo
```

**Huawei**:
```
Settings → Battery → More battery settings → Protected apps → Hypo
```

#### Problem: "Notification Not Persistent"

**Symptoms**: Sync service notification disappears

**Diagnostic Script**:
```bash
# Use the notification status check script
./scripts/check-notification-status.sh <device_id>
```

**Manual Solutions**:
```bash
# Check notification channel settings
adb shell cmd notification allow_listener com.hypo.clipboard

# Reset notification permissions
adb shell pm revoke com.hypo.clipboard android.permission.POST_NOTIFICATIONS
adb shell pm grant com.hypo.clipboard android.permission.POST_NOTIFICATIONS

# Check notification logs: See [Android Logs](#android-logs) section above, then filter for "Notification|ClipboardSyncService"
```

#### Problem: "ClipboardManager Access Issues"

**Symptoms**: App can't monitor clipboard changes

**API Level Considerations**:
- API 29+: Use OnPrimaryClipChangedListener
- API 28-: Polling required (less efficient)

**Standard Solutions**:
```bash
# Check API level
adb shell getprop ro.build.version.sdk

# Grant clipboard permission (if available)
adb shell pm grant com.hypo.clipboard android.permission.READ_CLIPBOARD
```

**Background Clipboard Access via ADB (Advanced/Experimental)**:

⚠️ **Warning**: These methods are **not officially supported** by Android and may:
- Not work on Android 12+ due to enhanced security
- Pose security risks
- Be reset after app updates or system updates
- Violate some app store policies

**Method 1: AppOps Permission (Android 10-11, may work on 12+)**

**What is AppOps?**

AppOps (Application Operations) is Android's **granular permission control system** that operates at a lower level than standard runtime permissions. It was introduced in Android 4.3 but became more prominent in Android 10+.

**Key Concepts:**
- **Standard Permissions** (`pm grant`): High-level permissions declared in AndroidManifest.xml (e.g., `READ_CLIPBOARD`, `ACCESS_FINE_LOCATION`)
- **AppOps**: Fine-grained operations that control what apps can actually *do* (e.g., `READ_CLIPBOARD`, `SYSTEM_ALERT_WINDOW`, `READ_LOGS`)
- **Why Both Matter**: An app can have a permission granted, but AppOps can still deny the operation

**How Method 1 Works:**

This method uses a **workaround** discovered by clipboard manager apps (like Clip Stack, Kata) that exploits how Android handles certain permissions:

1. **`SYSTEM_ALERT_WINDOW allow`**: 
   - Grants the app permission to draw overlays (floating windows)
   - **Why needed**: Some clipboard access workarounds require overlay permissions
   - **What it does**: Allows the app to display content over other apps

2. **`READ_LOGS allow`**:
   - Grants permission to read system logs
   - **Why needed**: This is the **key workaround** - some clipboard managers discovered that having `READ_LOGS` permission can bypass clipboard restrictions on Android 10-11
   - **How it works**: Android's security model sometimes treats apps with log access as "system-like" and grants them additional privileges
   - **Note**: This is a **hack/workaround**, not an official feature

3. **`force-stop`**:
   - Restarts the app so it picks up the new permission state
   - **Why needed**: Apps cache their permission state; restart forces a refresh

**The Commands Explained:**

```bash
# Package name (debug and release use the same application ID)
PACKAGE="com.hypo.clipboard"

# Grant SYSTEM_ALERT_WINDOW permission (allows overlay)
# This uses AppOps to set the operation mode to "allow"
adb shell appops set $PACKAGE SYSTEM_ALERT_WINDOW allow

# Grant READ_LOGS permission (workaround for clipboard access)
# This uses PackageManager (pm) to grant a standard permission
adb shell pm grant $PACKAGE android.permission.READ_LOGS

# Restart the app to apply changes
# This kills the app process so it restarts with new permissions
adb shell am force-stop $PACKAGE
```

**Why This Might Work:**

On Android 10-11, the combination of `READ_LOGS` + `SYSTEM_ALERT_WINDOW` can sometimes trick the system into allowing background clipboard access. This is likely because:
- Apps with log access are sometimes treated as "debugging/system" apps
- System apps have fewer restrictions
- The overlay permission might be checked alongside clipboard access in some code paths

**Why It Often Doesn't Work on Android 12+:**

Google tightened security in Android 12:
- Stricter enforcement of background clipboard restrictions
- Better separation between permission types
- The workaround was likely patched/blocked

**Method 2: Direct AppOps Clipboard Permission (Android 10-11 only)**

```bash
PACKAGE="com.hypo.clipboard"

# Try to set clipboard read permission directly
adb shell appops set $PACKAGE READ_CLIPBOARD allow
adb shell appops set $PACKAGE android:read_clipboard allow
adb shell appops set $PACKAGE android:read_clipboard_in_background allow

# Restart the app
adb shell am force-stop $PACKAGE
```

**Method 3: Check Current AppOps Status**

```bash
PACKAGE="com.hypo.clipboard"

# Check all AppOps for the package
adb shell dumpsys appops $PACKAGE | grep -i clipboard

# Check specific clipboard operations
adb shell appops get $PACKAGE READ_CLIPBOARD
adb shell appops get $PACKAGE android:read_clipboard
adb shell appops get $PACKAGE android:read_clipboard_in_background
```

**Limitations**:
- **Android 12+**: These methods are increasingly ineffective due to enhanced security
- **System Updates**: Permissions may be reset after Android system updates
- **App Updates**: Some permissions may be reset after app updates
- **Manufacturer ROMs**: MIUI, OneUI, etc. may have additional restrictions

**Recommended Approach**:
Instead of ADB workarounds, use the **official Android method**:
1. Open Hypo app
2. Go to **Settings** → **Permissions**
3. Enable **"Allow clipboard access in background"** toggle (if available on your device)
4. Some devices require: **Settings** → **Apps** → **Hypo** → **Other permissions** → **Clipboard access**

**Alternative Solutions**:
- Keep the app in foreground (use split-screen or picture-in-picture)
- Use the app's foreground service (already implemented)
- Wait for Android to provide official background clipboard API (future Android versions)

#### Problem: "Sync Not Working"

**Debugging**: See [Android Logs](#android-logs) section above, then filter for:
- Clipboard events: `| grep -E "ClipboardListener|onPrimaryClipChanged"`
- Sync targets: `| grep "Target devices now"`
- Transport: `| grep "transport.send()"`
- WebSocket: `| grep -E "WebSocket|Connection"`

**Emulating Clipboard Copy for Testing**:
```bash
# Method 1: Direct clipboard service (requires root on Android 10+)
adb -s $device_id shell "service call clipboard 2 s16 'Test clipboard content'"

# Method 2: Copy keyevent (requires text selection in an app)
adb -s $device_id shell input keyevent 278  # KEYCODE_COPY

# Method 3: Use simulation script (recommended)
python3 scripts/simulate-android-copy.py --text "Test message" --target-device-id <macos_device_id>

# Verify clipboard was set
adb -s $device_id shell service call clipboard 1 | grep -oP "(?<=text=')[^']*"
```

**Common Causes**:
- Clipboard permission not granted
- Sync targets not including device ID
- Encryption key missing
- WebSocket connection not established

---

## 🔒 Security & Encryption Issues

### Problem: "Encryption Key Mismatch"

**Symptoms**: "Decryption failed" errors, garbled content

**Diagnostic Steps**:
1. Check both devices show same key fingerprint
2. Verify system clocks are synchronized
3. Check for pairing corruption

**Debugging**:
```bash
# Check key exists
security find-generic-password -w -s 'com.hypo.clipboard.keys' -a $device_id

# Check decryption errors (filter MIUIInput)
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep -E "Decryption failed|BAD_DECRYPT"
# For Android logs, see [Android Logs](#android-logs) section above, then filter for "BAD_DECRYPT|MissingKey"
```

**Solutions**:

**Re-generate Encryption Keys**:
```
1. Both devices: Settings → Security → Reset encryption keys
2. Re-pair devices using QR code or remote pairing
3. Test sync with simple text
```

**Manual Key Reset** (Advanced):
```bash
# macOS: Clear keychain entries
security delete-generic-password -s "Hypo-DeviceKey" -a "$(whoami)"

# Android: Clear encrypted preferences
adb shell pm clear com.hypo.clipboard
```

### Problem: "Decryption Failures (BAD_DECRYPT)"

**Causes**:
- Key rotation (devices re-paired)
- Wrong key in test script
- Key not found on receiver

**Solution**:

### NSD/Bonjour IP Resolution Issues

**Symptom**: Android discovers macOS at wrong IP address (e.g., discovers `10.0.0.137` when macOS actually has `10.0.0.146`)

**Root Cause**: Android's NSD (Network Service Discovery) may return stale/cached IP addresses from mDNS cache, especially after network changes or when multiple network interfaces are present.

**Verification**:
1. On macOS, check actual IP: `ifconfig | grep "inet "` (should show `10.0.0.146`)
2. On macOS, check Bonjour advertisement: `dns-sd -G v4 dereks-macbook-air-13.local` (should show `10.0.0.146`)
3. Check Android logs: See [Android Logs](#android-logs) section above, then filter for "Service resolved" (may show wrong IP like `10.0.0.137`)

**Solution**:
- NSD cache will eventually expire and refresh (usually within a few minutes)
- Restart Android's NSD discovery by toggling WiFi or restarting the app
- The connection will fail with the wrong IP, but retry logic should eventually reconnect with correct IP
- This is a known Android NSD limitation - the app handles it gracefully with retry logic

**Prevention**: The app logs detailed NSD resolution info (hostname, canonical name, address bytes) to help diagnose these issues.
1. Re-pair devices to get new key
2. Update test script key from keychain (prioritizes keychain over .env)
3. Verify key format matches (64 hex chars)

### Problem: "Certificate Pinning Failures"

**Symptoms**: Cloud sync fails with SSL errors

**Diagnostic Steps**:
```bash
# Test SSL connection to relay
openssl s_client -connect hypo.fly.dev:443 -servername hypo.fly.dev

# Check certificate fingerprint
echo | openssl s_client -connect hypo.fly.dev:443 2>/dev/null | openssl x509 -fingerprint -noout -sha256
```

**Solutions**:
- Update app to latest version (new certificates)
- Check system date/time is correct
- Clear app cache and restart
- Temporarily disable other VPN/proxy connections

---

## 🧪 Testing & Diagnostics

### Automated Test Matrix

```bash
./tests/test-sync-matrix.sh
```

Tests all 8 combinations: Plaintext/Encrypted × Cloud/LAN × macOS/Android

**Prerequisites**:
- macOS with Xcode and Swift
- Android device connected via USB with USB debugging enabled
- OpenJDK 17, Android SDK configured
- `flyctl` installed (for backend deployment)

### Test Script Detection Logic

The `test-sync-matrix.sh` script detects messages by:

1. **Database Query** (Most Reliable)
   - Android: SQLite database check
   - macOS: UserDefaults check

2. **Log Content Search**
   - Searches for `content: <message>` in logs
   - macOS: `log show --predicate 'subsystem == "com.hypo.clipboard"'`
   - Android: See [Android Logs](#android-logs) section above, then filter for "content:"

3. **Handler Success Logs**
   - macOS: `Received clipboard` or `Inserted entry`
   - Android: `Decoded clipboard event`

4. **Reception Indicators**
   - Cloud: `onMessage` calls
   - LAN: `Binary frame received`

### Debugging Scripts

**Recent debugging scripts for common tasks:**

#### SMS-to-Clipboard Testing
```bash
# Simulate SMS reception (emulator only)
./scripts/simulate-sms.sh <device_id> "+1234567890" "Test SMS message"

# Comprehensive SMS testing suite
./scripts/test-sms-clipboard.sh <device_id>
```

#### Notification Status Check
```bash
# Check notification permission and channel status
./scripts/check-notification-status.sh <device_id>
```

#### Clipboard Simulation
```bash
# Simulate Android clipboard copy via LAN WebSocket
python3 scripts/simulate-android-copy.py --text "Test message" --target-device-id <macos_device_id>

# Simulate via cloud relay
python3 scripts/simulate-android-relay.py --text "Test message" --target-device-id <device_id>
```

**Note**: All Android log commands should filter MIUIInput noise. See [Android Logs](#android-logs) section above for the proper filtering commands.

### Manual Testing Procedures

#### Device Pairing

**LAN Auto-Discovery** (Recommended):
1. Ensure both devices on same Wi-Fi
2. Android: Pair → LAN tab → Tap macOS device
3. Verify pairing completes

**QR Code Pairing**:
1. macOS: Settings → Pair new device → QR tab
2. Android: Pair → Scan QR Code

#### Clipboard Sync Testing

**Android → macOS**:
```bash
# Copy text on Android
adb shell input text "Test from Android"

# Monitor logs: See [Android Logs](#android-logs) section above, then filter for "Clipboard|Sync|transport"
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug | grep -E "Received clipboard|content:"
```

**macOS → Android**:
```bash
# Copy text on macOS
echo "Test from macOS" | pbcopy

# Monitor Android logs: See [Android Logs](#android-logs) section above, then filter for "Clipboard|Sync|Received"
```

**Android → macOS (Emulate System Copy via ADB)**:
```bash
# Method 1: Direct clipboard service call (requires root on Android 10+)
# Set clipboard content directly
adb -s $device_id shell "service call clipboard 2 s16 'Test clipboard from adb'"

# Method 2: Using input text + copy keyevent (requires text selection)
# First, select text in an app, then:
adb -s $device_id shell input keyevent 278  # KEYCODE_COPY

# Method 3: Using am broadcast (may require special permissions)
adb -s $device_id shell am broadcast -a android.intent.action.CLIPBOARD_CHANGED

# Method 4: Use Python simulation script (recommended for testing)
python3 scripts/simulate-android-copy.py --text "Test from script" --target-device-id <macos_device_id>

# Monitor macOS logs
log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug | grep -E "Received clipboard|content:"
```

**Reading Clipboard via ADB**:
```bash
# Read clipboard content (may require root)
adb -s $device_id shell service call clipboard 1 | grep -oP "(?<=text=')[^']*"

# Alternative: Check app's clipboard history database
adb -s $device_id shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT preview FROM clipboard_items ORDER BY created_at DESC LIMIT 1;'"
```

**Verification**:
- Message content is logged: `content: <message>`
- Check UI: macOS history (Cmd+Shift+V), Android history screen
- Query logs: `grep -F "content: <message>"`

### Network Diagnostics

**LAN Discovery Testing**:
```bash
# macOS: Test Bonjour service discovery
dns-sd -B _hypo._tcp local.

# Should show discovered Android devices
```

**Port Connectivity**:
```bash
# Test specific port connectivity
nc -v <target-ip> <port>

# Scan for Hypo services
nmap -p 1024-65535 <target-ip>
```

### Performance Profiling

**Sync Latency Measurement**:
1. Enable performance logging in both apps
2. Copy test content multiple times
3. Analyze logs for timing data
4. Compare against benchmarks

**Memory Leak Detection**:
```bash
# macOS: Use Instruments
instruments -t "Leaks" -D leak_trace.trace /Applications/Hypo.app

# Android: Use memory profiler
adb shell am start -n com.hypo.clipboard/.MainActivity --es profiling memory
```

### Crash Report Analysis

**Finding Crash Reports**:
```bash
# Find recent crash reports
find ~/Library/Logs/DiagnosticReports -name "*HypoMenuBar*" -type f -mtime -1

# Extract crash location
cat ~/Library/Logs/DiagnosticReports/HypoMenuBar-*.ips | \
  grep -A 20 '"faultingThread"' | \
  grep -E '"sourceFile"|"sourceLine"'
```

**Common Crash Patterns**:

**Array Index Out of Bounds**:
- Symptom: `EXC_BREAKPOINT` at `Data.subscript.getter`
- Fix: Add guard statements before array access

**Force Unwrap Nil**:
- Symptom: `EXC_BREAKPOINT` with `fatalError` in stack
- Fix: Use optional binding or provide default values

**Threading Issues**:
- Symptom: Crashes in async/await code
- Fix: Ensure `@MainActor` for UI operations, use proper synchronization

### Common Testing Issues

#### Messages Not Detected by Test Script

**Symptoms**: Test script reports FAILED but messages appear in UI

**Debugging**:
```bash
# Check database directly (most reliable)
adb -s $device_id shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT preview FROM clipboard_items WHERE preview LIKE \"%Case X:%\" LIMIT 1;'"

# Check logs by content (filter MIUIInput)
log show --predicate 'subsystem == "com.hypo.clipboard"' --last 5m | grep -F "content: Case X:"
# For Android logs, see [Android Logs](#android-logs) section above, then filter for "content: Case X:"
```

**Solution**: Test script may need time window adjustment or log query refinement

---

## 📞 Getting Help

### Before Contacting Support

**Gather This Information**:
1. **Device Details**:
   - macOS version and hardware model
   - Android version and device model
   - Hypo app version on both devices

2. **Problem Description**:
   - Exact steps to reproduce
   - Error messages (screenshots helpful)
   - When the problem started
   - Frequency (always/sometimes/rare)

3. **Network Environment**:
   - Router model and firmware version
   - ISP and connection type
   - Other devices on network
   - VPN or proxy usage

4. **Log Files**:
   - Recent app logs from both devices
   - System logs if app crashes
   - Network diagnostic output

### Self-Help Resources

**Documentation**:
- [User Guide](USER_GUIDE.md): Complete feature documentation
- [User Guide - Installation Section](USER_GUIDE.md#-installation): Setup instructions
- [Developer Guide](DEVELOPER_GUIDE.md): Technical details

**Community Resources**:
- GitHub Issues: Search existing problems and solutions
- Community Forum: User tips and workarounds
- Wiki: Community-maintained troubleshooting tips

### Contact Support

**GitHub Issues** (Preferred for bugs):
```
https://github.com/hypo-app/hypo/issues/new?template=bug_report.md
```

**Email Support**:
- Technical Issues: support@hypo.app
- Security Concerns: security@hypo.app
- General Questions: hello@hypo.app

**Response Times**:
- Critical bugs: Within 24 hours
- General issues: Within 2 business days
- Feature requests: Acknowledged within 1 week

---

## 🔄 Recovery Procedures

### Complete Reset (Last Resort)

**When Nothing Else Works**:

1. **Backup Important Data**:
   ```bash
   # Export clipboard history (if accessible)
   # Settings → Export → Save clipboard history
   ```

2. **Complete Uninstall**:
   ```bash
   # Follow uninstallation steps in User Guide (Installation section)
   # Remove all preferences and data
   ```

3. **Fresh Installation**:
   ```bash
   # Download latest version
   # Follow installation section in User Guide exactly
   # Don't restore old settings initially
   ```

4. **Gradual Configuration**:
   - Test basic sync before changing settings
   - Re-pair devices from scratch
   - Slowly add back custom configurations

### Factory Reset Simulation

**macOS**:
```bash
# Stop app
killall Hypo

# Remove all Hypo data
rm -rf ~/Library/Preferences/com.hypo.*
rm -rf ~/Library/Application\ Support/Hypo

# Clear keychain
security delete-generic-password -s "Hypo" 2>/dev/null

# Restart app
open /Applications/Hypo.app
```

**Android**:
```bash
# Clear all app data
adb shell pm clear com.hypo.clipboard

# Restart app
adb shell am start -n com.hypo.clipboard/.MainActivity
```

---

## 📚 Quick Reference

### One-liners

**Android** (filter MIUIInput):
```bash
# View recent clipboard content from logs and database
# For Android logs, see [Android Logs](#android-logs) section above, then filter for "content:"
adb -s $device_id shell "sqlite3 /data/data/com.hypo.clipboard/databases/clipboard.db 'SELECT preview FROM clipboard_items ORDER BY created_at DESC LIMIT 5;'"

# Emulate clipboard copy and monitor
adb -s $device_id shell "service call clipboard 2 s16 'Test clipboard'" && \
adb -s $device_id logcat -c && \
# Then use [Android Logs](#android-logs) section above, filter for "ClipboardListener|content:"

# Check SMS-to-clipboard functionality
./scripts/test-sms-clipboard.sh <device_id>

# Check notification status
./scripts/check-notification-status.sh <device_id>
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

### Key Files

- **macOS crash reports**: `~/Library/Logs/DiagnosticReports/HypoMenuBar-*.ips`
- **macOS unified logs**: `log stream --predicate 'subsystem == "com.hypo.clipboard"' --level debug`
- **Android logs**: See [Android Logs](#android-logs) section above (always filter MIUIInput)
- **Pairing flow**: `macos/Sources/HypoApp/Services/TransportManager.swift`
- **Sync flow**: `macos/Sources/HypoApp/Services/HistoryStore.swift`
- **Incoming handler**: `macos/Sources/HypoApp/Services/IncomingClipboardHandler.swift`
- **WebSocket server**: `macos/Sources/HypoApp/Services/LanWebSocketServer.swift`
- **Android handler**: `android/app/src/main/java/com/hypo/clipboard/sync/IncomingClipboardHandler.kt`

### Testing Checklist

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

**Troubleshooting Guide Version**: 2.0  
**Compatible with Hypo**: 0.2.3 Beta  
**Last Updated**: December 30, 2025  
**For Additional Help**: support@hypo.app
