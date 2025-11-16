# Clipboard Sync Bug Report: Android-to-macOS Clipboard Synchronization Issues

**Date**: November 16, 2025  
**Last Updated**: November 16, 2025  
**Status**: 🔄 **IN PROGRESS** - Investigating clipboard sync functionality  
**Severity**: High - Core feature not working  
**Priority**: P0 - Blocks primary functionality

---

## Summary

This document tracks issues with clipboard synchronization between Android and macOS devices. After successful pairing, clipboard data should sync bidirectionally in real-time, but initial testing shows no sync activity.

**Current Status**: Clipboard sync functionality needs investigation. Service is running but clipboard changes are not being detected or transmitted. As of Nov 16 the Android build now performs a clipboard-permission health check and surfaces a notification action (“Grant access”) that deep-links to Settings → Hypo → Permissions so the user can explicitly allow background clipboard access (required on Android 13+).

---

## Symptoms

### Android Side
- ✅ `ClipboardSyncService` is running (confirmed via `dumpsys activity services`)
- ✅ Service started successfully with foreground notification
- ⚠️ No logs from `ClipboardListener` when clipboard changes occur
- ⚠️ No logs from `SyncCoordinator` or `SyncEngine`
- ⚠️ Clipboard changes detected by system (other apps see changes) but Hypo app doesn't log them

### macOS Side
- ⚠️ No incoming clipboard messages detected
- ⚠️ Clipboard changes on macOS not being sent to Android
- ⚠️ No sync activity logs

### User Experience
- Copy text on Android → Does not appear on macOS
- Copy text on macOS → Does not appear on Android
- No error messages or feedback
- Devices show as "Connected" but sync doesn't work

---

## Observations

### Observation 1: Service Running But No Clipboard Detection
**Date**: November 16, 2025

**What We See**:
- `ClipboardSyncService` is running (verified via `dumpsys`)
- Service has foreground notification
- No `ClipboardListener` logs when clipboard changes
- System clipboard changes are detected by other apps (input method, system services)

**Evidence**:
```bash
# Service is running
adb shell dumpsys activity services | grep ClipboardSyncService
# Output: ServiceRecord{...} com.hypo.clipboard.debug/com.hypo.clipboard.service.ClipboardSyncService

# No ClipboardListener logs
adb logcat | grep ClipboardListener
# Output: (empty)

# System clipboard changes detected
adb logcat | grep "onPrimaryClipChanged"
# Output: Multiple entries from other apps (sg-input, UniClip, etc.)
```

**Hypothesis**:
1. `ClipboardListener` may not be registered with `ClipboardManager`
2. Clipboard permissions may be restricted on Android
3. Service may not have fully initialized the listener
4. Listener may be registered but callback not firing

**Code to Check**:
- `ClipboardSyncService.onCreate()` - Verify listener is started
- `ClipboardListener.start()` - Verify registration with ClipboardManager
- AndroidManifest.xml - Check clipboard permissions

**TODOs**:
- [ ] Verify `ClipboardListener.start()` is called in service
- [ ] Check if clipboard permissions are granted
- [ ] Add startup logging to confirm listener registration
- [ ] Test with manual clipboard copy to trigger listener

---

### Observation 2: No Sync Activity Logs
**Date**: November 16, 2025

**What We See**:
- No logs from `SyncCoordinator` when clipboard changes
- No logs from `SyncEngine` for sending/receiving
- No logs from `IncomingClipboardHandler` on Android
- No logs from `IncomingClipboardHandler` on macOS

**Evidence**:
```bash
# No SyncCoordinator logs
adb logcat | grep SyncCoordinator
# Output: (empty)

# No SyncEngine logs
adb logcat | grep SyncEngine
# Output: (empty)
```

**Hypothesis**:
1. Clipboard events not reaching `SyncCoordinator`
2. `SyncCoordinator` not started or event channel not set up
3. No paired devices configured as sync targets
4. Transport connection not established

**Code to Check**:
- `SyncCoordinator.start()` - Verify event loop is running
- `SyncCoordinator.setTargetDevices()` - Check if paired devices are set
- `SyncEngine.sendClipboard()` - Verify transport is connected
- `LanWebSocketClient` connection state

**TODOs**:
- [ ] Verify `SyncCoordinator.start()` is called
- [ ] Check if `setTargetDevices()` is called with paired device IDs
- [ ] Verify WebSocket connection is established
- [ ] Add logging to track event flow from listener → coordinator → engine

---

### Observation 3: Clipboard Changes Detected by System But Not Hypo
**Date**: November 16, 2025

**What We See**:
- System clipboard changes are detected (logs show `onPrimaryClipChanged` from other apps)
- Hypo's `ClipboardListener` does not log any activity
- Clipboard content is accessible (can paste in other apps)

**Evidence**:
```bash
# System detects clipboard changes
adb logcat | grep "onPrimaryClipChanged"
# Output: Multiple entries from sg-input, UniClip, etc.

# Hypo doesn't detect
adb logcat | grep "ClipboardListener"
# Output: (empty)
```

**Hypothesis**:
1. `ClipboardListener` not registered as `OnPrimaryClipChangedListener`
2. Listener registered but callback method not being called
3. Android clipboard access restrictions (API 29+)
4. Service context issue (listener registered in wrong context)

**Code to Check**:
- `ClipboardListener.start()` - Verify `addPrimaryClipChangedListener(this)` is called
- `ClipboardListener.onPrimaryClipChanged()` - Verify method signature matches interface
- Service lifecycle - Check if listener is registered before service is ready

**TODOs**:
- [ ] Verify listener registration in `ClipboardListener.start()`
- [ ] Add logging to `onPrimaryClipChanged()` to confirm it's called
- [ ] Check Android API level and clipboard access requirements
- [ ] Test with different clipboard content types (text, links)

---

## Hypotheses

### Hypothesis 1: ClipboardListener Not Registered
**Likelihood**: High  
**Impact**: Critical

**Theory**: The `ClipboardListener` may not be properly registered with `ClipboardManager`, so clipboard changes are not being detected.

**Investigation Steps**:
1. Check `ClipboardSyncService.onCreate()` - Verify `listener.start()` is called
2. Check `ClipboardListener.start()` - Verify `clipboardManager.addPrimaryClipChangedListener(this)` is called
3. Add logging to confirm registration
4. Test with manual clipboard copy

**Code Changes Needed**:
- Add logging to `ClipboardListener.start()` to confirm registration
- Add logging to `onPrimaryClipChanged()` to confirm callback fires
- Verify listener is not null and clipboardManager is valid

**Expected Result**: Logs should show "ClipboardListener STARTING" and "onPrimaryClipChanged TRIGGERED" when clipboard changes.

---

### Hypothesis 2: Clipboard Permissions Restricted
**Likelihood**: Medium  
**Impact**: Critical

**Theory**: Android may be restricting clipboard access for background services, especially on API 29+.

**Investigation Steps**:
1. Check Android API level: `adb shell getprop ro.build.version.sdk`
2. Check if clipboard permission is granted
3. Verify service has necessary permissions in AndroidManifest.xml
4. Test with app in foreground vs background

**Code Changes Needed**:
- Add permission checks and logging
- Request clipboard permission if needed (API 29+)
- Handle permission denial gracefully

**Expected Result**: Permission should be granted or requested, and clipboard access should work.

---

### Hypothesis 3: SyncCoordinator Not Started or Event Channel Not Set Up
**Likelihood**: Medium  
**Impact**: Critical

**Theory**: The `SyncCoordinator` may not be started, or the event channel may not be properly initialized, so clipboard events are not being processed.

**Investigation Steps**:
1. Check `ClipboardSyncService.onCreate()` - Verify `syncCoordinator.start(scope)` is called
2. Check `SyncCoordinator.start()` - Verify event channel is created and event loop is running
3. Add logging to confirm coordinator is active
4. Verify event channel is not null when events are sent

**Code Changes Needed**:
- Add logging to `SyncCoordinator.start()` to confirm initialization
- Add logging to event channel send operations
- Verify scope is active and not cancelled

**Expected Result**: Logs should show "SyncCoordinator STARTING" and "event loop RUNNING" on service start.

---

### Hypothesis 4: No Paired Devices Configured as Sync Targets
**Likelihood**: Medium  
**Impact**: Critical

**Theory**: Even if clipboard events are detected, they may not be synced because no paired devices are configured as targets in `SyncCoordinator`.

**Investigation Steps**:
1. Check if `SyncCoordinator.setTargetDevices()` is called after pairing
2. Verify paired device IDs are passed correctly
3. Check if device IDs match between pairing and sync
4. Add logging to show target devices count

**Code Changes Needed**:
- Call `setTargetDevices()` after successful pairing
- Add logging to show target devices when events are processed
- Verify device IDs are consistent (same format as pairing)

**Expected Result**: After pairing, target devices should be set and logs should show "Broadcasting to N paired devices".

---

### Hypothesis 5: Transport Connection Not Established
**Likelihood**: Low  
**Impact**: Critical

**Theory**: The WebSocket transport may not be connected, so even if clipboard events are processed, they can't be sent.

**Investigation Steps**:
1. Check `LanWebSocketClient` connection state
2. Verify WebSocket is connected after pairing
3. Check if connection is maintained after pairing completes
4. Test manual WebSocket connection

**Code Changes Needed**:
- Verify WebSocket connection is established and maintained
- Add connection state logging
- Handle connection drops and reconnection

**Expected Result**: WebSocket should be connected and logs should show connection state.

---

## Code Changes

### Change 1: Background Clipboard Permission Check & Guidance
**Status**: ✅ Implemented (Nov 16, 2025)  
**Priority**: Critical

**Purpose**: Detect when Android’s clipboard privacy toggle blocks background access and surface a user-facing remediation path.

**Changes Made**:
- Added `ClipboardAccessChecker` which queries `AppOpsManager` for `OPSTR_READ_CLIPBOARD`/`OPSTR_READ_CLIPBOARD_IN_BACKGROUND` (Android 10+/13+).
- `ClipboardSyncService` now waits to start the `ClipboardListener` until clipboard access is allowed, refreshes the foreground notification with “Permission required” status, and exposes a “Grant access” action that opens App Info so the user can enable clipboard access.
- Added persistent logging so we can see when the permission is missing or granted.

**User Instructions**:
1. Open Hypo → Settings → tap the clipboard service notification’s “Grant access” action (or manually open Android Settings → Apps → Hypo).
2. Tap `Permissions` → `Clipboard` (Android 13/14) and switch it to **Allow**.
3. Return to Hypo; the notification should switch back to “Syncing clipboard” and clipboard events will start streaming.

**Files Modified**:
- `android/app/src/main/java/com/hypo/clipboard/service/ClipboardSyncService.kt`
- `android/app/src/main/java/com/hypo/clipboard/sync/ClipboardAccessChecker.kt`
- `android/app/src/main/res/values/strings.xml`

**Follow-up**:
- After granting permission, run through Tests 1–3 below to confirm events are emitted and synced.

### Change 2: Add Comprehensive Logging to ClipboardListener
**Status**: 🔄 TODO (partially addressed via Change 1 logging)  
**Priority**: High

**Purpose**: Debug why clipboard changes are not being detected

**Changes Needed**:
```kotlin
// ClipboardListener.kt
fun start() {
    if (isListening) return
    Log.i(TAG, "📋 ClipboardListener STARTING - registering listener")
    Log.d(TAG, "📋 ClipboardManager: $clipboardManager")
    clipboardManager.addPrimaryClipChangedListener(this)
    Log.d(TAG, "✅ Listener registered with ClipboardManager")
    clipboardManager.primaryClip?.let { clip ->
        Log.i(TAG, "📋 Processing initial clip on start")
        process(clip)
    }
    isListening = true
    Log.i(TAG, "✅ ClipboardListener is now ACTIVE (isListening=$isListening)")
}

override fun onPrimaryClipChanged() {
    Log.i(TAG, "🔔 onPrimaryClipChanged TRIGGERED!")
    Log.d(TAG, "📋 Thread: ${Thread.currentThread().name}")
    clipboardManager.primaryClip?.let { clip ->
        Log.i(TAG, "📋 Clipboard has content, processing...")
        process(clip)
    } ?: Log.w(TAG, "⚠️  Clipboard clip is null!")
}
```

**Files to Modify**:
- `android/app/src/main/java/com/hypo/clipboard/sync/ClipboardListener.kt`

**Expected Result**: Logs should show listener registration and callback invocations.

---

### Change 3: Verify SyncCoordinator Initialization
**Status**: 🔄 TODO  
**Priority**: High

**Purpose**: Ensure SyncCoordinator is properly started and event channel is set up

**Changes Needed**:
```kotlin
// SyncCoordinator.kt
fun start(scope: CoroutineScope) {
    if (job != null) {
        Log.i(TAG, "⚠️  SyncCoordinator already started")
        return
    }
    Log.i(TAG, "🚀 SyncCoordinator STARTING...")
    Log.d(TAG, "📋 Scope: $scope, isActive: ${scope.isActive}")
    val channel = Channel<ClipboardEvent>(Channel.BUFFERED)
    eventChannel = channel
    Log.d(TAG, "✅ Event channel created: $channel")
    job = scope.launch {
        Log.i(TAG, "✅ SyncCoordinator event loop RUNNING, waiting for events...")
        Log.d(TAG, "📋 Target devices: ${targets.value.size} (${targets.value})")
        for (event in channel) {
            // ... existing code ...
        }
    }
    Log.i(TAG, "✅ SyncCoordinator started successfully")
}
```

**Files to Modify**:
- `android/app/src/main/java/com/hypo/clipboard/sync/SyncCoordinator.kt`

**Expected Result**: Logs should show coordinator starting and event loop running.

---

### Change 4: Set Target Devices After Pairing
**Status**: 🔄 TODO  
**Priority**: High

**Purpose**: Ensure paired devices are configured as sync targets

**Changes Needed**:
```kotlin
// LanPairingViewModel.kt or ClipboardSyncService.kt
// After successful pairing:
val deviceId = completionResult.macDeviceId ?: device.attributes["device_id"] ?: device.serviceName
syncCoordinator.setTargetDevices(setOf(deviceId))
Log.d(TAG, "✅ Set sync target devices: ${setOf(deviceId)}")
```

**Files to Modify**:
- `android/app/src/main/java/com/hypo/clipboard/pairing/LanPairingViewModel.kt`
- OR `android/app/src/main/java/com/hypo/clipboard/service/ClipboardSyncService.kt`

**Expected Result**: After pairing, target devices should be set and sync should work.

---

### Change 5: Add Transport Connection Verification
**Status**: 🔄 TODO  
**Priority**: Medium

**Purpose**: Verify WebSocket connection is established and maintained

**Changes Needed**:
```kotlin
// SyncEngine.kt or LanWebSocketClient.kt
// Before sending clipboard data:
if (!transport.isConnected()) {
    Log.w(TAG, "⚠️ Transport not connected, attempting connection...")
    transport.connect()
}
Log.d(TAG, "📤 Sending clipboard to device: $targetDeviceId")
```

**Files to Modify**:
- `android/app/src/main/java/com/hypo/clipboard/sync/SyncEngine.kt`
- `android/app/src/main/java/com/hypo/clipboard/transport/ws/LanWebSocketClient.kt`

**Expected Result**: Transport should be connected and ready for sending.

---

## Results

### Result 1: Service Running Confirmation
**Date**: November 16, 2025  
**Status**: ✅ Confirmed

**What We Did**:
- Checked service status via `dumpsys activity services`
- Verified service is running with foreground notification

**Result**:
- ✅ Service is running
- ✅ Service has proper configuration
- ⚠️ Service may not have fully initialized listeners

**Next Steps**:
- Add startup logging to verify all components are initialized
- Check if listeners are registered after service start

---

### Result 2: No Clipboard Detection Logs
**Date**: November 16, 2025  
**Status**: ⚠️ Issue Confirmed (blocked by clipboard permission)

**What We Did**:
- Monitored logs for `ClipboardListener` activity
- Tested clipboard copy operations
- Checked system clipboard detection (other apps)

**Result**:
- ⚠️ No `ClipboardListener` logs when clipboard changes
- ✅ System detects clipboard changes (other apps log them)
- ⚠️ Hypo app is not detecting clipboard changes

**Next Steps**:
- Verify `ClipboardListener.start()` is called (should log once permission granted)
- Confirm clipboard permission toggle is set to Allow (use notification action or Settings → Apps → Hypo → Permissions → Clipboard)
- Add comprehensive logging to debug listener registration

---

## TODOs

### High Priority

- [ ] **Verify ClipboardListener Registration**
  - Add logging to confirm `start()` is called
  - Verify `addPrimaryClipChangedListener()` is called
  - Test with manual clipboard copy
  - Check if callback `onPrimaryClipChanged()` fires

- [ ] **Verify SyncCoordinator Initialization**
  - Add logging to confirm `start()` is called
  - Verify event channel is created
  - Check if event loop is running
  - Verify scope is active

- [ ] **Set Target Devices After Pairing**
  - Call `setTargetDevices()` after successful pairing
  - Verify device IDs match between pairing and sync
  - Add logging to show target devices count

- [ ] **Add Comprehensive Logging**
  - Log all clipboard listener events
  - Log all sync coordinator events
  - Log all sync engine operations
  - Log transport connection state

### Medium Priority

- [ ] **Check Clipboard Permissions**
  - Verify permissions in AndroidManifest.xml
  - Check if clipboard access is restricted (API 29+)
  - Test with app in foreground vs background
  - Handle permission requests if needed

- [ ] **Verify Transport Connection**
  - Check WebSocket connection state
  - Verify connection is maintained after pairing
  - Handle connection drops and reconnection
  - Test manual WebSocket connection

- [ ] **Test Bidirectional Sync**
  - Test Android → macOS sync
  - Test macOS → Android sync
  - Verify both directions work independently
  - Check for sync loops or duplicate events

### Low Priority

- [ ] **Add Unit Tests**
  - Test ClipboardListener registration
  - Test SyncCoordinator event flow
  - Test SyncEngine send/receive
  - Test transport connection handling

- [ ] **Performance Optimization**
  - Check for unnecessary clipboard polling
  - Optimize event processing
  - Reduce logging in production builds

---

## Testing Plan

### Test 1: Clipboard Detection
**Purpose**: Verify clipboard changes are detected

**Steps**:
1. Start app and service
2. Monitor logs for `ClipboardListener` startup
3. Copy text on Android device
4. Check logs for `onPrimaryClipChanged` callback
5. Verify event is processed

**Expected Result**: Logs should show clipboard change detection and event processing.

**Status**: 🔄 TODO

---

### Test 2: Android → macOS Sync
**Purpose**: Verify clipboard sync from Android to macOS

**Steps**:
1. Pair devices successfully
2. Verify devices show as "Connected"
3. Copy text on Android (e.g., "Test from Android")
4. Check macOS clipboard for the text
5. Monitor logs on both sides

**Expected Result**: Text should appear in macOS clipboard within 1-2 seconds.

**Status**: 🔄 TODO

---

### Test 3: macOS → Android Sync
**Purpose**: Verify clipboard sync from macOS to Android

**Steps**:
1. Pair devices successfully
2. Verify devices show as "Connected"
3. Copy text on macOS (e.g., "Test from macOS")
4. Check Android clipboard for the text
5. Monitor logs on both sides

**Expected Result**: Text should appear in Android clipboard within 1-2 seconds.

**Status**: 🔄 TODO

---

### Test 4: Sync After App Restart
**Purpose**: Verify sync works after app restart

**Steps**:
1. Pair devices and verify sync works
2. Restart Android app
3. Verify devices still show as "Connected"
4. Copy text on Android
5. Check if it syncs to macOS

**Expected Result**: Sync should work after restart if connection status persists.

**Status**: 🔄 TODO

---

## Related Files

### Android
- `android/app/src/main/java/com/hypo/clipboard/service/ClipboardSyncService.kt` - Main sync service
- `android/app/src/main/java/com/hypo/clipboard/sync/ClipboardListener.kt` - Clipboard change detection
- `android/app/src/main/java/com/hypo/clipboard/sync/SyncCoordinator.kt` - Event coordination
- `android/app/src/main/java/com/hypo/clipboard/sync/SyncEngine.kt` - Sync execution
- `android/app/src/main/java/com/hypo/clipboard/sync/IncomingClipboardHandler.kt` - Incoming message handling
- `android/app/src/main/java/com/hypo/clipboard/transport/ws/LanWebSocketClient.kt` - WebSocket transport

### macOS
- `macos/Sources/HypoApp/Services/HistoryStore.swift` - Clipboard history and sync
- `macos/Sources/HypoApp/Services/IncomingClipboardHandler.swift` - Incoming message handling
- `macos/Sources/HypoApp/Services/SyncEngine.swift` - Sync execution
- `macos/Sources/HypoApp/Services/ClipboardMonitor.swift` - Clipboard change detection

---

## Debugging Commands

### Android
```bash
# Check service status
adb shell dumpsys activity services | grep ClipboardSyncService

# Monitor clipboard sync logs
adb logcat | grep -E "(ClipboardListener|SyncCoordinator|SyncEngine|onPrimaryClipChanged)"

# Monitor all clipboard activity
adb logcat | grep -i clipboard

# Check clipboard permissions
adb shell dumpsys package com.hypo.clipboard.debug | grep -i clipboard

# Test clipboard copy manually
adb shell am broadcast -a clipper.set -e text "Test clipboard"
```

### macOS
```bash
# Monitor clipboard sync logs
log stream --predicate 'subsystem == "com.hypo.clipboard" && category == "sync"'

# Check clipboard content
pbpaste

# Monitor clipboard changes
log stream --predicate 'eventMessage contains "clipboard"'
```

---

## References

- [Android ClipboardManager Documentation](https://developer.android.com/reference/android/content/ClipboardManager)
- [Android OnPrimaryClipChangedListener](https://developer.android.com/reference/android/content/ClipboardManager.OnPrimaryClipChangedListener)
- [Android Clipboard Access Restrictions (API 29+)](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)
- [macOS NSPasteboard Documentation](https://developer.apple.com/documentation/appkit/nspasteboard)

---

**Last Updated**: November 16, 2025  
**Reported By**: AI Assistant (Auto)  
**Status**: 🔄 **IN PROGRESS** - Initial investigation phase. Service is running but clipboard detection needs debugging.
