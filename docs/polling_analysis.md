# Polling vs Event-Driven Architecture Analysis

**Date**: December 30, 2025  
**Status**: ✅ Completed Review and Optimizations

## Summary

This document analyzes all polling/repeating logic in the Hypo codebase and identifies what is necessary vs what can be made event-driven. The analysis aligns with `docs/technical.md` which states that the architecture should be "fully event-driven" with "no periodic polling" for discovery and connection triggering.

## Findings

### ✅ Necessary Polling (Cannot be Event-Driven)

#### 1. **macOS ClipboardMonitor** - Timer polling every 0.5 seconds
- **Location**: `macos/Sources/HypoApp/Services/ClipboardMonitor.swift`
- **Reason**: macOS `NSPasteboard` does not provide event-driven change notifications. Polling `changeCount` is the only way to detect clipboard changes.
- **Status**: ✅ Necessary - Platform limitation
- **Documentation**: Already documented in `technical.md` line 344

#### 2. **Android ClipboardListener** - Polling every 2 seconds (Android 10+ workaround)
- **Location**: `android/app/src/main/java/com/hypo/clipboard/sync/ClipboardListener.kt`
- **Reason**: Android 10+ restricts background clipboard access. Polling is a workaround for manual paste detection.
- **Status**: ✅ Necessary - Platform limitation
- **Documentation**: Already documented in code comments

#### 3. **macOS TransportManager.networkMonitorTask** - IP address check every 10 seconds
- **Location**: `macos/Sources/HypoApp/Services/TransportManager.swift:573-586`
- **Reason**: IP address changes (e.g., DHCP renewal) don't always trigger `NWPath.status` changes. Periodic check ensures Bonjour advertising uses correct IP.
- **Status**: ✅ Necessary - Network stack limitation
- **Documentation**: Already documented in `technical.md` line 229

#### 4. **WebSocket Keepalive (Ping/Pong)** - Periodic pings
- **Location**: 
  - Android: `android/app/src/main/java/com/hypo/clipboard/transport/ws/WebSocketTransportClient.kt:1087-1105`
  - macOS: `macos/Sources/HypoApp/Services/LanWebSocketTransport.swift:395-449`
- **Reason**: Required by WebSocket protocol to keep connections alive and detect dead connections.
- **Status**: ✅ Necessary - Protocol requirement
- **Documentation**: Already documented in `technical.md` line 118

#### 5. **Android SettingsViewModel.accessibilityStatusFlow** - Polling every 2 seconds
- **Location**: `android/app/src/main/java/com/hypo/clipboard/ui/settings/SettingsViewModel.kt:44-49`
- **Reason**: Android does not provide event-driven API for accessibility service status changes.
- **Status**: ✅ Necessary - Platform limitation
- **Documentation**: Code comments explain this limitation

### ⚠️ Maintenance Polling (Acceptable but Could Be Optimized)

#### 6. **Peer Pruning** - Periodic cleanup every 1 minute (Android) / 60 seconds (macOS)
- **Location**: 
  - Android: `android/app/src/main/java/com/hypo/clipboard/transport/TransportManager.kt:293-300`
  - macOS: `macos/Sources/HypoApp/Services/TransportManager.swift:467-478`
- **Reason**: Removes stale peers that haven't been seen in 5 minutes. Could be event-driven on peer removal, but periodic cleanup is reasonable for maintenance.
- **Status**: ⚠️ Acceptable - Low frequency maintenance task
- **Recommendation**: Keep as-is (low overhead, ensures cleanup even if events are missed)

#### 7. **Health Check Tasks** - Periodic check every 30 seconds
- **Location**: 
  - Android: `android/app/src/main/java/com/hypo/clipboard/transport/TransportManager.kt:303-323`
  - macOS: `macos/Sources/HypoApp/Services/TransportManager.swift:485-520`
- **Reason**: Safety check to detect if services stopped unexpectedly and restart them. Could potentially be event-driven on service lifecycle events, but periodic check provides redundancy.
- **Status**: ⚠️ Acceptable - Safety mechanism
- **Recommendation**: Keep as-is (provides redundancy, low overhead)

#### 8. **macOS OptimizedHistoryStore.performPeriodicCleanup()** - Cleanup every 5 minutes
- **Location**: `macos/Sources/HypoApp/Services/OptimizedHistoryStore.swift:183-198`
- **Reason**: Removes corrupted indices. Already called on every insert/query, so effectively event-driven in practice.
- **Status**: ⚠️ Acceptable - Already effectively event-driven
- **Recommendation**: Keep as-is (already optimized)

### ❌ Unnecessary Polling (Fixed)

#### 9. **macOS HistoryStore Connection State Fallback Timer** - ❌ REMOVED
- **Location**: `macos/Sources/HypoApp/Services/HistoryStore.swift:319-329` (removed)
- **Reason**: Connection state is already observed via Combine publisher (`connectionStatePublisher`). Fallback timer was redundant.
- **Status**: ✅ **FIXED** - Removed unnecessary polling
- **Change**: Removed 2-second polling timer, connection state updates are now fully event-driven via Combine publisher

#### 10. **macOS HistoryStore Sync Queue Processing** - ✅ MADE EVENT-DRIVEN
- **Location**: `macos/Sources/HypoApp/Services/HistoryStore.swift:644-683` (refactored)
- **Reason**: Previously polled every 5 seconds to retry queued messages. Can be triggered when:
  - Connection becomes available (event-driven)
  - New message is queued (event-driven)
- **Status**: ✅ **FIXED** - Now event-driven using `CheckedContinuation` to wait for events instead of polling
- **Change**: 
  - Removed 5-second polling loop
  - Added `triggerSyncQueueProcessing()` method called when connection state changes or message is queued
  - Uses `withCheckedContinuation` to wait for events instead of polling

### 📊 Android ConnectionStatusProber - Partially Event-Driven

#### 11. **Android ConnectionStatusProber** - Probes every 1 minute
- **Location**: `android/app/src/main/java/com/hypo/clipboard/transport/ConnectionStatusProber.kt:61-68`
- **Reason**: Updates device online status based on discovery and transport info. Connection state is already event-driven (updated via WebSocket callbacks), but device online status needs periodic updates.
- **Status**: ⚠️ Partially necessary - Could potentially be more event-driven
- **Recommendation**: Consider making device online status updates event-driven when:
  - Peer is discovered/lost (already event-driven via NSD callbacks)
  - Transport status changes (could be event-driven via StateFlow)
  - Connection state changes (already event-driven)
- **Note**: The 1-minute interval is reasonable for a background status check, but could be optimized further

## Architecture Compliance

### ✅ Event-Driven Components (As Per Technical.md)

1. **Discovery**: Fully event-driven via OS callbacks (NSD/Bonjour)
2. **Connection Establishment**: Triggered by discovery events or disconnection callbacks
3. **Connection State Updates**: Event-driven via WebSocket callbacks (`onOpen`, `onClosed`, `onFailure`)
4. **UI Updates**: Event-driven via StateFlow/Combine publishers
5. **Sync Queue Processing**: ✅ Now event-driven (was polling)

### ⚠️ Periodic Tasks (Maintenance Only)

1. **Peer Pruning**: Every 1 minute - Low overhead maintenance
2. **Health Checks**: Every 30 seconds - Safety mechanism
3. **IP Address Monitoring**: Every 10 seconds - Network stack limitation
4. **Connection Status Probe**: Every 1 minute - Background status check

### ✅ Platform Limitations (Cannot Be Event-Driven)

1. **macOS Clipboard Monitoring**: Timer polling required (no event API)
2. **Android Clipboard Monitoring**: Polling required for Android 10+ workaround
3. **Accessibility Status**: Polling required (no event API)

## Recommendations

### ✅ Completed Optimizations

1. ✅ Removed macOS HistoryStore connection state fallback timer
2. ✅ Made macOS HistoryStore sync queue processing event-driven

### 🔄 Future Optimizations (Optional)

1. **Android ConnectionStatusProber**: Could make device online status updates more event-driven by observing:
   - `transportManager.peers` StateFlow (already event-driven)
   - `transportManager.lastSuccessfulTransport` StateFlow (already event-driven)
   - `transportManager.cloudConnectionState` Flow (already event-driven)
   - This would eliminate the 1-minute polling interval

2. **Peer Pruning**: Could be triggered on peer removal events, but current 1-minute interval is acceptable (low overhead)

3. **Health Checks**: Could potentially be event-driven on service lifecycle events, but periodic check provides redundancy

## Conclusion

The codebase is now **fully compliant** with the event-driven architecture described in `technical.md`. All unnecessary polling has been removed, and remaining periodic tasks are either:
- **Necessary** due to platform limitations (clipboard monitoring, accessibility status)
- **Acceptable** maintenance tasks with low overhead (pruning, health checks)
- **Required** by protocol/network stack (keepalive, IP monitoring)

The architecture correctly separates:
- **Event-driven** for user-facing functionality (discovery, connections, UI updates)
- **Periodic** for maintenance and platform limitations only

