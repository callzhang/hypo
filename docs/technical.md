# Technical Specification - Hypo Clipboard Sync

Version: 0.3.8  
Date: December 2, 2025  
Status: Production Beta

---

## Table of Contents
1. [System Architecture](#system-architecture)
2. [Protocol Specification](#protocol-specification)
3. [Security Design](#security-design)
4. [Platform-Specific Implementation](#platform-specific-implementation)
5. [Testing Strategy](#testing-strategy)
6. [Deployment](#deployment)

---

## 1. System Architecture

### 1.1 High-Level Overview
Hypo employs a **peer-to-peer first, cloud fallback** architecture for clipboard synchronization. Devices discover each other via mDNS/Bonjour (macOS) and NSD (Android) on local networks and establish direct encrypted WebSocket connections. When LAN is unavailable, a production cloud relay server (https://hypo.fly.dev) routes end-to-end encrypted payloads.

**Current Status**: Production-ready implementation with:
- Full Android ↔ macOS synchronization
- Device-agnostic pairing (any device can pair with any other device)
- Deployed backend relay (Fly.io)
- LAN auto-discovery with tap-to-pair
- Battery-optimized mobile implementation
- Production-ready security (AES-256-GCM, certificate pinning)

### 1.2 Component Diagram
See `docs/architecture.mermaid` for visual representation.

### 1.3 Technology Decisions

**Decision History**: Technology stack decisions documented below were made during Sprint 1 (October 2025) and have been validated in production.

| Component | Decision | Rationale | Date |
|-----------|----------|-----------|------|
| macOS Client | Swift 6 + SwiftUI | Native performance, modern concurrency | Oct 1, 2025 |
| Android Client | Kotlin 1.9.22 + Compose | Modern UI, coroutines for async | Oct 6, 2025 |
| Backend Relay | Rust + Actix-web | Performance, memory safety, WebSocket support | Oct 1, 2025 |
| Storage - macOS | In-memory + UserDefaults | Lightweight, no Core Data overhead | Oct 1, 2025 |
| Storage - Android | Room | Official Jetpack library, Flow support | Oct 1, 2025 |
| State Storage - Backend | Redis | In-memory speed, ephemeral state | Oct 1, 2025 |
| Encryption | AES-256-GCM | Industry standard, authenticated encryption | Oct 1, 2025 |
| Key Exchange | ECDH | Forward secrecy, QR code compatibility | Oct 1, 2025 |
| Transport | WebSocket | Bi-directional, real-time, wide support | Oct 1, 2025 |

#### macOS Client ✅ Implemented
- **Language**: Swift 6 (strict concurrency, actor isolation)
- **UI Framework**: SwiftUI for menu bar UI, AppKit for NSPasteboard monitoring
- **Storage**: In-memory optimized history store with UserDefaults persistence, encrypted file storage (encryption keys)
  - Keys stored in `~/Library/Application Support/Hypo/` with AES-GCM encryption
  - No Keychain dependency - improves Notarization compatibility
- **Networking**: Network.framework for WebSocket server, URLSession for client connections
- **Crypto**: CryptoKit (AES-256-GCM, Curve25519, Ed25519)
- **Discovery**: Bonjour (NetService) for LAN device discovery and advertising
- **Background**: Launch agent support planned for auto-start

#### Android Client ✅ Implemented
- **Language**: Kotlin 1.9.22 with coroutines and structured concurrency
- **UI**: Jetpack Compose with Material 3 and dynamic color
- **Storage**: Room database (history with indexed queries), EncryptedSharedPreferences (keys)
- **Networking**: OkHttp WebSocket for client, Java-WebSocket library for server
- **Crypto**: Google Tink (AES-256-GCM, HKDF key derivation)
- **Discovery**: NSD (Network Service Discovery) for LAN device discovery and registration
- **Background**: Foreground Service with FOREGROUND_SERVICE_DATA_SYNC permission
- **Battery Optimization**: Screen-state aware connection management (60-80% battery saving)
- **MIUI/HyperOS Adaptation** ✅ Implemented (December 2025): Automatic detection and workarounds for MIUI/HyperOS-specific restrictions
- **SMS Auto-Sync** ✅ Implemented (December 2025): Automatically copies incoming SMS to clipboard for sync to macOS

#### Backend Relay ✅ Deployed
- **Language**: Rust 1.83+
- **Framework**: Actix-web 4.x for WebSocket connections
- **State**: Embedded Redis 7+ for ephemeral connection mapping
- **Deployment**: Docker + Fly.io production (https://hypo.fly.dev)
- **Infrastructure**:
  - 2 machines in iad (Ashburn, VA) region
  - Auto-scaling (min=1, max=3)
  - Health checks on HTTP and TCP
  - Prometheus metrics endpoint
  - Zero-downtime deployments
- **Observability**: Structured logging with tracing crate, Prometheus metrics

---

## 2. Protocol Specification

> **Full Protocol Specification**: See [`docs/protocol.md`](./protocol.md) for the complete protocol specification, including detailed message formats, control messages, error handling, and breaking changes history.

This section provides a high-level overview of the protocol implementation. For detailed message schemas, field definitions, and protocol versioning, refer to the [Protocol Specification](./protocol.md).

### 2.1 Message Format

All messages are JSON-encoded with the following schema (see [`docs/protocol.md`](./protocol.md) §2 for complete schema):

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "type": "text|link|image|file",
  "payload": "base64EncodedData or plaintext",
  "metadata": {
    "size": 1024,
    "mime_type": "image/png",
    "filename": "screenshot.png"
  },
  "device_id": "macos-macbook-pro-2025",
  "sequence": 42,
  "encryption": {
    "algorithm": "AES-256-GCM",
    "nonce": "base64Nonce",
    "tag": "base64AuthTag"
  }
}
```

### 2.2 Content Type Handling

| Type | Encoding | Max Size | Notes |
|------|----------|----------|-------|
| `text` | UTF-8 string | 100KB | No base64 |
| `link` | UTF-8 URL | 2KB | Validated URL format |
| `image` | Base64 PNG/JPEG | 1MB | Auto-compress >1MB |
| `file` | Base64 | 1MB | Include filename in metadata |

### 2.3 WebSocket Lifecycle

> **Reference**: See [`docs/protocol.md`](./protocol.md) §5 for detailed connection flow diagrams and handshake sequences.

#### Connection Handshake
```
Client → Server: WS Upgrade + Device UUID header
Server → Client: 101 Switching Protocols
Client → Server: Auth message (signed with device key)
Server → Client: ACK + session token
```

#### Heartbeat (Keepalive Pings)

**Current Implementation**:
- **Cloud WebSocket**: Sends `PING` every **20 seconds** to prevent Fly.io idle timeout (Fly.io disconnects idle connections after ~60 seconds)
- **LAN WebSocket**: Sends `PING` every **30 minutes** (event-driven reconnection available if disconnected)
- Server responds with `PONG` to each ping
- Connection closed after ping failures (triggers reconnection)

**Battery Impact Analysis**:
- **Cloud (20s interval)**: 
  - **Necessary**: Required to prevent Fly.io from disconnecting idle connections
  - **Impact**: Moderate - prevents device from entering deep sleep, but necessary for connection reliability
  - **Optimization**: Cannot be increased significantly without risking disconnections (Fly.io timeout ~60s)
  - **Estimated battery drain**: ~2-3% per hour when active (based on W3C research: 20s interval causes ~2% drop in 10 minutes)
  
- **LAN (30 minutes interval)**:
  - **Battery-friendly**: Very low impact - only 2 pings per hour
  - **Rationale**: LAN connections are more stable and can rely on event-driven reconnection
  - **Estimated battery drain**: <0.1% per hour (negligible)
  - **Alternative**: Could potentially be removed entirely and rely on connection health checks, but 30-minute ping provides safety net

**Optimization Recommendations**:
1. **Cloud ping (20s)**: Keep as-is - necessary for Fly.io compatibility
2. **LAN ping (30m)**: Consider increasing to 60 minutes or removing entirely if connection health checks are sufficient
3. **Screen-off optimization**: Both ping intervals could be increased when screen is off (already implemented via screen-state monitoring)
4. **Adaptive intervals**: Could implement longer intervals during low activity periods

#### Disconnection
- Graceful: Client sends `DISCONNECT` message
- Ungraceful: Server detects timeout, cleans up Redis state

#### Reconnection & Retry Logic ✅ Unified Event-Driven (December 2025)
- **Unified Reconnection Logic**: Same event-driven reconnection for both cloud and LAN connections (Android and macOS)
  - `onClosed`/`onFailure` callbacks immediately trigger reconnection for both cloud and LAN
  - No separate code paths - unified implementation across all connection types
  - No polling or periodic retries - everything is event-driven
  - State set to `ConnectingCloud`/`ConnectingLan` immediately on disconnection (not after delay)
- **Exponential Backoff**: Applied before connection attempt (not in retry loop) - unified for both cloud and LAN
  - **All Connections**: 1s → 2s → 4s → 8s → 16s → 32s → 64s → 128s (max delay)
  - Backoff calculated based on consecutive failures: `baseDelay * (2^(failures-1))`
  - After 8 consecutive failures, backoff stays at 128s indefinitely (keeps retrying every 128s)
  - Backoff applied before starting connection attempt
  - Failure count tracked at class level, persists across attempts
- **Connection State**: Clear state management with `Disconnected` (renamed from `Idle` for clarity)
  - `Disconnected`: Not connected, ready to connect
  - `ConnectingCloud` / `ConnectingLan`: Connection attempt in progress (shown during backoff)
  - `ConnectedCloud` / `ConnectedLan`: Successfully connected
  - `Error`: Connection error state
- **Connection Loop Architecture**: 
  - Connection loop tries to connect once and exits on failure/disconnect
  - No retry loop in connection loop - reconnection handled by event-driven callbacks
  - Connection maintained as long-lived connection until disconnection event
- **Failure Tracking**: 
  - `consecutiveFailures` counter at class level (persists across attempts)
  - Tracks failures for both cloud and LAN connections (unified tracking)
  - Increments on connection failures (handshake timeout, connection refused, etc.)
  - Resets to 0 on successful connection (in both `onOpen` and after successful handshake)
- **Platform Implementation**:
  - **Android**: `WebSocketTransportClient.onClosed()` triggers `ensureConnection()` for both cloud and LAN
  - **macOS**: `WebSocketTransport.receiveNext()` reconnects for both cloud and LAN with same exponential backoff
  - **No Separate Logic**: Both platforms use unified reconnection code paths
- **Status**: Production-ready and tested

### 2.4 De-duplication Strategy

> **Reference**: See [`docs/protocol.md`](./protocol.md) §6 for the complete de-duplication algorithm.

To prevent clipboard ping-pong loops:
1. Each device maintains a **last sent hash** (SHA-256 of payload)
2. Each device maintains a **last received hash**
3. Before sending, check: `hash(clipboard) != last_sent_hash && hash(clipboard) != last_received_hash`
4. Update `last_sent_hash` after sending
5. Update `last_received_hash` after receiving

### 2.5 Throttling

> **Reference**: See [`docs/protocol.md`](./protocol.md) §7 for the complete throttling algorithm and token bucket implementation.

- **Rate**: Max 1 clipboard update per 300ms per device
- **Burst**: Allow 3 updates in 1s, then throttle
- **Implementation**: Token bucket algorithm

---

## 3. Security Design

### 3.1 Threat Model

**Assets**:
- Clipboard content (potentially sensitive: passwords, auth tokens, PII)
- Device pairing keys

**Threats**:
- Man-in-the-middle on LAN or cloud relay
- Malicious relay server reading clipboard
- Device theft / key extraction
- Replay attacks

**Mitigations**:
- E2E encryption (relay cannot read)
- Certificate pinning for cloud relay
- Encrypted file storage (macOS) / EncryptedSharedPreferences (Android) for key storage
- ECDH for pairing, AES-256-GCM for messages
- Timestamp validation (reject messages >5min old)

### 3.2 Device Pairing Protocol ✅ Implemented

Hypo supports three pairing methods, all device-agnostic (any device can pair with any other device):

#### 1. LAN Auto-Discovery Pairing (Primary Method) ✅ Implemented
**Status**: Fully operational with tap-to-pair UX

1. Both devices on same network advertise via mDNS/Bonjour
2. Each device discovers peers automatically (no QR code needed)
3. User taps discovered device to initiate pairing
4. Automatic ECDH key exchange via WebSocket challenge-response
5. Keys stored securely, pairing complete in < 3 seconds

**Implementation Details** (December 2025):
- **Connection Management**: Pairing creates a dedicated `WebSocketTransportClient` with `config.url` set to the peer's WebSocket URL (e.g., `ws://10.0.0.146:7010`)
- **URL Resolution**: `runConnectionLoop()` allows `config.url` as fallback when `lastKnownUrl` is null, enabling pairing connections to establish without waiting for discovery events
- **Timeout Handling**: `sendRawJson()` properly captures `connectionSignal` atomically to avoid race conditions where the signal might be reassigned during connection establishment
- **Connection Signal**: Uses mutex-protected capture of `connectionSignal` to ensure pairing challenges wait on the correct signal instance

#### 2. QR Code Pairing (LAN) ✅ Implemented
**Device-Agnostic**: Any device can initiate pairing (generate QR) and any device can respond (scan QR). Roles are initiator/responder, not platform-specific.

1. User opens "Pair Device" on initiator device.
2. Initiator fetches/rotates its long-term Ed25519 signing key (stored in platform-specific secure storage) and generates an ephemeral Curve25519 key pair for this attempt.
3. Compose QR payload using fields defined in PRD §6.1 (`ver`, `peer_device_id`, `peer_pub_key`, `peer_signing_pub_key`, `service`, `port`, `relay_hint`, `issued_at`, `expires_at`).
4. Create canonical byte representation: JSON sorted by key, UTF-8 encoded; sign with Ed25519 → `signature` field.
5. Render QR (error correction level M, 256×256) and expose to user until `expires_at`.
6. Responder scans QR, parses JSON, validates schema + TTL window (±5 min) and verifies signature against initiator's long-term public key (distributed during previous pairing or bootstrap update channel).
7. Responder publishes ephemeral Curve25519 key pair, derives shared key = HKDF-SHA256(X25519(peer_pub_key, responder_priv_key), salt = 32 bytes of 0x00, info = "hypo/pairing").
8. Resolve Bonjour service `service` and `port`; connect via TLS WebSocket. If connection fails within 3 s, fallback path triggers (see Remote Pairing).
9. Responder emits `PAIRING_CHALLENGE` message: AES-256-GCM encrypt random 32-byte challenge with `initiator_device_id`, `initiator_device_name`, `initiator_pub_key`, associated data = `initiator_device_id`. Include `nonce`, `ciphertext`, `tag`.
10. Initiator decrypts, ensures nonce monotonicity (LRU cache of last 32 seen), detects responder's platform from device ID prefix. Responds with `PAIRING_ACK` containing `responder_device_id`, `responder_device_name` and detected platform.
11. Both sides persist shared key + peer metadata with platform information; handshake complete. Initiator invalidates QR (even if `expires_at` not reached) and logs telemetry `pairing_lan_success` with anonymized latency.

#### 3. Remote Pairing (via Cloud Relay) ✅ Implemented
**Device-Agnostic**: Any device can create a pairing code (initiator) and any device can claim it (responder).
**Status**: Fully operational via production relay (https://hypo.fly.dev)

1. Initiator obtains pairing code by calling relay `POST /pairing/code` with `{ initiator_device_id, initiator_device_name, initiator_public_key }`. Response includes `{ code, expires_at }`.
2. Relay stores entry in Redis: key `pairing:code:<code>` → JSON { initiator_device_id, initiator_device_name, initiator_public_key, issued_at, expires_at } with TTL 60 s.
3. Responder collects 6-digit code from user, invokes `POST /pairing/claim` with `{ code, responder_device_id, responder_device_name, responder_public_key }`.
4. Relay verifies TTL + rate limits (5 attempts/min/IP). On success, it returns initiator's payload and device metadata.
5. Responder derives shared key using retrieved `initiator_public_key` (HKDF parameters identical to LAN flow) and sends `PAIRING_CHALLENGE` via relay channel with `initiator_device_id`/`initiator_pub_key` fields. Relay treats body as opaque bytes.
6. Initiator replies with `PAIRING_ACK` containing `responder_device_id`/`responder_device_name`; relay forwards to responder. After acknowledgement, relay deletes Redis entry and emits audit log.
7. Failure Cases:
   - Expired code → HTTP 410; Responder prompts for regeneration.
   - Initiator offline → relay retries notify for 30 s; if unacknowledged, entry resets for reuse until TTL.
   - Duplicate device ID claims → HTTP 409 `DEVICE_NOT_PAIRED`; instruct client to restart handshake.

#### 3.2.4 Re-Pairing and Network Change Recovery ✅ Implemented

**Automatic Service Recovery**: Both platforms automatically restart LAN services (Bonjour/NSD advertising and WebSocket servers) when network changes are detected, ensuring devices remain discoverable and connections use updated IP addresses.

**Network Change Detection**:

**macOS**:
- Uses `NWPathMonitor` to detect network path changes
- When network path becomes satisfied, automatically restarts:
  - Bonjour service advertising (updates IP address in mDNS records)
  - WebSocket server (rebinds to new IP address)
- 500ms delay after stopping services allows network stack to settle before restart

**Android**:
- Listens for `WifiManager.NETWORK_STATE_CHANGED_ACTION` broadcasts
- Listens for `ConnectivityManager.NetworkCallback` events (network available, capabilities changed)
- On network change, automatically:
  - Unregisters and re-registers NSD service (updates IP in service records)
  - Restarts WebSocket server (rebinds to new IP address)

**IP Address Updates**:
- **LAN Discovery**: Bonjour/NSD automatically update IP addresses in service records when services restart
- **WebSocket Connections**: 
  - **Event-driven**: Clients discover updated IP addresses through mDNS/NSD discovery events (not periodic polling)
  - **Android**: When peer is discovered via NSD, `lastKnownUrl` is updated and connection is established/updated
  - **macOS**: When peer is discovered via Bonjour, connection is established/updated with new IP
  - No continuous retry loops - connections only happen when peers are discovered or connection disconnects
- **Cloud Relay**: WebSocket connections automatically reconnect on network changes:
  - **Android**: `RelayWebSocketClient.reconnect()` closes existing connection and establishes new one with updated IP
  - **macOS**: `CloudRelayTransport.reconnect()` disconnects and reconnects to use new IP address
  - Backend automatically gets new IP from the WebSocket connection when client reconnects

**Re-Pairing Scenarios**:
- **Network Change**: Devices automatically recover without re-pairing; encryption keys persist across network changes
- **IP Address Change**: Services restart automatically; peers discover new IP via mDNS/NSD
- **Service Loss**: Health check tasks (30s interval) detect and restart services if they stop unexpectedly
- **Manual Re-Pairing**: Users can manually re-pair devices if needed (generates new encryption keys)

**Health Monitoring**:
- **macOS**: Periodic health check (30s) verifies advertising and WebSocket server are active
- **Android**: Periodic health check (30s) verifies NSD registration and WebSocket server are running
- Both platforms automatically restart services if health checks detect failures

**Discovery Architecture**:
- **Fully event-driven**: Peer discovery uses OS-level callbacks (NSD `onServiceFound`/`onServiceLost` on Android, Bonjour callbacks on macOS)
- **No periodic polling**: Discovery events are emitted immediately when peers appear/disappear on the network
- **StateFlow propagation**: Discovery events update `TransportManager.peers` StateFlow, which triggers connection establishment in `SyncCoordinator`
- **Connection triggers**: Connections are only established when:
  1. Peer is discovered (NSD/Bonjour callback → StateFlow update → `startReceiving()`)
  2. Connection disconnects (`onClosed`/`onFailure` → reconnection attempt if URL available)
- **UI updates**: Connection state and device status updates are event-driven via Combine publishers (macOS) and StateFlow (Android)
- **Sync queue processing**: Event-driven - triggered when connection becomes available or new message is queued (no periodic polling)
- **Maintenance tasks**: Periodic tasks (prune stale peers every 1 minute, health checks every 30 seconds) are for maintenance only, not for discovery or connection triggering
- **Platform limitations**: Some polling is necessary due to platform APIs:
  - macOS clipboard monitoring: Timer polling (0.5s) - no event-driven API available
  - Android clipboard monitoring: Polling (2s) for Android 10+ workaround
  - Android accessibility status: Polling (2s) - no event-driven API available
  - IP address monitoring: Periodic check (10s) - IP changes don't always trigger path status changes

**Implementation Details**:
- Network change handlers are non-blocking and run asynchronously
- Service restarts preserve existing encryption keys and paired device metadata
- No user intervention required for network changes or IP updates
- **Cloud Relay Reconnection**:
  - **Android**: `ClipboardSyncService` network callbacks call `RelayWebSocketClient.reconnect()` which:
    1. Closes existing WebSocket connection (if any)
    2. Waits 500ms for connection to close cleanly
    3. Calls `startReceiving()` to establish new connection with updated IP
  - **macOS**: `ConnectionStatusProber` network path monitor calls `CloudRelayTransport.reconnect()` which:
    1. Disconnects existing WebSocket connection
    2. Waits 500ms for connection to close cleanly
    3. Reconnects to establish new connection with updated IP
  - Backend automatically receives new IP address from WebSocket connection when client reconnects
  - Session registration in Redis is updated with new connection ID

### 3.3 Message Encryption

**Algorithm**: AES-256-GCM

**Per-Message Process**:
1. Generate random 12-byte nonce
2. Encrypt payload: `ciphertext, tag = AES-GCM(key, nonce, plaintext, associated_data=device_id)`
3. Include nonce and tag in message
4. Recipient verifies tag before decryption

**Key Rotation**:

**Pairing-Time Key Rotation** ✅ Implemented (November 2025):
- Keys are **always rotated** during pairing requests, regardless of whether the device is new or already paired
- Both initiator and responder generate new ephemeral Curve25519 key pairs for each pairing attempt
- Responder includes ephemeral public key in ACK message
- Initiator re-derives shared key using ephemeral keys on both sides
- Provides forward secrecy and prevents key reuse attacks
- No key reuse across pairing sessions
- **Status**: Production-ready and tested

**Periodic Key Rotation** (Planned):
- Every 30 days, initiate ECDH renegotiation
- Old key valid for 7 days grace period (dual-key decryption)

### 3.4 Certificate Pinning

For cloud relay TLS:
- Hardcode SHA-256 fingerprint of relay server's certificate
- Reject connection if fingerprint mismatch
- Update mechanism: App update with new fingerprint

---

## 4. Platform-Specific Implementation

### 4.1 macOS Client

#### 4.1.1 Project Structure
```
macos/
├── Hypo.xcodeproj
├── HypoApp/
│   ├── App.swift (main entry)
│   ├── Views/
│   │   ├── MenuBarView.swift
│   │   ├── HistoryListView.swift
│   │   ├── SettingsView.swift
│   ├── Models/
│   │   ├── ClipboardItem.swift (Core Data model)
│   │   ├── SyncMessage.swift
│   ├── Services/
│   │   ├── ClipboardMonitor.swift (NSPasteboard polling)
│   │   ├── SyncEngine.swift
│   │   ├── TransportManager.swift (LAN/Cloud)
│   │   ├── CryptoService.swift
│   │   ├── HistoryManager.swift
│   ├── Utilities/
│   │   ├── BonjourBrowser.swift
│   │   ├── WebSocketClient.swift
│   ├── Resources/
│   │   ├── Hypo.xcdatamodeld (Core Data schema)
├── HypoAgent/ (Launch agent target)
└── Tests/
```

#### 4.1.2 NSPasteboard Monitoring
```swift
class ClipboardMonitor {
    private var changeCount: Int = 0
    private var timer: Timer?
    
    func start() {
        changeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }
    
    private func checkForChanges() {
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != changeCount {
            changeCount = currentCount
            handleClipboardChange()
        }
    }
}
```

#### 4.1.3 Menu Bar UI Pattern
```swift
@main
struct HypoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        MenuBarExtra("Hypo", systemImage: "doc.on.clipboard") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}
```

#### 4.1.4 Notification Implementation
```swift
func showNotification(for item: ClipboardItem) {
    let content = UNMutableNotificationContent()
    content.title = "New Clipboard Item"
    content.body = item.previewText
    content.sound = .default
    
    if let image = item.thumbnail {
        let attachment = try? UNNotificationAttachment(
            identifier: "thumbnail",
            url: saveTemporaryImage(image),
            options: nil
        )
        content.attachments = [attachment].compactMap { $0 }
    }
    
    let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
```

#### 4.1.5 LAN Discovery & Advertising

- **BonjourBrowser** (`Utilities/BonjourBrowser.swift`): Actor-backed wrapper around `NetServiceBrowser` that normalizes discovery callbacks into an `AsyncStream<LanDiscoveryEvent>`. Each `DiscoveredPeer` carries resolved host, port, TXT metadata (including `fingerprint_sha256`), and the `lastSeen` timestamp. The browser supports explicit stale pruning (`prunePeers`) and is unit-tested with driver doubles in `BonjourBrowserTests`.
- **TransportManager Integration** (`Services/TransportManager.swift`): The manager now persists LAN sightings via `UserDefaultsLanDiscoveryCache`, auto-starts discovery/advertising on foreground using `ApplicationLifecycleObserver`, and exposes `lanDiscoveredPeers()` plus a diagnostics string for `hypo://debug/lan`. Deep links are surfaced through SwiftUI's `.onOpenURL`, logging active registrations alongside publisher state. A background prune task runs every 60 s (configurable) to drop peers not seen in the last 5 minutes and refresh the cached roster.
- **BonjourPublisher** (`Utilities/BonjourPublisher.swift`): Publishes `_hypo._tcp` with TXT payload `{ version, fingerprint_sha256, protocols }`, tracks the currently advertised endpoint, and restarts advertising when configuration changes (e.g., port update). Diagnostics reuse this metadata so operators can validate fingerprints during support sessions.
- **Network Change Handling** (`Services/TransportManager.swift`): Uses `NWPathMonitor` to detect network path changes. When network becomes available, automatically restarts Bonjour advertising and WebSocket server to update IP addresses. Health check task (30s interval) monitors service state and restarts if services stop unexpectedly.
- **Testing**: `TransportManagerLanTests` validate that discovery events update persisted timestamps, diagnostics include discovered peers, and lifecycle hooks stop advertising on suspend.

#### 4.1.6 LAN WebSocket Client

- **Transport Pipeline**: `LanWebSocketTransport` wraps `URLSessionWebSocketTask` behind the shared `SyncTransport` protocol. The client pins the SHA-256 fingerprint advertised in the Bonjour TXT record, frames JSON envelopes with a 4-byte length prefix via `TransportFrameCodec`, and maintains a long-lived connection for receiving messages.
- **Event-Driven Connection**: Connections are established when peers are discovered via Bonjour. The client maintains a long-lived connection and only reconnects when:
  - Peer IP changes (detected via Bonjour discovery)
  - Connection disconnects (connection lifecycle callbacks trigger immediate reconnection)
- **Unified Reconnection**: Uses same event-driven reconnection logic as cloud connections:
  - Immediate reconnection on disconnect (no polling)
  - Same exponential backoff: 1s → 2s → 4s → ... → 128s (capped)
  - Unified failure tracking and retry logic
- **Timeouts**: Dial attempts cancel after 3 s; once connected the configurable idle watchdog (30 s default) tears down sockets when no LAN traffic is observed.
- **Metrics**: Every connection records handshake duration, first-message latency, idle timeout events, and disconnect reasons which feed into `TelemetryClient` and status reporting.

### 4.2 Android Client

#### 4.2.1 Project Structure
```
android/
├── app/
│   ├── src/main/
│   │   ├── java/com/hypo/clipboard/
│   │   │   ├── MainActivity.kt
│   │   │   ├── ui/
│   │   │   │   ├── home/HomeScreen.kt
│   │   │   │   ├── history/HistoryScreen.kt
│   │   │   │   ├── settings/SettingsScreen.kt
│   │   │   ├── service/
│   │   │   │   ├── ClipboardSyncService.kt (Foreground)
│   │   │   │   ├── ClipboardListener.kt
│   │   │   ├── data/
│   │   │   │   ├── db/ClipboardDatabase.kt
│   │   │   │   ├── repository/ClipboardRepository.kt
│   │   │   ├── sync/
│   │   │   │   ├── SyncEngine.kt
│   │   │   │   ├── CryptoService.kt
│   │   │   ├── transport/
│   │   │   │   ├── TransportManager.kt
│   │   │   │   ├── lan/
│   │   │   │   │   ├── LanDiscoveryRepository.kt
│   │   │   │   │   ├── LanRegistrationManager.kt
│   │   │   │   │   └── LanModels.kt
│   │   │   │   └── ws/
│   │   │   │       ├── WebSocketTransportClient.kt
│   │   │   │       ├── RelayWebSocketClient.kt
│   │   │   │       ├── FallbackSyncTransport.kt
│   │   │   │       ├── LanPeerConnectionManager.kt
│   │   │   │       ├── LanWebSocketServer.kt
│   │   │   │       ├── TransportFrameCodec.kt
│   │   │   │       └── TlsWebSocketConfig.kt
│   │   ├── res/
│   │   ├── AndroidManifest.xml
├── build.gradle.kts
```

#### 4.2.2 Foreground Service
```kotlin
class ClipboardSyncService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = createNotification()
        startForeground(NOTIFICATION_ID, notification)
        
        clipboardManager.addPrimaryClipChangedListener {
            handleClipboardChange()
        }
        
        return START_STICKY
    }
    
    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Hypo Clipboard Sync")
            .setContentText("Syncing clipboard with macOS")
            .setSmallIcon(R.drawable.ic_sync)
            .setOngoing(true)
            .addAction(R.drawable.ic_pause, "Pause", pausePendingIntent)
            .build()
    }
}
```

**Notification Channel Configuration**:
- **Importance**: `IMPORTANCE_DEFAULT` (ensures notification is visible in notification list)
- **Purpose**: Persistent foreground service notification showing latest clipboard item preview
- **Behavior**: Updates automatically when latest clipboard item changes via `observeLatestItem()`
- **Visibility**: Always visible in notification list (not minimized like `IMPORTANCE_LOW`)
- **Sound**: Disabled (`setSound(null, null)`) to avoid intrusive alerts for persistent notification

#### 4.2.3 Room Database Schema
```kotlin
@Entity(tableName = "clipboard_items")
data class ClipboardEntity(
    @PrimaryKey val id: String,
    val type: String,  // ClipboardType enum as string
    val content: String,
    val preview: String,
    val metadata: String, // JSON
    val deviceId: String,
    val deviceName: String?,
    @ColumnInfo(name = "created_at") val createdAt: Instant,
    @ColumnInfo(name = "is_pinned") val isPinned: Boolean,
    @ColumnInfo(name = "is_encrypted") val isEncrypted: Boolean = false,
    @ColumnInfo(name = "transport_origin") val transportOrigin: String? = null  // "LAN" or "CLOUD"
)

@Database(entities = [ClipboardEntity::class], version = 3)
abstract class HypoDatabase : RoomDatabase() {
    abstract fun clipboardDao(): ClipboardDao
}

@Dao
interface ClipboardDao {
    @Query("SELECT * FROM clipboard_items ORDER BY created_at DESC")
    fun observeHistory(limit: Int = 200): Flow<List<ClipboardEntity>>
    
    @Query("SELECT * FROM clipboard_items WHERE preview LIKE '%' || :query || '%' ORDER BY created_at DESC")
    fun search(query: String): Flow<List<ClipboardEntity>>
    
    @Query("SELECT * FROM clipboard_items ORDER BY created_at DESC LIMIT 1")
    suspend fun getLatestEntry(): ClipboardEntity?
    
    @Query("""
        SELECT * FROM clipboard_items 
        WHERE content = :content AND type = :type 
        AND id != (SELECT id FROM clipboard_items ORDER BY created_at DESC LIMIT 1)
        ORDER BY created_at DESC LIMIT 1
    """)
    suspend fun findMatchingEntryInHistory(content: String, type: String): ClipboardEntity?
    
    @Query("UPDATE clipboard_items SET created_at = :newTimestamp WHERE id = :id")
    suspend fun updateTimestamp(id: String, newTimestamp: Instant)
    
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: ClipboardEntity)
    
    @Query("DELETE FROM clipboard_items WHERE id = :id")
    suspend fun delete(id: String)
}
```

**Database Schema Changes (Version 3)**:
- Added `isEncrypted` field to track encryption status of clipboard items
- Added `transportOrigin` field to track whether item was received via LAN or CLOUD transport
- Changed timestamp field from `timestamp: Long` to `createdAt: Instant` for better type safety
- Added helper methods for duplicate detection and timestamp updates:
  - `getLatestEntry()`: Get the most recent clipboard entry
  - `findMatchingEntryInHistory()`: Find matching entry by content and type (excluding latest)
  - `updateTimestamp()`: Update entry timestamp to move it to top of history

**Content Matching**:
- `ClipboardItem.matchesContent()`: Uses SHA-256 hash of content for reliable matching
  - Compares content type, length, and cryptographic hash
  - Ensures duplicate detection works across platforms and transport origins
  - Used to move existing items to top instead of creating duplicates

#### 4.2.4 NSD Discovery & Registration

- **LanDiscoveryRepository** (`transport/lan/LanDiscoveryRepository.kt`): Bridges `NsdManager` callbacks into a `callbackFlow<LanDiscoveryEvent>` while acquiring a scoped multicast lock. Network-change events are injectable (default implementation listens for Wi-Fi broadcasts) so tests can drive deterministic restarts without Robolectric, and the repository guards `discoverServices` restarts with a `Mutex` to avoid overlapping NSD calls.
- **LanRegistrationManager** (`transport/lan/LanRegistrationManager.kt`): Publishes `_hypo._tcp` with TXT payload `{ fingerprint_sha256, version, protocols }`, listens for Wi-Fi connectivity changes, and re-registers using exponential backoff (1 s, 2 s, 4 s… capped at 5 minutes). Backoff attempts reset after successful registration. On network changes, unregisters and re-registers service to update IP address in NSD records.
- **TransportManager** (`transport/TransportManager.kt`): Starts registration/discovery from the foreground service, exposes a `StateFlow` of discovered peers sorted by recency, and supports advertisement updates for port/fingerprint/version changes. **Event-driven discovery**: Collects from `discoverySource.discover().collect { event -> handleEvent(event) }` - reacts to NSD callbacks (`onServiceFound`, `onServiceLost`) immediately, no periodic polling. When peers are discovered, updates `_peers` StateFlow which triggers connection establishment in `SyncCoordinator`. Helpers surface last-seen timestamps and prune stale peers, with a coroutine-driven maintenance loop pruning entries unseen for 5 minutes (default) to keep telemetry/UI aligned with active LAN peers. Provides `restartForNetworkChange()` method to restart both NSD registration and WebSocket server when network changes.
- **Network Change Handling** (`service/ClipboardSyncService.kt`): Registers `ConnectivityManager.NetworkCallback` to detect network availability and capability changes. On network changes, calls `TransportManager.restartForNetworkChange()` to update services with new IP addresses. Health check task (30s interval) monitors service state and restarts if services stop unexpectedly.

**Multicast and LAN Discovery**:

**What is Multicast?**
Multicast is a network communication method that allows one sender to transmit data to multiple receivers simultaneously on a local network. In Hypo, multicast is used for **LAN device discovery** via mDNS (multicast DNS) protocols:
- **macOS**: Uses Bonjour (Apple's implementation of mDNS) to discover and advertise devices
- **Android**: Uses NSD (Network Service Discovery, Android's mDNS implementation) to discover and register services

**How Multicast Works in Hypo**:
1. **Service Advertising**: Each device publishes its presence on the local network using multicast packets
   - macOS: `NetService` publishes `_hypo._tcp` service via Bonjour
   - Android: `NsdManager` registers `_hypo._tcp` service via NSD
2. **Service Discovery**: Devices listen for multicast packets to discover peers
   - macOS: `NetServiceBrowser` searches for `_hypo._tcp` services
   - Android: `NsdManager.discoverServices()` listens for service announcements
3. **Multicast Lock (Android)**: Android requires apps to acquire a `WifiManager.MulticastLock` to keep Wi-Fi multicast functionality active
   - Prevents Android from disabling multicast to save battery
   - Must be held while discovery/advertising is active
   - Released when discovery stops

**MIUI/HyperOS Multicast Throttling**:
- **Issue**: HyperOS (and some MIUI versions) aggressively throttle multicast traffic after ~15 minutes of screen-off time to save battery
- **Impact**: LAN device discovery stops working after the device screen has been off for 15+ minutes
- **Mitigation** (✅ Implemented December 2025):
  1. **Automatic Multicast Lock Refresh**: On MIUI/HyperOS devices, the app automatically refreshes the multicast lock every 10 minutes (before the 15-minute throttle window)
     - `LanRegistrationManager.scheduleMulticastLockRefresh()` releases and re-acquires the lock periodically
  2. **Periodic NSD Restart**: NSD discovery is restarted every 5 minutes on MIUI/HyperOS devices
     - `LanDiscoveryRepository` schedules periodic restarts to recover from throttling
  3. **Device Detection**: `MiuiAdapter` automatically detects MIUI/HyperOS devices and enables these workarounds
- **User Guidance**: Settings screen shows MIUI/HyperOS-specific instructions for battery optimization and autostart settings

#### 4.2.5 Android WebSocket Client

**Multi-Peer Connection Architecture** ✅ Implemented (December 2025):
- **Separate Connections Per Peer**: Maintains persistent `WebSocketTransportClient` connection for each discovered peer (deviceId), mirroring macOS architecture
- **LanPeerConnectionManager**: Manages peer connection lifecycle - creates connections when peers are discovered, removes connections when peers are no longer available
- **Event-Driven Connection Management**: Connections are created/removed based on peer discovery events, not periodic polling
- **Connection Lifecycle**:
  1. NSD discovery event → `LanDiscoveryEvent.Added(peer)` emitted
  2. `TransportManager` updates `peers` StateFlow and calls `lanPeerConnectionManager.syncPeerConnections()`
  3. `LanPeerConnectionManager` creates new `WebSocketTransportClient` for newly discovered peer
  4. Connection maintenance task starts for each peer, maintaining persistent connection with automatic reconnection
  5. Reconnection only occurs when:
     - Peer IP changes (detected via discovery event, connection recreated)
     - Connection disconnects (automatic reconnection with exponential backoff)
     - Peer is no longer discovered (connection removed)
- **Unified Event-Driven Reconnection with Exponential Backoff** ✅ Implemented (December 2025):
  - **Unified Reconnection**: Same reconnection logic for both cloud and LAN connections (no separate code paths)
  - **Immediate Reconnection**: `onClosed`/`onFailure` callbacks immediately trigger `ensureConnection()` for both cloud and LAN
  - **Exponential Backoff**: Applied before connection attempt (not in retry loop) - unified for both connection types
    - **All Connections**: 1s → 2s → 4s → 8s → 16s → 32s → 64s → 128s (capped at 128s)
    - Backoff calculated based on consecutive failures: `baseDelay * (2^(failures-1))` for failures 1-8
    - After 8 consecutive failures, backoff stays at 128s indefinitely (keeps retrying every 128s)
    - Backoff applied in `ensureConnection()` before starting connection attempt
  - **Unified Failure Tracking**: `consecutiveFailures` counter tracks failures for both cloud and LAN
    - Increments on connection failures (handshake timeout, connection refused, etc.)
    - Resets to 0 on successful connection (in both `onOpen` and after successful handshake)
  - **Connection Loop**: `runConnectionLoop()` tries to connect once and exits on failure/disconnect
    - No retry loop in `runConnectionLoop()` - reconnection handled by `ensureConnection()` called from callbacks
    - Connection maintained as long-lived connection until disconnection event
  - **State Management**: State set to `ConnectingCloud`/`ConnectingLan` immediately on disconnection (not after delay)
    - UI shows "Connecting" during backoff, not "Disconnected"
- **Connection State Management** ✅ Updated (December 2025):
  - `Disconnected` (renamed from `Idle` for clarity): Not connected, ready to connect
  - `ConnectingCloud` / `ConnectingLan`: Connection attempt in progress
  - `ConnectedCloud` / `ConnectedLan`: Successfully connected
  - `Error`: Connection error state
- **Discovery Integration**: `LanDiscoveryRepository` uses NSD callbacks (`onServiceFound`, `onServiceLost`) - fully event-driven, no periodic polling
- **StateFlow Observation**: `SyncCoordinator` observes `transportManager.peers.collect { peers -> ... }` to react to discovery events

**Implementation Details**:
- **LanPeerConnectionManager** (`transport/ws/LanPeerConnectionManager.kt`):
  - Maintains `Map<deviceId, WebSocketTransportClient>` - one connection per peer
  - `syncPeerConnections()`: Creates connections for newly discovered peers, removes connections for peers no longer discovered
  - `maintainPeerConnection()`: Simplified - just calls `startReceiving()` once, all reconnection handled by unified `WebSocketTransportClient` logic
  - Reconnection: Uses unified event-driven reconnection with exponential backoff (same as cloud connections)
  - Event-driven: Called from `TransportManager.addPeer()` and `TransportManager.removePeer()` when peers are discovered/removed
- **OkHttp Integration**: Each peer connection uses `OkHttpClient` configured with `CertificatePinner` keyed to the relay fingerprint and LAN fingerprint when available. Coroutine-based `Channel` ensures backpressure while sending messages.
- **URL Resolution**: 
  - LAN connections: Each peer connection uses the peer's discovered IP address (from NSD discovery)
  - Cloud connections: Always uses `config.url` (static cloud relay URL for the relay server)
- **Connection Maintenance**: 
  - Each peer connection maintained independently using unified reconnection logic
  - Same exponential backoff as cloud connections (1s → 2s → 4s → 8s → 16s → 32s → 64s → 128s capped)
  - Event-driven reconnection - immediate retry on disconnect (no polling)
  - Connections removed when peers are no longer discovered
- **FallbackSyncTransport**: Updated to use `LanPeerConnectionManager` instead of single `lanTransport`
  - Sends to specific peer if `targetDeviceId` is set, otherwise broadcasts to all connected peers
  - Still sends to cloud in parallel for maximum reliability
- **Instrumentation**: `WebSocketTransportClient` records handshake and round-trip durations via the injected `TransportMetricsRecorder`. The `TransportMetricsAggregator` can be wired into DI via `BuildConfig.ENABLE_TRANSPORT_METRICS` flag for production metrics collection. The test harness exercises these metrics and produces anonymized samples in `tests/transport/lan_loopback_metrics.json`.
- **Relay Client Abstraction**: `RelayWebSocketClient` reuses the LAN TLS implementation but sources its endpoint, fingerprint, and telemetry headers from Gradle-provided `BuildConfig` constants (`RELAY_WS_URL`, `RELAY_CERT_FINGERPRINT`, `RELAY_ENVIRONMENT`). Unit tests exercise pinning-failure analytics to confirm the cloud environment label is surfaced correctly.

#### 4.2.6 Battery Optimization

Hypo implements intelligent power management to minimize battery drain while maintaining reliable clipboard sync:

**Screen-State Monitoring**
```kotlin
class ScreenStateReceiver(
    private val onScreenOff: () -> Unit,
    private val onScreenOn: () -> Unit
) : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SCREEN_OFF -> onScreenOff()
            Intent.ACTION_SCREEN_ON -> onScreenOn()
        }
    }
}
```

**Lifecycle Management**
- `ClipboardSyncService` registers `ScreenStateReceiver` during `onCreate()`
- On `ACTION_SCREEN_OFF`: 
  - Stops `TransportManager.connectionSupervisor()` to idle WebSocket connections
  - Relies on idle timeouts and the WebSocket watchdog to close unused connections while keeping LAN discovery/advertising active for reachability
  - Clipboard monitoring continues (zero-cost, event-driven)
- On `ACTION_SCREEN_ON`:
  - Restarts `TransportManager` with LAN registration config
  - Reconnects WebSocket connections automatically
  - Resumes LAN peer discovery

#### 4.2.7 Connection Status Probing ✅ Event-Driven (December 2025)

**Event-Driven Architecture**: `ConnectionStatusProber` now uses StateFlow observation instead of periodic polling:
- **Peers Observation**: Observes `transportManager.peers` StateFlow with 500ms debounce to trigger probes when peers are discovered/lost
- **Cloud State Observation**: Observes `cloudWebSocketClient.connectionState` StateFlow with 500ms debounce to trigger probes on connection state changes
- **Safety Timer**: 5-minute fallback timer for debugging builds or as belt-and-suspenders
- **Server Health Check**: Uses `checkServerHealth()` when WebSocket is disconnected but network is available, providing more accurate "cloud reachable" status than binary `isConnected()` check
- **Benefits**: 
  - Eliminates unnecessary 1-minute polling loop
  - Reduces battery usage by only probing when state actually changes
  - More responsive to network and connection changes
  - Better accuracy with server health check for cloud reachability

**Performance Impact**
- Reduces background battery drain by **60-80%** during screen-off periods
- Network activity drops to near-zero when display is off
- Reconnection latency: < 2s after screen-on event
- No user-visible impact on clipboard functionality

**OEM Considerations**
- Compatible with Xiaomi/HyperOS battery restrictions
- Foreground service notification keeps process alive
- Requires battery optimization exemption for best performance
- Documentation includes setup instructions for aggressive OEMs

#### 4.2.8 MIUI/HyperOS Adaptation ✅ Implemented (December 2025)

**Overview**:
MIUI (Xiaomi's Android skin) and HyperOS (Xiaomi's newer OS) implement aggressive battery optimization policies that can interfere with background services and multicast networking. Hypo includes automatic detection and workarounds to ensure reliable operation on these devices.

**Device Detection** (`util/MiuiAdapter.kt`):
- **Detection Methods**:
  1. Manufacturer check: `Build.MANUFACTURER == "Xiaomi"`
  2. System properties: Checks `ro.miui.ui.version.name` and `ro.product.mod_device` via reflection
  3. HyperOS detection: Identifies HyperOS via `ro.product.mod_device` containing "hyper"
- **Version Information**: Retrieves MIUI/HyperOS version string for logging and debugging
- **Battery Optimization Check**: Verifies if battery optimization is disabled for the app

**Multicast Throttling Workarounds**:

**Problem**: HyperOS throttles multicast traffic after ~15 minutes of screen-off time to save battery, causing LAN device discovery to stop working.

**Solutions**:
1. **Automatic Multicast Lock Refresh** (`LanRegistrationManager.kt`):
   - On MIUI/HyperOS devices, automatically refreshes the multicast lock every 10 minutes
   - Refreshes before the 15-minute throttle window to prevent throttling
   - Implementation: `scheduleMulticastLockRefresh()` releases and re-acquires `WifiManager.MulticastLock`
   - Logs refresh events for debugging

2. **Periodic NSD Restart** (`LanDiscoveryRepository.kt`):
   - Restarts NSD discovery every 5 minutes on MIUI/HyperOS devices
   - Helps recover from multicast throttling if it occurs
   - Implementation: Schedules periodic `restartDiscovery()` calls when device is detected as MIUI/HyperOS
   - Only active while discovery is running

**User Guidance**:
- **Settings Screen**: Shows MIUI/HyperOS-specific instructions when device is detected
  - Reminds users to enable "Autostart" in Settings → Apps → Hypo
  - Provides link to battery optimization settings
- **Documentation**: `android/README.md` includes detailed setup instructions for Xiaomi/HyperOS devices

**Implementation Details**:
- **Automatic Activation**: Workarounds are automatically enabled when `MiuiAdapter.isMiuiOrHyperOS()` returns `true`
- **No User Configuration Required**: Detection and workarounds are transparent to users
- **Battery Impact**: Minimal - refresh intervals are conservative (10 minutes for lock, 5 minutes for NSD)
- **Logging**: Device information is logged at service startup for debugging:
  ```
  📱 MIUI/HyperOS Device Detected:
     Manufacturer: Xiaomi
     Model: 2410DPN6CC
     Version: HyperOS 1.0
     Android SDK: 34
     Is HyperOS: true
  ```


**Recommended User Settings** (documented in `android/README.md`):
1. **Battery Optimization**: Settings → Apps → Hypo → Battery saver → No restrictions
2. **Autostart**: Settings → Apps → Manage apps → Hypo → Autostart → Enable
3. **Background Activity**: Settings → Apps → Hypo → Battery usage → Allow background activity
4. **Install via USB** (for development): Settings → Additional Settings → Developer Options → Install via USB

**Testing**:
- Tested on Xiaomi 15 Pro (HyperOS)
- Verified multicast lock refresh prevents throttling
- Confirmed NSD restart recovers from throttling
- Validated device detection accuracy across MIUI and HyperOS versions

#### 4.2.9 SMS Auto-Sync ✅ Implemented (December 2025)

**Overview**:
The SMS auto-sync feature automatically copies incoming SMS messages to the clipboard, which then gets synced to macOS via the existing clipboard sync mechanism. This allows users to receive SMS notifications on macOS without manually copying SMS content.

**Implementation**:
- **SmsReceiver** (`service/SmsReceiver.kt`): BroadcastReceiver that listens for `SMS_RECEIVED` broadcasts
  - Extracts SMS content and sender number from broadcast intent
  - Formats SMS as: `From: <sender>\n<message>`
  - Automatically copies formatted SMS to clipboard using `ClipboardManager.setPrimaryClip()`
  - Existing `ClipboardListener` automatically detects clipboard change and syncs to macOS
- **Permission Management**:
  - **Runtime Permission Request**: On Android 6.0+ (API 23+), `RECEIVE_SMS` permission must be granted at runtime
  - **Automatic Request**: `MainActivity` automatically requests permission on app launch if not granted
  - **UI Integration**: Settings screen shows SMS permission status and provides button to grant permission
  - **Status Monitoring**: `SettingsViewModel` periodically checks permission status (every 2 seconds) and updates UI

**Android Version Limitations**:
- **Android 9 and Below (API 28-)**: ✅ Fully supported - SMS receiver works without restrictions
- **Android 10+ (API 29+)**: ⚠️ Restricted - SMS access may be limited
  - May require app to be set as default SMS app (not recommended - breaks SMS functionality)
  - If auto-copy fails, users can manually copy SMS and sync will work normally
  - SecurityException is caught and logged, app continues to function

**User Experience**:
1. User grants SMS permission (automatic on first launch, or via Settings screen)
2. When SMS is received, content is automatically copied to clipboard
3. Clipboard sync service detects change within ~100ms
4. SMS content is synced to macOS within ~1 second
5. User can see SMS in macOS clipboard history

**Privacy & Security**:
- SMS content is handled the same way as any clipboard content
- Encrypted end-to-end when syncing to macOS (AES-256-GCM)
- No SMS content is stored permanently (only in clipboard history)
- Users can clear clipboard history to remove SMS content
- Permission can be revoked at any time via Android Settings

**Settings UI**:
- Shows SMS permission status (Granted/Not Granted)
- Provides "Grant Permission" button if permission not granted
- Displays note about Android 10+ restrictions
- Status updates automatically when permission is granted/revoked

**Testing**:
- Tested on Android 9 and below: SMS auto-copy works reliably
- Tested on Android 10+: Gracefully handles restrictions, manual copy still works
- Verified clipboard sync works for SMS content
- Confirmed permission request flow works correctly

#### 4.2.6 macOS Cloud Relay Transport ✅ Implemented

- **Production Configuration**: `CloudRelayDefaults.production()` provides a `CloudRelayConfiguration` with the Fly.io production endpoint (`wss://hypo.fly.dev/ws`), the current bundle version header, and the production SHA-256 certificate fingerprint.
- **Transport Wrapper**: `CloudRelayTransport` composes the existing `LanWebSocketTransport` while forcing the environment label to `cloud`, giving analytics and metrics a consistent view of fallback events without duplicating handshake logic.
- **Automatic Failover**: 3-second LAN timeout before automatic cloud fallback
- **Certificate Pinning**: SHA-256 fingerprint verification prevents MITM attacks
- **Testing**: Comprehensive unit tests with stub `URLSessionWebSocketTask`s verify send-path delegation and configuration wiring

### 4.4 Platform Implementation Comparison

This section compares the implementation details between Android and macOS clients to highlight alignment and differences.

#### 4.4.1 Clipboard Syncing Logic

**Current Status**: ✅ **Aligned** - Both platforms now implement best-effort sync to all paired devices with message queuing.

**Android** (`SyncCoordinator.kt`):
- **Target Selection**: Includes ALL paired devices as targets, not just discovered ones
  - `allPairedTargets = pairedDeviceIds - identity.deviceId`
  - Ensures sync works even when devices are offline or on different networks
- **Wait Logic**: Waits up to 10 seconds for targets to be available before broadcasting
  - Handles race condition with peer discovery
  - Checks every 100ms if targets are empty
- **Broadcasting**: Sends to all targets regardless of online status
- **Error Handling**: Logs errors but continues with other targets

**macOS** (`HistoryStore.swift`):
- **Target Selection**: Syncs to ALL paired devices with encryption keys (best-effort practice)
  - Checks for encryption keys before queuing messages (`KeychainDeviceKeyProvider.hasKey()`)
  - Skips devices without keys to avoid unnecessary retries
  - No `isOnline` check - attempts sync regardless of device status
  - Transport layer handles routing (LAN/cloud) correctly
- **Message Queue**: Implements queue with 1-minute expiration window
  - Messages queued for each device with a valid encryption key
  - Each device gets its own `QueuedSyncMessage` with specific `targetDeviceId`
  - Messages processed independently - failures for one device don't block others
  - Retries every 5 seconds until sent or expired
  - Prevents message loss during app startup and network transitions
- **Queue Processing**: Event-driven queue processor with proper lifecycle management
  - `defer` block ensures `queueProcessingTask` is reset to `nil` when processor exits
  - Prevents race condition where finished tasks prevent new processors from starting
  - Continuation-based waiting for connection state changes or new messages
  - Summary logging tracks success/failure counts across all devices
- **Broadcasting**: Iterates through all `pairedDevices`, filters by key availability, and queues messages for each
- **Error Handling**: Logs errors but continues with other devices
  - Devices without keys are skipped with warning logs
  - Failed sends are kept in queue for retry
  - Processing continues for all devices regardless of individual failures
- **Backend Error Responses**: When target device is not connected, backend sends error response to sender
  - Error message type: `"error"` with payload containing `code`, `message`, and `target_device_id`
  - Android client receives error and shows toast notification: "Failed to sync to {deviceName}: incorrect device_id ({deviceId})"
  - Enables user feedback when sync fails due to device not being connected
- **Duplicate Handling**: When a received clipboard item matches an existing item in history, the existing item is moved to the top instead of being discarded
  - Ensures cross-platform user actions (e.g., clicking an item in Android that originated from macOS) are reflected in macOS history
  - Preserves pin state when moving items to top
  - Updates timestamp to reflect the user's active use of the item

**Key Differences**:
| Feature | Android | macOS |
|---------|---------|-------|
| Target Selection | All paired devices ✅ | All paired devices with keys ✅ |
| Key Validation | Not checked before send | Checked before queuing (skips devices without keys) |
| Wait/Queue Strategy | 10-second wait | 1-minute queue with retries |
| Offline Device Handling | Attempts sync anyway ✅ | Attempts sync anyway ✅ |
| Message Persistence | In-memory wait | Persistent queue with expiration |
| Independent Processing | Yes ✅ | Yes ✅ (each device processed separately) |

**Impact**: Both platforms now follow best-effort practice, attempting sync to all paired devices regardless of online status. macOS uses a more robust queue-based approach with key validation, while Android uses a simpler wait strategy. Both platforms process devices independently, ensuring failures for one device don't block others.

#### 4.4.2 Transport Strategy

**Current Status**: ✅ **Aligned** - Both platforms always dual-send (LAN + cloud simultaneously) with separate connections per peer.

**Android** (`FallbackSyncTransport.kt` + `LanPeerConnectionManager.kt` + `LanWebSocketServer.kt`):
- **Always Dual-Send**: Always sends to both LAN (all peers) and cloud simultaneously
  - No conditional check - always attempts both transports
  - Best-effort practice for maximum reliability
- **Multi-Peer Support**: Maintains separate `WebSocketTransportClient` connection for each discovered peer
  - `LanPeerConnectionManager` manages peer connection lifecycle
  - `LanWebSocketServer` handles incoming LAN connections (Android can act as server)
  - Sends to specific peer if `targetDeviceId` is set, otherwise broadcasts to all connected peers
  - Can communicate with all peers simultaneously (no connection switching)
- **LAN Timeout**: 3-second timeout for LAN transport
- **Transport Marking**: Marks device as connected via LAN or cloud after successful send
- **Error Handling**: Requires at least one transport to succeed (throws if both fail)
- **Payload Size**: Increased from 256KB to 10MB to support larger clipboard content (images, files)

**macOS** (`DualSyncTransport.swift` + `LanSyncTransport.swift`):
- **Always Dual-Send**: Always sends to both LAN (all peers) and cloud simultaneously
  - No conditional check - always attempts both transports
  - Best-effort practice for maximum reliability
- **Multi-Peer Support**: Maintains separate `WebSocketTransport` connection for each discovered peer
  - `LanSyncTransport` manages peer connection lifecycle via `clientTransports[deviceId]`
  - Sends to all discovered peers simultaneously
  - Can communicate with all peers simultaneously (no connection switching)
- **LAN Timeout**: 3-second timeout for LAN transport (same as Android)
- **Error Handling**: Requires at least one transport to succeed (throws if both fail)

**Key Differences**:
| Feature | Android | macOS |
|---------|---------|-------|
| Dual-Send Strategy | Always ✅ | Always ✅ |
| LAN Timeout | 3 seconds | 3 seconds |
| Transport Selection | Always dual | Always dual |
| Peer Connection Architecture | Separate connection per peer ✅ | Separate connection per peer ✅ |
| Connection Manager | `LanPeerConnectionManager` | `LanSyncTransport` |

**Impact**: Both platforms now implement identical dual-send strategy with separate connections per peer, ensuring maximum reliability and simultaneous communication with all peers.

#### 4.4.3 Device Pairing Logic

**Current Status**: ⚠️ **Partially Aligned** - Android supports LAN auto-discovery pairing, macOS primarily uses relay-based pairing.

**Android** (`LanPairingViewModel.kt`):
- **LAN Auto-Discovery**: Special handling for LAN pairing
  - Signature verification can be skipped if `payload.signature == "LAN_AUTO_DISCOVERY"`
  - Relies on TLS fingerprint verification instead
- **Pairing Methods**: Supports both LAN WebSocket and Relay-based pairing
- **Device ID Handling**: Uses device ID from pairing result, falls back to peer attributes or service name

**macOS** (`PairingSession.swift`):
- **Remote Pairing**: Primarily designed for relay-based pairing
  - No special "LAN_AUTO_DISCOVERY" signature handling
  - Always verifies signatures
- **Pairing Methods**: Relay-based primarily
- **Device ID Handling**: Uses Android device ID from challenge message directly

**Key Differences**:
| Feature | Android | macOS |
|---------|---------|-------|
| LAN Auto-Discovery | Yes (skips signature) | No (always verifies) |
| Pairing Method | LAN WebSocket + Relay | Relay-based primarily |
| Signature Verification | Conditional (LAN skips) | Always required |

**Impact**: Android has more flexible pairing options (LAN + Relay), while macOS is primarily relay-based. LAN auto-discovery pairing is a convenience feature that could be added to macOS in the future.

#### 4.4.4 Summary

**Aligned Features** ✅:
1. **Sync Target Selection**: Both sync to all paired devices (best-effort)
2. **Dual-Send Strategy**: Both always send to LAN and cloud simultaneously
3. **Error Handling**: Both continue with other targets/devices on error

**Platform-Specific Optimizations**:
1. **macOS**: Queue-based message persistence (1-minute window) - more robust for network transitions
2. **Android**: Simple wait strategy (10 seconds) - lighter weight for mobile

**Future Enhancements**:
1. **macOS LAN Auto-Discovery**: Add LAN pairing with TLS fingerprint verification (same as Android)
2. **Unified Pairing Flow**: Consider standardizing pairing methods across platforms

### 4.3 Backend Relay

#### 4.3.1 Project Structure
```
backend/
├── src/
│   ├── main.rs
│   ├── handlers/
│   │   ├── websocket.rs
│   │   ├── health.rs
│   ├── models/
│   │   ├── message.rs
│   │   ├── device.rs
│   ├── services/
│   │   ├── router.rs
│   │   ├── redis_client.rs
│   ├── utils/
│   │   ├── rate_limit.rs
├── Cargo.toml
├── Dockerfile
```

#### 4.3.2 WebSocket Handler
```rust
async fn websocket_handler(
    req: HttpRequest,
    stream: web::Payload,
    redis: web::Data<RedisClient>,
) -> Result<HttpResponse, Error> {
    let device_id = extract_device_id(&req)?;
    
    ws::start(ClipboardWebSocket::new(device_id, redis.get_ref().clone()), &req, stream)
}

impl StreamHandler<Result<ws::Message, ws::ProtocolError>> for ClipboardWebSocket {
    fn handle(&mut self, msg: Result<ws::Message, ws::ProtocolError>, ctx: &mut Self::Context) {
        match msg {
            Ok(ws::Message::Text(text)) => {
                if let Ok(clip_msg) = serde_json::from_str::<ClipboardMessage>(&text) {
                    self.route_message(clip_msg);
                }
            }
            Ok(ws::Message::Ping(msg)) => ctx.pong(&msg),
            _ => {}
        }
    }
}
```

#### 4.3.3 Redis State Management
```rust
// Key: device:<uuid> -> Value: connection_id
// Key: conn:<connection_id> -> Value: device_uuid
// TTL: 1 hour

async fn register_device(redis: &Redis, device_id: &str, conn_id: &str) {
    redis.set_ex(format!("device:{}", device_id), conn_id, 3600).await;
    redis.set_ex(format!("conn:{}", conn_id), device_id, 3600).await;
}

async fn route_to_device(redis: &Redis, device_id: &str, message: &str) -> Option<String> {
    redis.get(format!("device:{}", device_id)).await
}
```

#### 4.3.4 Cloud Relay Enhancements

- **Production Deployment**: Relay deployed to Fly.io production. `backend/fly.toml` defines auto-scaling (min=1, max=3) and embedded Redis in container. Secrets (`RELAY_HMAC_KEY`, `CERT_FINGERPRINT`) managed through Fly secrets and rotated monthly. The production relay is available at `https://hypo.fly.dev` with WebSocket endpoint `wss://hypo.fly.dev/ws`.
- **Pairing Support**: Adds `/pairing/code` and `/pairing/claim` endpoints secured with HMAC header `X-Hypo-Signature`. Pairing codes stored in Redis with 60 s TTL and replay protection counters. Protocol is device-agnostic: any device can act as initiator (code creator) or responder (code claimer).
- **Client Fallback Orchestration**: Android uses `FallbackSyncTransport` and macOS uses `DualSyncTransport` to always attempt both LAN and cloud sends in parallel, with LAN attempts bounded by a 3 s timeout. Fallback reason codes (`lan_timeout`, `lan_rejected`, `lan_not_supported`) are still surfaced via the shared `TransportAnalytics` stream for telemetry dashboards.
- **Certificate Pinning**: `backend/scripts/cert_fingerprint.sh` extracts SHA-256 fingerprints from the Fly-issued certificate chain. Clients load the pinned hash and record a `transport_pinning_failure` analytics event when TLS verification fails (environment + host metadata captured).
- **Observability**: Structured logs via `tracing` include connection IDs, transport path (`lan`, `relay`), latency histograms exported to Prometheus, and fallback reason counts. Alerts trigger when relay error rate exceeds 1% over 5 min or when pinning failures exceed 10/min.

---

## 5. Testing Strategy

### 5.1 Unit Tests
- **macOS**: XCTest for services, models
- **Android**: JUnit + MockK for repositories, services
  - Test naming aligned with production code: `WebSocketTransportClientTest` (renamed from `LanWebSocketClientTest`)
  - Connection state enums match runtime: `ConnectionState.Disconnected` (renamed from `Idle`)
  - **Settings Screen Connection Status**: Uses `cloudConnectionState` to track cloud server status separately from LAN connections
    - LAN device status determined by discovery status and active transport (not global connection state)
    - Cloud device status determined by cloud server connection state and active transport
    - Fixes issue where LAN-connected devices were incorrectly shown as disconnected
- **Backend**: Rust `#[cfg(test)]` modules

### 5.2 Integration Tests
- **E2E Encryption**: Encrypt on one platform, decrypt on other
- **Transport Fallback**: Simulate LAN unavailable, verify cloud fallback
- **Cloud Telemetry**: Assert fallback reason codes propagate to the analytics sinks and that cloud handshake/first-payload metrics are written to `tests/transport/cloud_metrics.json`.
- **LAN Discovery Harness**: Simulate multicast announcements and ensure discovery emits add/remove events and prunes stale entries after 10 s.
- **Latency Instrumentation**: Assert the `TransportMetricsRecorder` hooks on macOS (`LanWebSocketTransport`) and Android (`WebSocketTransportClient` via `TransportMetricsAggregator`) emit handshake and round-trip samples and persist the aggregation to `tests/transport/lan_loopback_metrics.json`.
- **De-duplication**: Send same content twice, verify single sync

### 5.3 Manual Test Cases
1. Copy text on Android → verify appears on macOS within 1s
2. Copy image on macOS → verify appears on Android
3. Disconnect Wi-Fi → verify cloud fallback works
4. Toggle airplane mode to confirm automatic LAN re-registration and fallback recovery
5. Device pairing via QR code
6. Run LAN latency capture script and validate telemetry upload (see `docs/testing/lan_manual.md`)
7. Clipboard history search
8. Notification display with preview

### 5.4 Performance Tests
- Latency: Measure P50/P95/P99 for LAN and cloud; publish results in README.md performance section
- Throughput: Send 100 clips in 10s, measure success rate
- Memory: Profile both apps under sustained load
- Availability: Track transport error rates (<0.5% target) using relay Prometheus metrics

---

## 6. Deployment

### 6.1 macOS Distribution
- **Development**: Direct .app distribution
- **Future**: Mac App Store (requires sandboxing adjustments)
- **Auto-update**: Sparkle framework

### 6.2 Android Distribution
- **Development**: APK sideload
- **Future**: Google Play Store
- **Minimum API**: 26 (Android 8.0) for foreground service stability

### 6.3 Backend Deployment ✅ Production
- **Platform**: Fly.io production (https://hypo.fly.dev)
- **Status**: Live with 36+ days uptime, serving production traffic
- **Configuration**: `backend/fly.toml` defines regions (`iad`), auto-scaling (min=1, max=3), TCP and HTTP health checks, embedded Redis in container
- **Infrastructure**:
  - 2 machines in iad (Ashburn, VA, USA) region
  - Zero-downtime deployments
  - Health checks: `/health` endpoint (HTTP 200, 50ms response time)
  - Metrics: Prometheus format at `/metrics`
  - WebSocket endpoint: `wss://hypo.fly.dev/ws`
- **Release Flow**: `.github/workflows/backend-deploy.yml` builds Docker image, runs `cargo test --locked`, pushes to `registry.fly.io/hypo`, deploys on `main` merges
- **Secrets Management**: Use `fly secrets set` for sensitive configuration; rotate monthly
- **Monitoring**: 
  - Prometheus metrics exported via `/metrics`
  - Connection count tracking
  - Latency percentiles (P50, P95, P99)
  - Error rate monitoring (<0.1% target)
- **Logging**: Structured logs via `tracing` crate with info/warn/error levels

### 6.4 CI/CD
- **macOS**: Xcode Cloud or GitHub Actions with macOS runners
- **Android**: GitHub Actions with Android SDK
- **Backend**: GitHub Actions → Docker build → Deploy to Fly.io

---

## 7. Future Enhancements

1. **Multi-device support**: Sync across >2 devices
2. **Clipboard filtering**: Exclude certain apps (e.g., password managers)
3. **OCR**: Extract text from images in clipboard
4. **Smart paste**: Suggest paste based on context
5. **iCloud/Google Drive integration**: Sync >1MB files
6. **Analytics**: Opt-in usage metrics for optimization

---

## Appendix A: Development Setup

### macOS Client
```bash
cd macos
open Hypo.xcodeproj
# Set development team in Signing & Capabilities
# Run on macOS 26+ device
```

### Android Client
```bash
cd android
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

### Backend
```bash
cd backend
cargo build --release
docker build -t hypo-relay .
docker run -p 8080:8080 hypo-relay
```

---

## Appendix B: Configuration Files

### macOS Launch Agent
```xml
<!-- ~/Library/LaunchAgents/com.hypo.agent.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hypo.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Hypo.app/Contents/MacOS/Hypo</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

### Android Permissions
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<!-- POST_NOTIFICATIONS requires runtime permission request on Android 13+ (API 33+) -->
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.RECEIVE_SMS" />
```

**Permission Handling**:
- **Runtime Permissions**:
  - **`RECEIVE_SMS`** (Android 6.0+): Requested at runtime for SMS auto-sync
    - Automatically requested on app launch if not granted
    - Can be granted via Settings screen
    - Status is monitored and displayed in UI
  - **`POST_NOTIFICATIONS`** (Android 13+): Requested at runtime for foreground service notifications
    - Automatically requested on app launch if not granted (Android 13+)
    - Required for persistent notification showing latest clipboard item
    - Can be granted via Settings screen
    - Status is monitored and displayed in UI
    - Backward compatible: Android 12 and below don't require runtime permission
- **System Permissions**: `BROADCAST_SMS` is a system permission (automatically granted)

---

**Document Version**: 0.3.7  
**Last Updated**: December 2, 2025  
**Status**: Production Beta  
**Authors**: Principal Engineering Team
