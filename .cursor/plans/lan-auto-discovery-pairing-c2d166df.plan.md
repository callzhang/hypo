<!-- c2d166df-ab66-499e-985d-c118d9180f52 0d22b30b-d8e4-41b6-917b-53228138195a -->
# LAN Pairing and Bidirectional Sync Implementation

## Overview

Finish the LAN auto-discovery pairing flow by wiring the existing pairing handshake models over the LAN WebSocket transport, then verify clipboard sync in both directions without loops while preserving device metadata.

## Phase 1: Android LAN Handshake Completion

### 1.1 Normalize Bonjour Metadata → QR Payload

**Files:** `android/app/src/main/java/com/hypo/clipboard/pairing/LanPairingViewModel.kt`, `android/app/src/main/java/com/hypo/clipboard/transport/lan/LanDiscoveryRepository.kt`

- Ensure `DiscoveredPeer.attributes` surfaces `device_id`, `pub_key`, `signing_pub_key`, optional `relay_hint`, and fingerprint from macOS TXT records.
- Use or refactor `createQrPayloadFromDevice()` so it emits JSON matching the QR schema consumed by `PairingHandshakeManager.initiate`.
- Add null/expiry guards so stale announcements do not start pairing.

### 1.2 WebSocket Connection + Challenge Send

**Files:** `LanPairingViewModel.kt`, `android/app/src/main/java/com/hypo/clipboard/transport/ws/LanWebSocketClient.kt`

- Inject a real `LanWebSocketClient`/`WebSocketConnector` rather than logging a placeholder.
- Configure `TlsWebSocketConfig` with `ws://host:port` and the published fingerprint; reject mismatches.
- After `PairingHandshakeManager.initiate(payloadJson)`, encode the returned `PairingChallengeMessage` and send it over the WebSocket channel.
- Surface `LanPairingUiState` transitions (discovering → pairing → success/error) with retry hooks.

### 1.3 ACK Handling & Trust Persistence

**Files:** `LanPairingViewModel.kt`, `android/app/src/main/java/com/hypo/clipboard/pairing/PairingHandshakeManager.kt`

- Listen for the macOS `PairingAckMessage` via the WebSocket client.
- Pass the ACK JSON into `PairingHandshakeManager.complete` and persist the derived key with `DeviceKeyStore`.
- Update discovery to resume on failure and keep the paired device in memory for immediate sync.

## Phase 2: macOS Challenge Approval & ACK Response

### 2.1 Surface Pairing Requests

**Files:** `macos/Sources/HypoApp/Services/TransportManager.swift`, `macos/Sources/HypoApp/Pairing/PairingViewModel.swift`

- Replace the TODO logging in `LanWebSocketServerDelegate.server(_:didReceivePairingChallenge:)` with a handoff to UI (menu bar sheet, alert, or dev auto-accept).
- Provide context (Android device name, fingerprint) and capture user approval/denial.

### 2.2 Generate and Send ACK

**Files:** `macos/Sources/HypoApp/Pairing/PairingSession.swift`, `macos/Sources/HypoApp/Services/LanWebSocketServer.swift`

- Invoke `PairingSession.handleChallenge` to produce a `PairingAckMessage`.
- Call `LanWebSocketServer.sendPairingAck` with the generated message so Android can complete.
- Persist the shared key/device record via the existing trust/keychain abstractions and refresh Bonjour TXT metadata if needed.

## Phase 3: Verify Clipboard Routing & Loop Prevention

### 3.1 Android Outbound Sync Targets

**Files:** `android/app/src/main/java/com/hypo/clipboard/sync/SyncCoordinator.kt`, `android/app/src/main/java/com/hypo/clipboard/transport/TransportManager.kt`

- Ensure paired device IDs populate the target list so Android broadcasts clipboard events after pairing.
- Add a `skipBroadcast` flag on `ClipboardEvent` (and set it for inbound events) to avoid echo loops.

### 3.2 macOS Receive Path Validation

**Files:** `macos/Sources/HypoApp/Services/LanSyncTransport.swift`, `macos/Sources/HypoApp/Services/SyncEngine.swift`

- Confirm LAN transport surfaces received envelopes to the clipboard pipeline with correct device metadata.
- Add logging/metrics hooks for handshake completion to ease debugging.

## Phase 4: Testing & Verification

### 4.1 Unit & Instrumented Coverage

- `LanPairingViewModel` tests for discovery updates, handshake success/failure, and fingerprint mismatch handling.
- Extend `LanDiscoveryRepositoryTest` to assert attribute parsing for pairing keys.
- macOS unit/UI test for pairing approval flow (mock `LanWebSocketServer` challenge delivery).

### 4.2 End-to-End Manual Runs

- Tap-to-pair over LAN, confirm Android reports success and macOS trust store records the device.
- Clipboard sync Android → macOS and macOS → Android with correct device names.
- Disconnect/reconnect scenarios to ensure pairing state persists.

## Key Files to Modify

- `android/app/src/main/java/com/hypo/clipboard/pairing/LanPairingViewModel.kt`
- `android/app/src/main/java/com/hypo/clipboard/transport/ws/LanWebSocketClient.kt`
- `android/app/src/main/java/com/hypo/clipboard/transport/lan/LanDiscoveryRepository.kt`
- `android/app/src/main/java/com/hypo/clipboard/sync/SyncCoordinator.kt`
- `android/app/src/main/java/com/hypo/clipboard/sync/ClipboardEvent.kt`
- `android/app/src/main/java/com/hypo/clipboard/transport/TransportManager.kt`
- `macos/Sources/HypoApp/Services/TransportManager.swift`
- `macos/Sources/HypoApp/Pairing/PairingSession.swift`
- `macos/Sources/HypoApp/Services/LanWebSocketServer.swift`

## Critical Implementation Details

1. Reuse the QR pairing schema so LAN handshake flows through `PairingHandshakeManager` without introducing new message types.
2. Enforce TLS fingerprint checks even on LAN to prevent spoofing.
3. Avoid clipboard echo loops by tagging inbound events and skipping re-broadcast.
4. Provide clear UI/UX for pairing approvals and error recovery on both platforms.

## To-dos

- [ ] Convert Bonjour attributes into a valid pairing payload and initiate handshake on Android.
- [ ] Send the pairing challenge over a real LAN WebSocket client and handle ACK responses.
- [ ] Implement macOS approval + ACK send flow integrated with `PairingSession`.
- [ ] Persist paired device keys and ensure clipboard sync targets update accordingly.
- [ ] Add loop-prevention flagging in Android sync coordinator.
- [ ] Write unit tests for LAN pairing state machines and attribute parsing.
- [ ] Run end-to-end pairing + clipboard verification and document results.

### To-dos

- [ ] Define pairing message types and payloads in both Android and macOS
- [ ] Implement Android tap-to-pair to send pairing request via WebSocket
- [ ] Implement macOS WebSocket server to receive and process pairing requests
- [ ] Save paired Android device to macOS pairedDevices and exchange keys
- [ ] Fix Android SyncCoordinator to broadcast local clipboard to paired devices
- [ ] Add skipBroadcast flag to prevent infinite sync loops
- [ ] Test end-to-end pairing flow and verify both sides save device info
- [ ] Test clipboard sync in both directions with device name preservation