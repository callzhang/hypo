# Technical Specification - Hypo Clipboard Sync

Version: 0.1.0  
Date: October 1, 2025  
Status: Draft

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
Hypo employs a **peer-to-peer first, cloud fallback** architecture for clipboard synchronization. Devices discover each other via mDNS on local networks and establish direct encrypted WebSocket connections. When LAN is unavailable, a lightweight cloud relay server routes end-to-end encrypted payloads.

### 1.2 Component Diagram
See `docs/architecture.mermaid` for visual representation.

### 1.3 Technology Decisions

#### macOS Client
- **Language**: Swift 6 (strict concurrency)
- **UI Framework**: SwiftUI for menu bar UI, AppKit for NSPasteboard
- **Storage**: Core Data (clipboard history), Keychain (encryption keys)
- **Networking**: URLSession WebSocket API
- **Background**: Launch agent (LaunchAgents/com.hypo.agent.plist)

#### Android Client
- **Language**: Kotlin 2.0 with coroutines
- **UI**: Jetpack Compose with Material 3
- **Storage**: Room (history), EncryptedSharedPreferences (keys)
- **Networking**: OkHttp WebSocket
- **Background**: Foreground Service with FOREGROUND_SERVICE_DATA_SYNC permission

#### Backend Relay
- **Language**: Rust 1.75+
- **Framework**: Actix-web 4.x for WebSocket
- **State**: Redis 7+ for ephemeral connection mapping
- **Deployment**: Docker + Fly.io or Railway

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

### 3.2 Device Pairing Protocol

#### Initial Pairing (LAN)
1. User opens "Pair Device" on macOS.
2. macOS fetches/rotates its long-term Ed25519 signing key (stored in Keychain) and generates an ephemeral Curve25519 key pair for this attempt.
3. Compose QR payload using fields defined in PRD §6.1 (`ver`, `mac_device_id`, `mac_pub_key`, `service`, `port`, `relay_hint`, `issued_at`, `expires_at`).
4. Create canonical byte representation: JSON sorted by key, UTF-8 encoded; sign with Ed25519 → `signature` field.
5. Render QR (error correction level M, 256×256) and expose to user until `expires_at`.
6. Android scans QR, parses JSON, validates schema + TTL window (±5 min) and verifies signature against macOS long-term public key (distributed during previous pairing or bootstrap update channel).
7. Android publishes ephemeral Curve25519 key pair, derives shared key = HKDF-SHA256(X25519(mac_pub_key, android_priv_key), salt = 32 bytes of 0x00, info = "hypo/pairing").
8. Resolve Bonjour service `service` and `port`; connect via TLS WebSocket. If connection fails within 3 s, fallback path triggers (see Remote Pairing).
9. Android emits `PAIRING_CHALLENGE` message: AES-256-GCM encrypt random 32-byte challenge, associated data = `mac_device_id`. Include `nonce`, `ciphertext`, `tag`.
10. macOS decrypts, ensures nonce monotonicity (LRU cache of last 32 seen). Responds with `PAIRING_ACK` containing device descriptor and hashed Android ID.
11. Both sides persist shared key + peer metadata; handshake complete. macOS invalidates QR (even if `expires_at` not reached) and logs telemetry `pairing_lan_success` with anonymized latency.

#### Remote Pairing (via Cloud Relay)
1. macOS obtains pairing code by calling relay `POST /pairing/code` with TLS + HMAC header. Response includes `{ code, expires_at }`.
2. Relay stores entry in Redis: key `pairing:code:<code>` → JSON { mac_device_id, mac_pub_key, issued_at, expires_at } with TTL 60 s.
3. Android collects 6-digit code from user, invokes `POST /pairing/claim` with `{ code, android_device_id, android_pub_key }` and same HMAC header.
4. Relay verifies TTL + rate limits (5 attempts/min/IP). On success, it returns macOS payload (excluding signature) and pushes WebSocket control message `PAIRING_CLAIMED` to macOS.
5. Android derives shared key using retrieved `mac_pub_key` (HKDF parameters identical to LAN flow) and sends `PAIRING_CHALLENGE` via relay channel. Relay treats body as opaque bytes.
6. macOS replies with `PAIRING_ACK`; relay forwards to Android. After acknowledgement, relay deletes Redis entry and emits audit log.
7. Failure Cases:
   - Expired code → HTTP 410; Android prompts for regeneration.
   - macOS offline → relay retries notify for 30 s; if unacknowledged, entry resets for reuse until TTL.
   - Duplicate `mac_device_id` claims → HTTP 409 `DEVICE_NOT_PAIRED`; instruct client to restart handshake.

### 3.3 Message Encryption

**Algorithm**: AES-256-GCM

**Per-Message Process**:
1. Generate random 12-byte nonce
2. Encrypt payload: `ciphertext, tag = AES-GCM(key, nonce, plaintext, associated_data=device_id)`
3. Include nonce and tag in message
4. Recipient verifies tag before decryption

**Key Rotation**:
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
- **TransportManager Integration** (`Services/TransportManager.swift`): The manager now persists LAN sightings via `UserDefaultsLanDiscoveryCache`, auto-starts discovery/advertising on foreground using `ApplicationLifecycleObserver`, and exposes `lanDiscoveredPeers()` plus a diagnostics string for `hypo://debug/lan`. Deep links are surfaced through SwiftUI's `.onOpenURL`, logging active registrations alongside publisher state.
- **BonjourPublisher** (`Utilities/BonjourPublisher.swift`): Publishes `_hypo._tcp` with TXT payload `{ version, fingerprint_sha256, protocols }`, tracks the currently advertised endpoint, and restarts advertising when configuration changes (e.g., port update). Diagnostics reuse this metadata so operators can validate fingerprints during support sessions.
- **Testing**: `TransportManagerLanTests` validate that discovery events update persisted timestamps, diagnostics include discovered peers, and lifecycle hooks stop advertising on suspend.

#### 4.1.6 LAN WebSocket Client

- **Transport Pipeline**: `LanTransport` composes certificate pinning (SHA-256 fingerprint fetched from pairing metadata), TLS configuration with ALPN `hypo/1`, and a `URLSessionWebSocketTask` send/receive loop using `AsyncStream` bridging.
- **Timeouts**: LAN dial attempts are cancelled after 3 s; success resets the transport manager state to `ConnectedLan`. Idle watchdog closes sockets after 60 s of inactivity while leaving heartbeat timers running.
- **Metrics**: Each connection records handshake duration, first-message latency, and disconnect reason; results feed into `TelemetryClient` for ingestion and status reporting.

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
│   │   │   │   └── lan/
│   │   │   │       ├── LanDiscoveryRepository.kt
│   │   │   │       ├── LanRegistrationManager.kt
│   │   │   │       └── LanModels.kt
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
- **LanRegistrationManager** (`transport/lan/LanRegistrationManager.kt`): Publishes `_hypo._tcp` with TXT payload `{ fingerprint_sha256, version, protocols }`, listens for Wi-Fi connectivity changes, and re-registers using exponential backoff (1 s, 2 s, 4 s… capped at 5 minutes). Backoff attempts reset after successful registration.
- **TransportManager** (`transport/TransportManager.kt`): Starts registration/discovery from the foreground service, exposes a `StateFlow` of discovered peers sorted by recency, and supports advertisement updates for port/fingerprint/version changes. Helpers surface last-seen timestamps and prune stale peers, ensuring telemetry and UI layers can render an accurate LAN roster.
- **OEM Notes**: HyperOS throttles multicast after ~15 minutes of screen-off time. The repository exposes lock lifecycle hooks so the service can prompt users to re-open the app, and the registration manager schedules immediate retries when connectivity resumes to mitigate OEM suppression.

#### 4.2.5 Android WebSocket Client

- **OkHttp Integration**: `OkHttpClient` configured with `CertificatePinner` keyed to the relay fingerprint and LAN fingerprint when available. Coroutine-based `Channel` ensures backpressure while sending messages.
- **Fallback Orchestration**: `TransportManager` races LAN connection vs. a 3 s timeout before instantiating a relay `WebSocket`. Cloud attempts use jittered exponential backoff, persisting the last successful transport in `DataStore` for heuristics.
- **Instrumentation**: `MetricsReporter` logs handshake and first payload durations (`transport_handshake_ms`, `transport_first_payload_ms`) with transport label `lan` or `cloud` for downstream analytics.

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

- **Staging Deployment**: Relay packaged via Docker and deployed to Fly.io. `fly.toml` defines auto-scaling (min=1, max=3) and binds Redis through the `redis` add-on. Secrets (`RELAY_HMAC_KEY`, `CERT_FINGERPRINT`) managed through Fly secrets and rotated monthly.
- **Pairing Support**: Adds `/pairing/code` and `/pairing/claim` endpoints secured with HMAC header `X-Hypo-Signature`. Pairing codes stored in Redis with 60 s TTL and replay protection counters.
- **Observability**: Structured logs via `tracing` include connection IDs, transport path (`lan`, `relay`), and latency histograms exported to Prometheus. Alerts trigger when relay error rate exceeds 1% over 5 min.

---

## 5. Testing Strategy

### 5.1 Unit Tests
- **macOS**: XCTest for services, models
- **Android**: JUnit + MockK for repositories, services
- **Backend**: Rust `#[cfg(test)]` modules

### 5.2 Integration Tests
- **E2E Encryption**: Encrypt on one platform, decrypt on other
- **Transport Fallback**: Simulate LAN unavailable, verify cloud fallback
- **LAN Discovery Harness**: Simulate multicast announcements and ensure discovery emits add/remove events and prunes stale entries after 10 s.
- **Latency Instrumentation**: Assert handshake timers produce metrics for `transport_handshake_ms` and `transport_first_payload_ms` across LAN and cloud paths.
- **De-duplication**: Send same content twice, verify single sync

### 5.3 Manual Test Cases
1. Copy text on Android → verify appears on macOS within 1s
2. Copy image on macOS → verify appears on Android
3. Disconnect Wi-Fi → verify cloud fallback works
4. Toggle airplane mode to confirm automatic LAN re-registration and fallback recovery
5. Device pairing via QR code
6. Run LAN latency capture script and validate telemetry upload
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

### 6.3 Backend Deployment
- **Platform**: Fly.io (staging) with optional Railway fallback for load tests
- **Configuration**: `fly.toml` checked into `backend/infra/` defines regions (`iad`, `sjc`), auto-scaling (min=1, max=3), health checks (`/healthz` every 15 s), and Redis attachment `hypo-redis`.
- **Release Flow**: GitHub Actions pipeline builds Docker image, runs `cargo test`, executes integration suite, and deploys tagged images to Fly with release annotations. Rollbacks executed via `fly deploy --image` referencing previous digest.
- **Secrets Management**: Use `fly secrets set RELAY_HMAC_KEY=... CERT_FINGERPRINT=...` per environment; rotate monthly and update client fingerprints.
- **Monitoring**: Prometheus scraping via Fly metrics exporter, Grafana dashboard for connection counts, latency percentiles, and error ratios (<0.5% target).
- **Logging**: Structured logs via `tracing` crate shipped to Loki for retention (14 days) with alerts when pairing/code endpoints exceed 5% failure rate.

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

**Document Version**: 0.1.0  
**Last Updated**: October 1, 2025  
**Authors**: Principal Engineering Team

