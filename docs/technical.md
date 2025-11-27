# Technical Specification - Hypo Clipboard Sync

Version: 0.2.3  
Date: November 26, 2025  
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

#### macOS Client ✅ Implemented
- **Language**: Swift 6 (strict concurrency, actor isolation)
- **UI Framework**: SwiftUI for menu bar UI, AppKit for NSPasteboard monitoring
- **Storage**: In-memory optimized history store with Room-based persistence, Keychain (encryption keys)
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

### 2.1 Message Format

All messages are JSON-encoded with the following schema:

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

#### Connection Handshake
```
Client → Server: WS Upgrade + Device UUID header
Server → Client: 101 Switching Protocols
Client → Server: Auth message (signed with device key)
Server → Client: ACK + session token
```

#### Heartbeat
- Client sends `PING` every 30s
- Server responds with `PONG`
- Timeout after 3 missed pings

#### Disconnection
- Graceful: Client sends `DISCONNECT` message
- Ungraceful: Server detects timeout, cleans up Redis state

### 2.4 De-duplication Strategy

To prevent clipboard ping-pong loops:
1. Each device maintains a **last sent hash** (SHA-256 of payload)
2. Each device maintains a **last received hash**
3. Before sending, check: `hash(clipboard) != last_sent_hash && hash(clipboard) != last_received_hash`
4. Update `last_sent_hash` after sending
5. Update `last_received_hash` after receiving

### 2.5 Throttling
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
- Keychain/EncryptedSharedPreferences for key storage
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
- **WebSocket Connections**: Clients discover updated IP addresses through mDNS/NSD discovery
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

- **Transport Pipeline**: `LanWebSocketTransport` wraps `URLSessionWebSocketTask` behind the shared `SyncTransport` protocol. The client pins the SHA-256 fingerprint advertised in the Bonjour TXT record, frames JSON envelopes with a 4-byte length prefix via `TransportFrameCodec`, and restarts its receive loop after each payload.
- **Timeouts**: Dial attempts still cancel after 3 s; once connected the configurable idle watchdog (30 s default) tears down sockets when no LAN traffic is observed.
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
│   │   │   │       ├── LanWebSocketClient.kt
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

#### 4.2.3 Room Database Schema
```kotlin
@Entity(tableName = "clipboard_history")
data class ClipboardItem(
    @PrimaryKey val id: String,
    val timestamp: Long,
    val type: ClipType,
    val content: String,
    val previewText: String,
    val metadata: String, // JSON
    val deviceId: String,
    val isPinned: Boolean = false
)

@Dao
interface ClipboardDao {
    @Query("SELECT * FROM clipboard_history ORDER BY timestamp DESC LIMIT :limit")
    fun getRecent(limit: Int = 200): Flow<List<ClipboardItem>>

    @Query("SELECT * FROM clipboard_history WHERE previewText LIKE '%' || :query || '%'")
    fun search(query: String): Flow<List<ClipboardItem>>
}
```

#### 4.2.4 NSD Discovery & Registration

- **LanDiscoveryRepository** (`transport/lan/LanDiscoveryRepository.kt`): Bridges `NsdManager` callbacks into a `callbackFlow<LanDiscoveryEvent>` while acquiring a scoped multicast lock. Network-change events are injectable (default implementation listens for Wi-Fi broadcasts) so tests can drive deterministic restarts without Robolectric, and the repository guards `discoverServices` restarts with a `Mutex` to avoid overlapping NSD calls.
- **LanRegistrationManager** (`transport/lan/LanRegistrationManager.kt`): Publishes `_hypo._tcp` with TXT payload `{ fingerprint_sha256, version, protocols }`, listens for Wi-Fi connectivity changes, and re-registers using exponential backoff (1 s, 2 s, 4 s… capped at 5 minutes). Backoff attempts reset after successful registration. On network changes, unregisters and re-registers service to update IP address in NSD records.
- **TransportManager** (`transport/TransportManager.kt`): Starts registration/discovery from the foreground service, exposes a `StateFlow` of discovered peers sorted by recency, and supports advertisement updates for port/fingerprint/version changes. Helpers surface last-seen timestamps and prune stale peers, with a coroutine-driven maintenance loop pruning entries unseen for 5 minutes (default) to keep telemetry/UI aligned with active LAN peers. Provides `restartForNetworkChange()` method to restart both NSD registration and WebSocket server when network changes.
- **Network Change Handling** (`service/ClipboardSyncService.kt`): Registers `ConnectivityManager.NetworkCallback` to detect network availability and capability changes. On network changes, calls `TransportManager.restartForNetworkChange()` to update services with new IP addresses. Health check task (30s interval) monitors service state and restarts if services stop unexpectedly.
- **OEM Notes**: HyperOS throttles multicast after ~15 minutes of screen-off time. The repository exposes lock lifecycle hooks so the service can prompt users to re-open the app, and the registration manager schedules immediate retries when connectivity resumes to mitigate OEM suppression.

#### 4.2.5 Android WebSocket Client

- **OkHttp Integration**: `OkHttpClient` configured with `CertificatePinner` keyed to the relay fingerprint and LAN fingerprint when available. Coroutine-based `Channel` ensures backpressure while sending messages.
- **Fallback Orchestration**: `TransportManager` races LAN connection vs. a 3 s timeout before instantiating a relay `WebSocket`. Cloud attempts use jittered exponential backoff, persisting the last successful transport in `DataStore` for heuristics.
- **Instrumentation**: `MetricsReporter` logs handshake and first payload durations (`transport_handshake_ms`, `transport_first_payload_ms`) with transport label `lan` or `cloud` for downstream analytics.
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
  - Halts LAN discovery (`NsdManager`) to reduce network activity
  - Clipboard monitoring continues (zero-cost, event-driven)
- On `ACTION_SCREEN_ON`:
  - Restarts `TransportManager` with LAN registration config
  - Reconnects WebSocket connections automatically
  - Resumes LAN peer discovery

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

#### 4.2.6 macOS Cloud Relay Transport ✅ Implemented

- **Production Configuration**: `CloudRelayDefaults.production()` provides a `CloudRelayConfiguration` with the Fly.io production endpoint (`wss://hypo.fly.dev/ws`), the current bundle version header, and the production SHA-256 certificate fingerprint.
- **Transport Wrapper**: `CloudRelayTransport` composes the existing `LanWebSocketTransport` while forcing the environment label to `cloud`, giving analytics and metrics a consistent view of fallback events without duplicating handshake logic.
- **Automatic Failover**: 3-second LAN timeout before automatic cloud fallback
- **Certificate Pinning**: SHA-256 fingerprint verification prevents MITM attacks
- **Testing**: Comprehensive unit tests with stub `URLSessionWebSocketTask`s verify send-path delegation and configuration wiring

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
- **Client Fallback Orchestration**: Android and macOS `TransportManager` instances race LAN dial attempts against a 3 s timeout before instantiating the relay transport. Fallback reason codes (`lan_timeout`, `lan_rejected`, `lan_not_supported`) are emitted through the shared `TransportAnalytics` stream for telemetry dashboards.
- **Certificate Pinning**: `backend/scripts/cert_fingerprint.sh` extracts SHA-256 fingerprints from the Fly-issued certificate chain. Clients load the pinned hash and record a `transport_pinning_failure` analytics event when TLS verification fails (environment + host metadata captured).
- **Observability**: Structured logs via `tracing` include connection IDs, transport path (`lan`, `relay`), latency histograms exported to Prometheus, and fallback reason counts. Alerts trigger when relay error rate exceeds 1% over 5 min or when pinning failures exceed 10/min.

---

## 5. Testing Strategy

### 5.1 Unit Tests
- **macOS**: XCTest for services, models
- **Android**: JUnit + MockK for repositories, services
- **Backend**: Rust `#[cfg(test)]` modules

### 5.2 Integration Tests
- **E2E Encryption**: Encrypt on one platform, decrypt on other
- **Transport Fallback**: Simulate LAN unavailable, verify cloud fallback
- **Cloud Telemetry**: Assert fallback reason codes propagate to the analytics sinks and that cloud handshake/first-payload metrics are written to `tests/transport/cloud_metrics.json`.
- **LAN Discovery Harness**: Simulate multicast announcements and ensure discovery emits add/remove events and prunes stale entries after 10 s.
- **Latency Instrumentation**: Assert the `TransportMetricsRecorder` hooks on macOS (`LanWebSocketTransport`) and Android (`LanWebSocketClient`) emit `transport_handshake_ms` and `transport_first_payload_ms` samples, and persist the aggregation to `tests/transport/lan_loopback_metrics.json`.
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
- Latency: Measure P50/P95/P99 for LAN and cloud; publish results in `docs/status.md`
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
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

---

**Document Version**: 0.2.3  
**Last Updated**: November 26, 2025  
**Status**: Production Beta  
**Authors**: Principal Engineering Team

