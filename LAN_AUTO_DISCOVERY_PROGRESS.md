# LAN Auto-Discovery Pairing - Implementation Progress

## 🎉 Completed (macOS Side)

### 1. WebSocket Server Infrastructure ✅
**File:** `macos/Sources/HypoApp/Services/LanWebSocketServer.swift`
- Created full Network.framework WebSocket server
- Listens on port 7010 (already advertised via Bonjour)
- Handles incoming connections from Android
- Routes messages to pairing vs clipboard handlers
- Delegate pattern for connection lifecycle events

### 2. LAN Transport Implementation ✅
**File:** `macos/Sources/HypoApp/Services/LanSyncTransport.swift`
- Implements `SyncTransport` protocol
- Wraps WebSocket server for clipboard sync
- Sends encrypted clipboard messages to connected clients
- Receives and processes incoming clipboard data

### 3. Transport Provider Update ✅
**File:** `macos/Sources/HypoApp/Services/TransportProvider+Default.swift`
- Replaced `NoopSyncTransport` with `LanSyncTransport`
- Now uses real WebSocket server for LAN communication
- CloudOnly preference ready for future cloud fallback

### 4. Transport Manager Integration ✅
**File:** `macos/Sources/HypoApp/Services/TransportManager.swift`
- Added `webSocketServer` property
- Server starts/stops with LAN services lifecycle
- Implements `LanWebSocketServerDelegate` for callbacks
- Logs pairing challenges and clipboard data received

### 5. App Initialization ✅
**File:** `macos/Sources/HypoApp/App/HypoMenuBarApp.swift`
- Creates `LanWebSocketServer` on app startup
- Initializes `DefaultTransportProvider` with server
- Passes real `TransportManager` to `ClipboardHistoryViewModel`
- No more noop transport!

### 6. Build & Deploy ✅
- macOS app compiles successfully (Release mode)
- Binary deployed to `HypoApp.app`
- App launches correctly

---

## 🚧 Remaining Work

### 7. Android Auto-Discovery UI (In Progress)
**File:** `android/app/src/main/java/com/hypo/clipboard/pairing/PairingScreen.kt`

**What’s Next:**
- The route already defaults to `PairingMode.AutoDiscovery`; polish the UI by surfacing loading/empty states for `LanPairingUiState.Discovering`, error messaging, and a manual refresh/“try again” affordance.
- Render Bonjour metadata that macOS publishes (device name, host, fingerprint) in the cards so users can confirm they are pairing the right Mac.
- Add lightweight `LazyColumn` diffing so the list doesn’t jump when NSD emits updates; consider stable keys based on `serviceName`.
- Ensure the toggle resets state without cancelling discovery on rotations (verify `LanPairingViewModel.reset()` behaviour).

### 8. Android Tap-to-Pair Flow (Pending Implementation)
**File:** `android/app/src/main/java/com/hypo/clipboard/pairing/LanPairingViewModel.kt`

**What’s Needed:**
- Replace the placeholder delay/success path with a real handshake:
  1. Build a QR-equivalent payload from `DiscoveredPeer.attributes` (`device_id`, `pub_key`, `signing_pub_key`, optional `relay_hint`) using `createQrPayloadFromDevice`.
  2. Call `PairingHandshakeManager.initiate(payloadJson)` to obtain the `PairingChallengeMessage` and session state.
  3. Instantiate a real `LanWebSocketClient` (inject a connector instead of `NotImplementedError`) and send the encoded challenge frame.
  4. Await the macOS `PairingAckMessage`, pass it to `PairingHandshakeManager.complete`, and persist the derived key via `DeviceKeyStore`.
- Validate the Bonjour fingerprint before trusting the connection (`TlsWebSocketConfig.fingerprintSha256`).
- Emit transitional states (`Pairing`, `Success`, `Error`) based on the coroutine outcome and resume discovery on failure.

**Integration Points:**
- `LanDiscoveryRepository` (✅ discovery events in place)
- `LanWebSocketClient` / `TlsWebSocketConfig` (needs wiring)
- `PairingHandshakeManager` + `PairingTrustStore` (ensures signature validation)
- `DeviceIdentity` / `DeviceKeyStore` (persist shared key)

### 9. macOS Pairing Approval & ACK Response (Required)
**Files:** `macos/Sources/HypoApp/Services/TransportManager.swift`, `macos/Sources/HypoApp/Pairing/PairingSession.swift`

**What’s Needed:**
- Move beyond logging in `LanWebSocketServerDelegate.server(_:didReceivePairingChallenge:)`; hand challenges to a UI surface (notification/dialog) or auto-accept in debug builds.
- Invoke `PairingSession.handleChallenge` to generate the `PairingAckMessage` and send it back via `LanWebSocketServer.sendPairingAck`.
- Record paired device metadata (so Bonjour TXT values stay in sync) and update any trust-store bookkeeping.
- Optionally gate approvals behind a dedicated ViewModel so the menu bar app can show pending requests.

---

## 🧪 Testing Checklist

### Phase 1: Server Verification
- [ ] Verify WebSocket server listening on port 7010
  ```bash
  lsof -iTCP:7010 -sTCP:LISTEN
  ```
- [ ] Check Bonjour advertisement
  ```bash
  dns-sd -B _hypo._tcp local.
  ```

### Phase 2: Android Discovery
- [ ] Android discovers macOS device
- [ ] Device name displayed correctly
- [ ] Can tap device to initiate pairing

### Phase 3: Pairing Handshake
- [ ] Android builds QR-equivalent payload and sends pairing challenge
- [ ] macOS surfaces challenge UI and issues ACK via `sendPairingAck`
- [ ] Android receives ACK, calls `PairingHandshakeManager.complete`, and persists keys
- [ ] Fingerprint validation rejects mismatched devices

### Phase 4: Clipboard Sync
- [ ] Copy text on Android → appears on macOS
- [ ] Copy text on macOS → appears on Android
- [ ] Verify encryption/decryption works
- [ ] Check message routing through WebSocket

### Phase 5: Automated Coverage
- [ ] Add unit tests for `LanPairingViewModel` state transitions (discovery add/remove, handshake success/failure)
- [ ] Extend `LanDiscoveryRepositoryTest` to cover attribute parsing for pairing metadata
- [ ] Add integration test (instrumented or JVM with fake WebSocket) covering the handshake round-trip
- [ ] Add macOS unit/UI test for handling incoming pairing challenges (if possible with TestHost)

---

## 📝 Key Technical Decisions Made

1. **Network.framework** - Modern, Apple-recommended API for WebSocket server
2. **MainActor isolation** - Server runs on main thread for SwiftUI integration
3. **Delegate pattern** - Clean separation between server and transport logic
4. **Reuse existing models** - `PairingChallengeMessage`, `PairingAckMessage`, `SyncEnvelope`
5. **No QR code required** - LAN devices discover each other automatically via mDNS

---

## 🎯 Next Steps

### Immediate (Required for MVP):
1. Polish Android auto-discovery UI and state handling (2-3 hours)
2. Implement LAN handshake (Android challenge send + macOS ACK response) and persist trust (2-3 hours)
3. Run end-to-end transport + pairing verification (1 hour)

### Future Enhancements:
1. macOS pairing approval dialog
2. Cloud fallback when not on same network
3. Connection status indicators
4. Device trust management UI

---

## 📊 Progress: 67% Complete

- ✅ macOS WebSocket Server (100%)
- ✅ macOS Transport Layer (100%)
- ✅ macOS App Integration (100%)
- ⏳ Android Discovery UI (0%)
- ⏳ Android Pairing Flow (0%)
- ⏳ End-to-End Testing (0%)

**Estimated Time to Complete:** 4-6 hours
