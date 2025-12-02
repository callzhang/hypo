# Product Requirements Document: Hypo Cross-Platform Clipboard Sync

## Project Overview
- **Project**: Hypo - Cross-Platform Clipboard Sync
- **Platforms**: Android (8.0+), macOS (14.0+), with support for additional platforms (iOS, Windows, Linux)
- **Status**: Beta (Sprint 8 - Polish & Deployment)
- **Version**: v0.2.3
- **Last Updated**: November 26, 2025

## 1. Purpose
Users frequently move between mobile devices (Android, iOS) and desktop computers (macOS, Windows, Linux) but lack a native universal clipboard that works across all platforms. Hypo enables real-time, bi-directional clipboard synchronization across any combination of devices, supporting both LAN (local network) for speed and efficiency and a cloud fallback for mobility. The system provides clipboard history, rich notifications, and cross-format support for text, links, images, and small files.

**Current Implementation Status**: Production-ready beta with full Android ↔ macOS support, deployed backend server, and device-agnostic pairing system.

## 2. Goals & Objectives

### Achieved in Current Release (v0.2.3)
- ✅ Enable device-agnostic clipboard sync (any device ↔ any device)
- ✅ LAN-first sync with automatic discovery (Bonjour/mDNS)
- ✅ Cloud relay fallback when devices not on same network
- ✅ Support for multiple clipboard data types:
  - ✅ Plain text
  - ✅ Links/URLs
  - ✅ Images (PNG/JPEG, compressed if >1 MB)
  - ✅ Files (up to 1 MB)
- ✅ Clipboard history on both platforms (200 items default)
- ✅ Rich notifications with content preview
- ✅ Modern, native UI (SwiftUI on macOS, Material 3 on Android)
- ✅ End-to-end encryption (AES-256-GCM)
- ✅ Device pairing (LAN auto-discovery, QR code, remote code entry)
- ✅ Battery-optimized for mobile (screen-state aware)
- ✅ Production backend deployed (https://hypo.fly.dev)

### Planned for Future Releases
- Multi-device support (>2 devices simultaneously)
- iOS, Windows, and Linux client applications
- Large file support via cloud storage integration
- Advanced features (OCR, smart paste, clipboard filtering)

## 3. Non-Goals (v1.0)
- Not designed for very large file transfers (> 1 MB) - use dedicated file transfer tools
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
- Images: Compressed to PNG or JPEG.
- Files: Base64-encoded small files (< 1 MB).

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
- **Permissions handling**: Clear prompts and guidance for required permissions

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
- Language: Swift/SwiftUI + AppKit (NSPasteboard).
- Background agent + menu-bar app.
- Notifications via the macOS 26 notification framework.

### Android Client
- Language: Kotlin.
- ClipboardManager API.
- Foreground Service to bypass background restrictions.

### Backend (Cloud Relay)
- Lightweight WebSocket server (Node.js, Go, or Rust).
- Stateless design that relays only encrypted payloads.
- Protocol format:

```json
{
  "id": "uuid",
  "timestamp": "iso8601",
  "type": "text|link|image|file",
  "payload": "base64/string",
  "device": "android|macos"
}
```

## 6. User Stories
1. As a user, I copy a text snippet on my Xiaomi phone, and within 1 s, it appears on my Mac.
2. As a user, I copy an image (≤ 1 MB) on my Mac, and it syncs to my phone’s clipboard.
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
- Android background clipboard access restrictions (HyperOS may add more).
- Maintaining performance with image/file transfers.
- Latency issues if cloud fallback is the only available path.
- Security: clipboard may contain sensitive data, so encryption must be strong.

## 9. Success Metrics

### Achieved Metrics (Current Release)
- ✅ **LAN sync latency**: P95 < 500ms (achieved: ~200-400ms typical)
- ✅ **Cloud sync latency**: P95 < 3s (achieved: ~1-2s typical)
- ✅ **Memory usage**: macOS < 50MB (achieved: ~35-45MB), Android < 30MB (achieved: ~20-25MB)
- ✅ **Battery optimization**: Android < 2% drain per day (achieved with screen-off optimization)
- ✅ **Server uptime**: >99.9% (achieved: 36+ days continuous)
- ✅ **Backend response time**: <100ms (achieved: ~50ms for health endpoint)

### Target Metrics (Beta Testing Phase)
- Error rate < 0.1%
- Message delivery success rate > 99.9%
- User satisfaction rating ≥ 4.5 in beta test
- Device pairing success rate > 95%
- Zero critical security vulnerabilities

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

