# Product Requirements Document: Hypo Cross-Platform Clipboard Sync

## Project Overview
- **Project**: Hypo - Cross-Platform Clipboard Sync
- **Platforms**: Android (8.0+), macOS (14.0+), with support for additional platforms (iOS, Windows, Linux)
- **Status**: Production Release (Sprint 11 - Production Release)
- **Version**: v1.0.6
- **Last Updated**: December 13, 2025

## 1. Purpose
Users frequently move between mobile devices (Android, iOS) and desktop computers (macOS, Windows, Linux) but lack a native universal clipboard that works across all platforms. Hypo enables real-time, bi-directional clipboard synchronization across any combination of devices, supporting both LAN (local network) for speed and efficiency and a cloud fallback for mobility. The system provides clipboard history, rich notifications, and cross-format support for text, links, images, and small files.

**Current Implementation Status**: Production release with full Android ↔ macOS support, deployed backend server, device-agnostic pairing system, SMS auto-sync, and MIUI/HyperOS optimization.

## 2. Goals & Objectives

### Achieved in Current Release (v1.0.1)
- ✅ Enable device-agnostic clipboard sync (any device ↔ any device)
- ✅ LAN-first sync with automatic discovery (Bonjour/mDNS)
- ✅ Cloud relay fallback when devices not on same network
- ✅ Support for multiple clipboard data types:
  - ✅ Plain text
  - ✅ Links/URLs
  - ✅ Images (PNG/JPEG/HEIC/GIF/WebP, auto-compressed if >7.5MB, max 10MB)
  - ✅ Files (up to 10MB, lazy loading on macOS)
- ✅ Clipboard history on both platforms (200 items default)
- ✅ Rich notifications with content preview
- ✅ Modern, native UI (SwiftUI on macOS, Material 3 on Android)
- ✅ End-to-end encryption (AES-256-GCM)
- ✅ Device pairing (LAN auto-discovery, QR code, remote code entry)
- ✅ Battery-optimized for mobile (screen-state aware, 60-80% reduction)
- ✅ Production backend deployed (https://hypo.fly.dev)
- ✅ SMS auto-sync (Android): Automatically copies incoming SMS to clipboard and syncs to macOS
- ✅ MIUI/HyperOS optimization: Automatic detection and workarounds for Xiaomi device restrictions
- ✅ Automated build and release pipeline with GitHub Actions
- ✅ Comprehensive documentation and user guides

### Planned for Future Releases
- Multi-device support (>2 devices simultaneously)
- iOS, Windows, and Linux client applications
- Large file support via cloud storage integration
- Advanced features (OCR, smart paste, clipboard filtering)

## 3. Non-Goals (v1.0)
- Not designed for very large file transfers (> 10 MB) - use dedicated file transfer tools
- No guarantee of perfect fidelity for proprietary clipboard formats (e.g., styled RTF from Word, complex spreadsheet formulas)
- Not a file backup or storage solution - clipboard history is local only
- Not a replacement for platform-specific features (e.g., Apple Universal Clipboard, Google Nearby Share)

## 4. Key Features

### 4.1 Device-Agnostic Sync Engine ✅ Implemented
- **Bi-directional sync**: Any device → Any device (Android ↔ macOS, macOS ↔ macOS, Android ↔ Android)
- **Real-time updates**: Sub-second clipboard synchronization
- **De-duplication**: SHA-256 hash-based duplicate detection prevents ping-pong loops
- **Rate limiting**: Token bucket algorithm prevents excessive updates
- **Smart routing**: Backend routes messages only to target devices
- **Connection management**: Automatic reconnection with exponential backoff

### 4.2 Transport Layer ✅ Implemented
- **LAN-first architecture**
  - Automatic device discovery via mDNS/Bonjour (NSD on Android)
  - Direct WebSocket connections over TLS 1.3
  - Certificate fingerprint verification
  - Port 7010 for LAN WebSocket server
  - <500ms latency (P95)
  
- **Cloud relay fallback**
  - Production server: https://hypo.fly.dev
  - WebSocket endpoint: wss://hypo.fly.dev/ws
  - Automatic failover when LAN unavailable
  - Certificate pinning for security
  - <3s latency (P95)
  - Stateless relay design (no data storage)

- **Smart transport selection**
  - 3-second LAN timeout before cloud fallback
  - Connection pooling and reuse
  - Graceful reconnection handling

### 4.3 Clipboard Data Support
- Text/Links/URLs: UTF-8 encoded.
- Images: Auto-compressed if >7.5MB (scale down >2560px, re-encode as JPEG with quality 85-40%), max 10MB.
- Files: Base64-encoded files up to 10MB. macOS uses lazy loading (file bytes loaded on-demand when syncing).
- Compression: Gzip compression of JSON payloads before encryption (always enabled, 70-90% reduction for text).

### 4.4 macOS Features ✅ Implemented
- **Menu bar application**: Non-intrusive, always-accessible from menu bar
- **Notification Center integration**: Rich notifications with content previews
- **Clipboard history**:
  - Searchable history with 200-item default limit
  - Filter by content type (text, link, image, file)
  - Filter by date/time
  - Visual indicators for encryption status and transport origin
  - Pin frequently used items
  - Drag-to-paste support
- **Settings management**:
  - Device pairing and management
  - Transport preferences (LAN/Cloud)
  - History retention settings
  - Connection status display with real-time updates
- **Native SwiftUI interface** with dark mode support

### 4.5 Android Features ✅ Implemented
- **Foreground service**: Reliable clipboard monitoring with persistent notification
- **Battery optimization**: 
  - Screen-state aware connection management
  - 60-80% reduction in battery drain during screen-off
  - Automatic reconnection on screen-on
- **Material 3 UI**:
  - Dynamic color theming
  - Home screen with recent clipboard item
  - Full clipboard history with search
  - Connection status indicators
- **Settings**:
  - Device pairing (auto-discovery, QR code, code entry)
  - Paired device management
  - Transport preferences
  - History retention controls
  - Battery optimization guidance
  - SMS permission management with status display
- **Permissions handling**: Clear prompts and guidance for required permissions
  - Runtime permission requests for SMS (Android 6.0+)
  - Notification permission handling (Android 13+)
  - Permission status monitoring and UI updates
- **Text Selection Context Menu** ✅ Implemented (December 2025):
  - "Copy to Hypo" appears first in text selection menu across all apps
  - ProcessTextActivity handles ACTION_PROCESS_TEXT intent
  - Forces immediate clipboard processing via service intent
  - Passes text directly in intent to avoid timing issues with clipboard access
  - Works even when ClipboardListener isn't started (e.g., accessibility service enabled)
- **History Item Copying** ✅ Improved (December 2025):
  - Items move to top when copied from history
  - Universal "Copied to clipboard" toast notification for all item types
  - FileProvider integration for secure file sharing on Android 10+
  - Resolves "FrameInsert open fail" errors when copying images/files
- **SMS Auto-Sync** ✅ Implemented (December 2025):
  - **Overview**: Automatically copies incoming SMS messages to clipboard and syncs to macOS via existing clipboard sync mechanism
  - **How It Works**:
    1. `SmsReceiver` BroadcastReceiver listens for incoming SMS broadcasts
    2. SMS content is automatically copied to clipboard with format: `From: <sender>\n<message>`
    3. Existing `ClipboardListener` detects the clipboard change and syncs to macOS
  - **Implementation**:
    - `SmsReceiver` (`service/SmsReceiver.kt`): BroadcastReceiver that listens for `SMS_RECEIVED` broadcasts
    - Registered in `AndroidManifest.xml` with `RECEIVE_SMS` permission
  - **Android Version Limitations**:
    - **Android 9 and Below (API 28-)**: ✅ Fully supported - SMS receiver works without restrictions
    - **Android 10+ (API 29+)**: ⚠️ Restricted - SMS access may be limited
      - May require app to be set as default SMS app (not recommended - breaks SMS functionality)
      - If auto-copy fails, users can manually copy SMS and sync will work normally
      - SecurityException is caught and logged, app continues to function
  - **Permissions**:
    - `RECEIVE_SMS`: Required to receive SMS broadcast intents (dangerous permission on Android 6.0+)
    - `BROADCAST_SMS`: System permission (automatically granted)
    - Runtime permission request on Android 6.0+ with UI status display
    - Settings screen shows permission status and provides grant button
    - Periodic permission status monitoring (every 2 seconds)
  - **User Experience**:
    1. User grants SMS permission (automatic on first launch, or via Settings screen)
    2. When SMS is received, content is automatically copied to clipboard
    3. Clipboard sync service detects change within ~100ms
    4. SMS content is synced to macOS within ~1 second
    5. User can see SMS in macOS clipboard history
  - **Privacy & Security**:
    - SMS content is handled the same way as any clipboard content
    - Encrypted end-to-end when syncing to macOS (AES-256-GCM)
    - No SMS content is stored permanently (only in clipboard history)
    - Users can clear clipboard history to remove SMS content
    - Permission can be revoked at any time via Android Settings
  - **Troubleshooting**:
    - **SMS Not Auto-Copying**: Check Android version (Android 10+ has restrictions), check logs for SecurityException warnings, verify permission is granted
    - **SMS Copied But Not Syncing**: Check clipboard sync service is running, verify network connection, check device pairing, review logs
- **MIUI/HyperOS Adaptation** ✅ Implemented (December 2025):
  - Automatic device detection (Xiaomi/HyperOS)
  - Multicast lock refresh every 10 minutes (prevents throttling)
  - Periodic NSD restart every 5 minutes (recovers from throttling)
  - Device-specific settings guidance in UI
  - Transparent to users - no configuration required

### 4.6 Security & Privacy ✅ Implemented
- **End-to-end encryption**: AES-256-GCM with authenticated encryption
- **Device pairing**:
  - LAN auto-discovery with tap-to-pair
  - QR code pairing with signature verification
  - Remote pairing via secure 6-digit codes (60s TTL)
  - Device-agnostic (any device can initiate/respond)
- **Key management**:
  - Secure storage (Keychain on macOS, EncryptedSharedPreferences on Android)
  - ECDH key exchange (Curve25519)
  - Pairing-time key rotation for forward secrecy
- **Certificate pinning**: Protection against MITM attacks on cloud relay
- **No data storage**: Backend relay never stores clipboard content
- **Privacy by design**: All clipboard data encrypted before transmission

## 5. Technical Requirements

### macOS Client
- Language: Swift 6 (strict concurrency) + SwiftUI + AppKit (NSPasteboard).
- Menu bar application (LSUIElement) - no Dock icon.
- Notifications via UNUserNotificationCenter (macOS 13.0+).
- Network.framework for WebSocket server and client connections.

### Android Client
- Language: Kotlin 1.9.22 with coroutines and structured concurrency.
- ClipboardManager API with Accessibility Service fallback.
- Foreground Service (FOREGROUND_SERVICE_DATA_SYNC) to bypass background restrictions.
- Room database for clipboard history persistence.
- Java-WebSocket library for LAN WebSocket server.

### Backend (Cloud Relay) ✅ Deployed
- **Language**: Rust 1.83+ with Actix-web 4.x.
- **Deployment**: Fly.io production (https://hypo.fly.dev).
- **Infrastructure**: 
  - 2 machines in iad (Ashburn, VA) region
  - Auto-scaling (min=1, max=3)
  - Embedded Redis 7+ for session management
  - Zero-downtime deployments
- **Stateless design**: Relays only encrypted payloads, never stores clipboard content.
- **Message Queue (Planned)**: When target device is offline, messages are queued with exponential backoff retry (1s → 2s → 4s → ... → 2048s max). Messages expire after 2048 seconds. Queue stored in Redis for persistence across server restarts.
- **Protocol**: See [`docs/protocol.md`](./protocol.md) for complete message format specification.
- **Observability**: Structured logging with tracing, Prometheus metrics endpoint.

## 6. User Stories
1. As a user, I copy a text snippet on my Xiaomi phone, and within 1 s, it appears on my Mac.
2. As a user, I copy an image (≤ 10 MB) on my Mac, and it syncs to my phone's clipboard.
3. As a user, I want a macOS menu-bar app to view my clipboard history and paste from it.
4. As a user, if I’m away from my LAN, I want the clipboard to still sync via the cloud.
5. As a user, I want notifications on macOS when a new clipboard item arrives from my phone.

### 6.1 Local Pairing via QR (LAN-First)

- **Entry Point**: Any device → *Pair New Device*.
- **Prerequisites**: Both devices connected to LAN, on same subnet, Bonjour/mDNS enabled.
- **Device-Agnostic**: Any device can pair with any other device (Android↔Android, macOS↔macOS, Android↔macOS, etc.).
- **QR Payload Schema**:

| Field | Type | Description |
|-------|------|-------------|
| `ver` | string | Semantic version of the pairing payload (`"1"` for v1). |
| `peer_device_id` | UUID v4 | Stable device identifier of the device generating the QR code. |
| `peer_pub_key` | base64 (32 bytes) | Curve25519 public key for ephemeral ECDH. |
| `peer_signing_pub_key` | base64 (32 bytes) | Ed25519 public key for signature verification. |
| `service` | string | Bonjour service name advertised (e.g., `_hypo._tcp.local`). |
| `port` | number | TCP port for the provisional LAN WebSocket endpoint. |
| `relay_hint` | URL | Optional HTTPS fallback relay endpoint if LAN negotiation fails. |
| `issued_at` | ISO8601 | Creation timestamp (UTC). |
| `expires_at` | ISO8601 | Expiry timestamp (issued_at + 5 min). |
| `signature` | base64 (64 bytes) | Ed25519 signature over concatenated fields using long-term pairing key. |

- **Flow**:
  1. Initiator device generates new ephemeral Curve25519 key pair and QR payload, signs it with its long-term pairing key, and renders QR using high-contrast theme.
  2. Responder device scans QR, validates schema version, timestamp window (±5 min), and Ed25519 signature using initiator's long-term public key from previous pairing (or bootstrap list bundled with app).
  3. Responder resolves the Bonjour service using `service` + `port`; if discovery fails within 3 s, prompt to retry or fall back to remote pairing.
  4. Responder generates its own ephemeral Curve25519 key pair and derives shared secret via X25519(peer_pub_key, responder_priv_key) → HKDF-SHA256 (info: `"hypo/pairing"`, salt: 32 bytes of `0x00`).
  5. Responder sends encrypted `PAIRING_CHALLENGE` over LAN WebSocket with payload `{ initiator_device_id, initiator_device_name, initiator_pub_key, nonce, ciphertext, tag }` using AES-256-GCM and associated data `initiator_device_id`.
  6. Initiator decrypts challenge, verifies monotonic nonce (store last 32 challenge IDs), detects responder's platform from device ID or metadata, and responds with `PAIRING_ACK` containing device profile (device name, platform) encrypted with same shared key.
  7. Both devices persist derived shared key (platform-specific secure storage) and store counterpart device metadata with detected platform information.
  8. Both devices update UI to display success; pairing is complete and devices can begin syncing.
- **Error Handling**:
  - If signature validation fails → display security warning, block pairing, log telemetry event `pairing_qr_signature_invalid`.
  - If handshake times out → allow user to retry scanning without generating a new QR until expiry.
  - If LAN WebSocket negotiation fails repeatedly → provide CTA to switch to remote pairing flow.

### 6.2 Remote Pairing via Relay (Code Entry)

- **Entry Point**: Any device → *Pair over Internet* toggle; Other device → *Enter Code* dialog.
- **Prerequisites**: Backend relay reachable, both clients online.
- **Device-Agnostic**: Any device can create a pairing code (initiator), and any other device can claim it (responder).
- **Pairing Code Schema**:
  - 6-digit numeric code (`000000`–`999999`), random, non-sequential.
  - TTL: 60 s, stored in Redis with device metadata (`initiator_device_id`, `initiator_public_key`, `issued_at`).
- **Flow**:
  1. Initiator device requests new pairing code from relay: `POST /pairing/code` with `{ initiator_device_id, initiator_device_name, initiator_public_key }`, obtains `{ code, expires_at }`.
  2. User enters code on responder device; app calls `POST /pairing/claim` with `{ code, responder_device_id, responder_device_name, responder_public_key }`.
  3. Relay validates TTL and rate limits (max 5 attempts per minute per IP/device). On success, it returns initiator's public key and device metadata.
  4. Responder and initiator perform the same challenge/response exchange as LAN flow, routed via relay using encrypted control messages (`PAIRING_CHALLENGE`, `PAIRING_ACK`). Challenge messages use `initiator_device_id`/`initiator_pub_key` fields; ACK messages use `responder_device_id`/`responder_device_name` fields.
  5. Relay deletes pairing code upon successful acknowledgement or TTL expiry (whichever first) and emits audit log `pairing_code_consumed`.
- **Error Handling**:
  - Invalid/expired code → Responder shows inline error and allows regeneration request. Relay increments abuse counter; after 10 failures code is revoked.
  - If initiator is offline when claim occurs → relay queues notification for 30 s; if unacknowledged, code returns to available state until TTL expiry.
  - Duplicate device IDs detected by relay respond with `DEVICE_NOT_PAIRED` error, instructing responder to clear cached keys and restart pairing.
- **Security Requirements**:
  - All relay endpoints require TLS + HMAC header (`X-Hypo-Signature`) using app secret stored securely on each device.
  - Telemetry event `pairing_remote_success` sent upon completion, including anonymized latency metrics.
  - Pairing handshake transcripts discarded after success; only hashed device IDs stored for analytics.

## 7. UX / UI Concepts

### macOS
- Menu bar icon with clipboard count.
- History popup with search box and previews.

### Android
- Clean Material You interface.
- Switch between LAN/Cloud, manage keys, view history.

## 8. Risks / Challenges

### Addressed ✅
- ✅ **Android background clipboard access restrictions**: Mitigated with Accessibility Service and foreground service
- ✅ **HyperOS multicast throttling**: Automatic workarounds implemented (multicast lock refresh, NSD restart)
- ✅ **Performance with image/file transfers**: Optimized with compression and size limits (10MB, gzip compression for JSON payloads)
- ✅ **Cloud fallback latency**: Achieved <3s P95 latency with production relay
- ✅ **Security**: Strong encryption (AES-256-GCM) with certificate pinning

### Ongoing Monitoring
- Android OS updates may introduce new restrictions
- Network reliability in various environments
- Battery optimization on different OEM devices

## 9. Success Metrics

### Achieved Metrics (Current Release)
- ✅ **LAN sync latency**: P95 < 500ms (achieved: ~200-400ms typical)
- ✅ **Cloud sync latency**: P95 < 3s (achieved: ~1-2s typical)
- ✅ **Memory usage**: macOS < 50MB (achieved: ~35-45MB), Android < 30MB (achieved: ~20-25MB)
- ✅ **Battery optimization**: Android < 2% drain per day (achieved with screen-off optimization)
- ✅ **Server uptime**: >99.9% (achieved: 36+ days continuous)
- ✅ **Backend response time**: <100ms (achieved: ~50ms for health endpoint)

### Production Metrics (v1.0.1)
- ✅ **Error rate**: < 0.1% (achieved)
- ✅ **Message delivery success rate**: > 99.9% (achieved)
- ✅ **Device pairing success rate**: > 95% (achieved)
- ✅ **Zero critical security vulnerabilities**: All known issues resolved
- ✅ **Protocol version**: 1.0.0 (production-ready)
- ✅ **Automated CI/CD**: GitHub Actions release pipeline operational

## 10. Suggestions for Expansion
- Add multi-device sync (Mac ↔ multiple phones).
- Add end-to-end logs and analytics (debug mode).
- Optionally integrate with iCloud Drive or Google Drive for larger files.
- Add cross-device search: search clipboard history across all devices.

## 11. UX / UI Wireframes (Conceptual)

### macOS 26 (Menu Bar App + History)
- **Menu Bar Dropdown**
  - Top section: Latest clipboard item preview.
  - Shows icon by type: 📋 text, 🔗 link, 🖼 image, 📄 file.
  - Hover → “Copy to Clipboard Again.”
  - Middle section: History list (scrollable, approximately 10–15 recent items).
  - Each entry: small icon plus truncated text, filename, or thumbnail.
  - Right-click → options (Copy, Pin, Delete).
  - Bottom section includes a search bar (filter by keyword, type, or date) and a settings gear.
- **Notification Center**
  - Rich preview of new incoming item:
    - Text → show first 100 characters.
    - Link → show domain and favicon.
    - Image → small thumbnail.
    - File → filename and size.

### Android / HyperOS 3 (App + Foreground Service)
- **Home Screen**
  - Header: “Clipboard Sync” with device connection status (LAN / Cloud / Offline).
  - Large card for the last clipboard item (preview plus “Share to Mac” button if sync fails).
  - History section: chronological list with type icons, searchable.
- **Settings Screen**
  - Toggles: Enable LAN sync / Enable Cloud sync.
  - Encryption keys management (pair device via QR code).
  - Data retention settings (history size, auto-delete after N days).
  - Battery optimization whitelist instructions.
- **Foreground Service Notification**
  - Persistent notification: “Clipboard sync active.”
  - Quick action buttons: Pause, Resume, Push last item.

## 12. Suggested Visual Style
- macOS: Light/dark mode adaptive, rounded cards, native SF Symbols icons.
- Android/HyperOS: Material You theming with color-adaptive widgets.
- Consistency: Use the same symbols for content types (text/link/image/file) across both platforms.

## 13. Future Expansion (UI Hooks)
- Multi-device support: device list in settings.
- Drag-and-drop files directly into the menu bar app for instant sharing.
- Contextual actions: for example, links open directly in browser, images preview fullscreen.

