# Android Clipboard Monitoring Diagnosis

## Issue
Android is unable to pick up clipboard items - clipboard monitoring appears to be inactive.

## Log Analysis

### What's WORKING ✅
1. **Service Started**: ClipboardSyncService onCreate() completed
2. **History Loaded**: 356 items loaded, filtered to 200
3. **LAN Discovery**: NSD service registered and discovering
4. **Cloud Connection**: WebSocket connected to relay, 2 devices visible
5. **Network Monitoring**: Network state change detected

### What's MISSING ❌
1. **NO ClipboardListener logs** - Should see:
   - `📋 ClipboardListener STARTING - registering listener`
   - `✅ ClipboardListener is now ACTIVE`
   - `🔔 onPrimaryClipChanged TRIGGERED!`

2. **NO Clipboard Permission Check logs** - Should see:
   - `🔍 Starting clipboard permission check loop...`
   - `📋 Clipboard permission status: allowed=X`

3. **NO ClipboardAccessibilityService logs** - Should see (for Android 10+):
   - `✅ ClipboardAccessibilityService CONNECTED`

## Root Cause Analysis

The clipboard listener is created in `ClipboardSyncService.onCreate()` (line 112-117) but **never started**.

The call to `ensureClipboardPermissionAndStartListener()` at line 195 should:
1. Check clipboard permissions via `ClipboardAccessChecker.canReadClipboard()`
2. Start the `ClipboardListener` if permission is granted
3. Log the permission status

Since we see ZERO logs from this function, possible causes:

### Hypothesis 1: ClipboardAccessChecker Failure
The `clipboardAccessChecker.canReadClipboard()` call might be:
- Throwing an exception (caught by coroutine exception handler)
- Hanging indefinitely
- Returning false and retrying every 5 seconds (but NOT logging)

### Hypothesis 2: Android 10+ Background Restriction
On Android 10+, clipboard access requires either:
- **App in foreground** (your logs show: `📱 App state: FOREGROUND`)
- **Accessibility Service enabled** (NO logs showing this is connected)

Your device appears to be Android 10+ (based on `Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q` checks in logs).

### Hypothesis 3: Missing Accessibility Service
For background clipboard access on Android 10+, the **ClipboardAccessibilityService** must be enabled in device settings:
- Settings → Accessibility → Hypo → Enable service

## Diagnostic Steps

### Step 1: Check Accessibility Service Status
```bash
adb shell settings get secure enabled_accessibility_services
```
Should include: `com.hypo.clipboard/.service.ClipboardAccessibilityService`

### Step 2: Enable Debug Logging for ClipboardAccessChecker
The `ClipboardAccessChecker` should be logging, but we see nothing. Check if logs are filtered.

### Step 3: Force Filter Android Logs by Tag
```bash
adb logcat -s ClipboardListener:D ClipboardAccessChecker:D ClipboardAccessibilityService:D ClipboardSyncService:D
```

### Step 4: Check AppOps Permission
```bash
adb shell appops get com.hypo.clipboard READ_CLIPBOARD
```

Should return: `allow` (not `deny` or `ignore`)

## Fix Strategy

1. **Enable Accessibility Service** (if not already enabled)
   - Go to Settings → Accessibility
   - Find "Hypo" in the list
   - Enable the accessibility service
   - This grants background clipboard access on Android 10+

2. **Grant Clipboard Permission** (if denied)
   - Settings → Apps → Hypo → Permissions
   - Look for "Clipboard access" or similar
   - Grant permission

3. **Add More Verbose Logging**
   - Add try-catch around `clipboardAccessChecker.canReadClipboard()`
   - Log the exact exception if any
   - Add logs before/after critical calls

## Expected Behavior (When Working)

When app starts, logs should show:
```
🚀 Starting foreground service
✅ Foreground service started successfully
🔍 Starting clipboard permission check loop...
📋 Clipboard permission status: allowed=true, awaiting=false
✅ Clipboard permission granted! Starting ClipboardListener...
📋 ClipboardListener STARTING - registering listener
✅ ClipboardListener is now ACTIVE (listener + polling)
✅ ClipboardListener started successfully
```

When copying text, should see:
```
🔔 onPrimaryClipChanged TRIGGERED!
📋 Clipboard has content, processing...
```

## Session Update (Dec 28, 2025) - Resolved Issues ✅

### 1. Connection Stuck in "Connecting..." UI State
**Problem**: The cloud connection status would hang indefinitely at "Connecting..." especially after network changes.
**Root Cause**: Race conditions in `WebSocketTransportClient` where the `isReconnecting` flag was not reset correctly during cancellations, or was reset prematurely in skip branches, causing deadlock.
**Fixes**:
- Reset `isReconnecting = false` in `disconnect()` and `cancelConnectionJob()`.
- Removed premature `isReconnecting = false` from `ensureConnection()` skip branch.
- Added extensive docstrings to `WebSocketTransportClient` explaining the synchronization logic.

### 2. Clipboard Listener Dying After Service Crash
**Problem**: After several days or system-initiated service restarts, the clipboard listener would stop working until the app was manually reopened.
**Root Cause**: `onCreate()` is not always called when a service is restarted by the system (e.g. from `START_STICKY`). The listener initialization was only in `onCreate()`.
**Fixes**:
- Modified `ClipboardSyncService.onStartCommand()` to call `ensureClipboardListenerIsRunning()`.
- This ensures the listener is checked and restarted every time the service is (re)started.

### 3. Loop Prevention vs. History Re-sync
**Problem**: Distinguishing between items copied from other devices (loop prevention) vs items manually re-synced from history.
**Fixes**: 
- Modified `HistoryScreen.kt` to use `"Hypo Remote"` label for items originating from other devices and `"Hypo Clipboard"` for local items.
- Updated `ClipboardListener` to only skip items with the `"Hypo Remote"` label.

### 4. Background Permission Visibility
**Action**: Documented the requirement for the Accessibility Service on Android 10+ in `TROUBLESHOOTING.md` and added diagnostic commands to verify background clipboard operations.
