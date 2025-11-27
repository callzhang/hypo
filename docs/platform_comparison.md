# Platform Logic Comparison: Android vs macOS

This document compares the implementation differences between Android and macOS for syncing, pairing, and relay functionality.

## 1. Clipboard Syncing Logic

### Android (`SyncCoordinator.kt`)

**Key Features:**
- **Target Selection**: Includes ALL paired devices as targets, not just discovered ones
  - `allPairedTargets = pairedDeviceIds - identity.deviceId` (line 72)
  - Ensures sync works even when devices are offline or on different networks
- **Wait Logic**: Waits up to 10 seconds for targets to be available before broadcasting
  - Handles race condition with peer discovery
  - Checks every 100ms if targets are empty
  - Logs warning if no targets after waiting
- **Broadcasting**: Sends to all targets in `_targets.value` regardless of online status
- **Error Handling**: Logs errors but continues with other targets

**Code Location**: `android/app/src/main/java/com/hypo/clipboard/sync/SyncCoordinator.kt:158-186`

### macOS (`HistoryStore.swift`)

**Key Features:**
- **Target Selection**: Only syncs to devices that are `isOnline` (line 468)
  - `guard device.isOnline else { continue }`
  - Skips offline devices immediately
- **No Wait Logic**: No waiting for targets to become available
  - If no online devices, sync is skipped
- **Broadcasting**: Iterates through `pairedDevices` and only sends to online ones
- **Error Handling**: Logs errors but continues with other devices

**Code Location**: `macos/Sources/HypoApp/Services/HistoryStore.swift:431-482`

### Differences Summary

| Feature | Android | macOS |
|---------|---------|-------|
| Target Selection | All paired devices | Only online devices |
| Wait for Targets | Yes (10 seconds) | No |
| Offline Device Handling | Attempts sync anyway | Skips offline devices |
| Error Recovery | Continues with other targets | Continues with other devices |

**Impact**: Android will attempt to sync to offline devices (which may succeed via cloud relay), while macOS only syncs to devices that are currently online. This could cause macOS to miss sync opportunities when devices are temporarily offline but still reachable via cloud.

---

## 2. Device Pairing Logic

### Android (`LanPairingViewModel.kt`)

**Key Features:**
- **LAN Auto-Discovery**: Special handling for LAN pairing
  - Signature verification can be skipped if `payload.signature == "LAN_AUTO_DISCOVERY"`
  - Relies on TLS fingerprint verification instead
- **Pairing Flow**:
  1. Validate device attributes
  2. Initiate pairing handshake
  3. Create WebSocket connection to peer
  4. Send challenge message
  5. Receive ACK message
  6. Complete handshake and save encryption key
- **Device ID Handling**: Uses device ID from pairing result, falls back to peer attributes or service name
- **Key Verification**: Verifies key was saved after pairing completes

**Code Location**: `android/app/src/main/java/com/hypo/clipboard/pairing/LanPairingViewModel.kt:147-283`

### macOS (`PairingSession.swift`)

**Key Features:**
- **Remote Pairing Only**: Primarily designed for relay-based pairing
  - No special "LAN_AUTO_DISCOVERY" signature handling
  - Always verifies signatures
- **Pairing Flow**:
  1. Start pairing session with configuration
  2. Create pairing code via relay
  3. Poll for challenge from Android
  4. Handle challenge and create ACK
  5. Complete pairing and save device
- **Device ID Handling**: Uses Android device ID from challenge message directly
- **Key Storage**: Stores shared key derived from key agreement

**Code Location**: `macos/Sources/HypoApp/Pairing/PairingSession.swift:191-224`

### Differences Summary

| Feature | Android | macOS |
|---------|---------|-------|
| LAN Auto-Discovery | Yes (skips signature) | No (always verifies) |
| Pairing Method | LAN WebSocket + Relay | Relay-based primarily |
| Signature Verification | Conditional (LAN skips) | Always required |
| Device ID Source | Pairing result → attributes → service name | Challenge message directly |

**Impact**: Android has more flexible pairing options (LAN + Relay), while macOS is primarily relay-based. The signature verification difference could cause issues if LAN pairing is attempted on macOS.

---

## 3. Cloud Relay Transport Logic

### Android (`FallbackSyncTransport.kt`)

**Key Features:**
- **Conditional Dual-Send**: Checks if device is on LAN before deciding transport strategy
  - If device is on LAN: Sends to both LAN and cloud simultaneously
  - If device is not on LAN: Sends to cloud only
- **LAN Detection**: Checks `peer.host != "unknown" && peer.host != "127.0.0.1"`
- **LAN Timeout**: 3-second timeout for LAN transport when sending to both
- **Transport Marking**: Marks device as connected via LAN or cloud after successful send
- **Error Handling**: Requires at least one transport to succeed (throws if both fail)

**Code Location**: `android/app/src/main/java/com/hypo/clipboard/transport/ws/FallbackSyncTransport.kt:24-125`

### macOS (`DualSyncTransport.swift`)

**Key Features:**
- **Always Dual-Send**: Always sends to both LAN and cloud simultaneously (no conditional check)
  - No check if device is actually on LAN
- **LAN Timeout**: 3-second timeout for LAN transport (same as Android)
- **Transport Selection**: Based on user preference (`lanFirst` vs `cloudOnly`)
- **Error Handling**: Requires at least one transport to succeed (throws if both fail)

**Code Location**: `macos/Sources/HypoApp/Services/DualSyncTransport.swift:43-120`

### Differences Summary

| Feature | Android | macOS |
|---------|---------|-------|
| Dual-Send Condition | Only if device on LAN | Always (when `lanFirst`) |
| LAN Detection | Checks peer discovery | No check |
| Transport Selection | Based on discovery | Based on user preference |
| Cloud-Only Fallback | Yes (if not on LAN) | No (always dual when `lanFirst`) |

**Impact**: Android is more efficient (only uses dual-send when needed), while macOS always uses dual-send when `lanFirst` is selected, even if the device is not on LAN. This could cause unnecessary cloud traffic on macOS.

---

## 4. Recommendations

### Syncing Logic
1. **Align Target Selection**: macOS should also attempt to sync to all paired devices, not just online ones
   - This ensures cloud relay can be used even when device appears offline
   - Android's approach is more robust

2. **Add Wait Logic to macOS**: Consider adding a short wait (1-2 seconds) for targets to become available
   - Prevents race conditions with peer discovery
   - Android's 10-second wait might be too long for macOS

### Pairing Logic
1. **Add LAN Auto-Discovery to macOS**: macOS should support LAN pairing with signature skip
   - Enables faster local pairing without relay
   - Matches Android's flexibility

### Relay Logic
1. **Add Conditional Dual-Send to macOS**: macOS should check if device is on LAN before dual-sending
   - Reduces unnecessary cloud traffic
   - Matches Android's efficiency
   - Only use dual-send when device is actually discovered on LAN

2. **Unify Transport Selection**: Both platforms should use the same logic
   - Discovery-based (Android) is more efficient than preference-based (macOS)

---

## 5. Code Locations Reference

### Android
- **Syncing**: `android/app/src/main/java/com/hypo/clipboard/sync/SyncCoordinator.kt`
- **Pairing**: `android/app/src/main/java/com/hypo/clipboard/pairing/LanPairingViewModel.kt`
- **Relay**: `android/app/src/main/java/com/hypo/clipboard/transport/ws/FallbackSyncTransport.kt`

### macOS
- **Syncing**: `macos/Sources/HypoApp/Services/HistoryStore.swift`
- **Pairing**: `macos/Sources/HypoApp/Pairing/PairingSession.swift`
- **Relay**: `macos/Sources/HypoApp/Services/DualSyncTransport.swift`

---

**Last Updated**: 2025-01-21
**Version**: 0.2.2


