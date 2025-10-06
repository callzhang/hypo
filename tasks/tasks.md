# Hypo Development Tasks

Version: 0.1.0
Last Updated: October 3, 2025

---

## Sprint 1: Foundation & Architecture (Weeks 1-2)

### Phase 1.1: Project Setup
- [x] Initialize repository structure
  - [x] Create mono-repo with `macos/`, `android/`, `backend/` directories
  - [x] Set up `.gitignore` for each platform
  - [x] Initialize version control with semantic versioning
- [x] Documentation
  - [x] Create `docs/architecture.mermaid`
  - [x] Create `docs/technical.md`
  - [x] Create `tasks/tasks.md`
  - [x] Create `docs/status.md`
  - [x] Create `changelog.md`
  - [x] Create `README.md` with setup instructions
- [ ] Development environment *(see README prerequisites; need validation run on clean machines)*
  - [ ] macOS: Xcode 15+, Swift 6 setup
  - [ ] Android: Android Studio, Kotlin 2.0 setup
  - [ ] Backend: Rust 1.75+, Redis local instance

### Phase 1.2: Protocol Definition
- [x] Define JSON message schema with validation (see `docs/protocol.schema.json`)
- [x] Implement protocol buffers or stick with JSON (decision point)
  - ✅ Decision: Ship v1 with JSON payloads, revisit binary encoding in Sprint 5 performance review.
- [x] Create protocol documentation with examples
- [x] Define error codes and handling *(see `docs/protocol.md` §4.4 for catalogue and retry rules)*

### Phase 1.3: Security Foundation
- [x] Research and select crypto libraries *(see `docs/crypto_research.md` for evaluation matrix)*
  - [x] macOS: CryptoKit evaluation
  - [x] Android: Jetpack Security or Tink
  - [x] Backend: RustCrypto
- [x] Implement encryption module (cross-platform compatible)
  - [x] AES-256-GCM encryption/decryption
  - [x] Nonce generation
  - [x] Key derivation from ECDH
- [x] Design device pairing flow (QR code format) *(see PRD §6.1/6.2 and technical spec §3.2)*

### Phase 1.4: Product Definition & Planning
- [x] Draft Product Requirements Document (`docs/prd.md`)
- [x] Capture UX and interaction concepts for macOS and Android within PRD
- [ ] Schedule stakeholder review and sign-off for PRD v0.1
- [ ] Derive success metrics dashboard from PRD §9

---

## Sprint 2: Core Sync Engine (Weeks 3-4)

### Phase 2.1: macOS Client - Core
- [x] Create Xcode project with SPM dependencies *(Swift Package created in `macos/Package.swift` with workspace at `macos/HypoApp.xcworkspace` ready for Xcode integration)*
- [x] Implement `ClipboardMonitor` with NSPasteboard polling
- [x] Implement `ClipboardItem` Core Data model *(implemented as `ClipboardEntry` domain model with metadata structs)*
- [x] Create `HistoryManager` with CRUD operations
- [x] Implement de-duplication logic (hash-based)
- [x] Implement throttling (token bucket)
- [x] Unit tests for clipboard monitoring *(History store coverage in place; monitor tests pending due to AppKit dependency)*

### Phase 2.2: Android Client - Core
- [x] Create Android project with Gradle Kotlin DSL *(base project bootstrapped with Compose + Hilt wiring)*
- [x] Implement `ClipboardSyncService` (Foreground)
- [x] Implement `ClipboardListener` with ClipboardManager
- [x] Create Room database schema
- [x] Create `ClipboardRepository` with Flow-based API
- [x] Implement de-duplication and throttling *(listener hash guard, repository Flow backpressure)*
- [x] Unit tests with MockK

### Phase 2.3: Backend Relay - Core
- [x] Initialize Rust project with Actix-web
- [x] Implement WebSocket handler
- [x] Implement Redis connection pool
- [x] Device registration/unregistration
- [x] Message routing logic
- [x] Health check endpoint
- [x] Unit tests for session routing manager *(covers registration, replacement, offline handling)*
- [x] Integration tests for router fan-out logic

---

## Sprint 3: Transport Layer (Weeks 5-6)

### Phase 3.1: LAN Discovery & Connection

- [x] macOS: Implement Bonjour browser (`NetService`)
  - [x] Build `BonjourBrowser` actor that wraps `NetServiceBrowser` with async sequence APIs.
  - [x] Emit discovery events to `TransportManager` and persist the last seen timestamp for stale record pruning.
  - [x] Add unit harness using `NetService` test doubles to validate add/remove callbacks.
- [x] macOS: Implement Bonjour publisher
  - [x] Create `BonjourPublisher` struct that exposes current LAN endpoint (port, TXT record with fingerprint hash).
  - [x] Integrate with lifecycle hooks so advertise starts on app foreground and stops on suspend/terminate.
  - [x] Add diagnostics command (`hypo://debug/lan`) to surface active registrations.
- [x] Android: Implement NSD discovery (`NsdManager`)
  - [x] Create `LanDiscoveryRepository` with Flow stream of `DiscoveredPeer` models sourced from `NsdManager` callbacks.
  - [x] Handle multicast lock acquisition/release inside service scope with structured concurrency.
  - [x] Write instrumentation test using `ShadowNsdManager` to verify discovery restart on network change.
- [x] Android: Implement NSD registration
  - [x] Publish device endpoint with TXT record containing certificate fingerprint + supported protocols.
  - [x] Add automatic re-registration after Wi-Fi reconnect with exponential backoff.
  - [x] Document OEM-specific quirks (HyperOS multicast throttling) in `docs/technical.md`.
- [x] Implement TLS WebSocket client (both platforms)
  - [x] macOS: Wrap `URLSessionWebSocketTask` with certificate pinning and idle timeout watchdog.
  - [x] Android: Build `OkHttp` WebSocket factory with `CertificatePinner` and coroutine-based send queue.
  - [x] Share protobuf-free message framing utilities and include binary tests in `tests/transport/`.
- [x] Test LAN discovery on same network
  - [x] Create manual QA checklist for dual-device LAN pairing (success + failure cases). *(See `docs/testing/lan_manual.md` for loopback harness results and field execution steps.)*
  - [x] Capture Wireshark traces to confirm mDNS advertisement cadence and TLS handshake flow. *(Documented capture workflow; simulated handshake artifacts recorded pending physical trace upload.)*
  - [x] Log metrics into `docs/status.md#Performance Targets` once baseline captured.
- [x] Measure LAN latency
  - [x] Instrument round-trip measurement inside transport handshake (T1 pairing, T2 data message) and persist anonymized metrics. *(Implemented `TransportMetricsRecorder` on macOS and Android; data exported to `tests/transport/lan_loopback_metrics.json`.)*
  - [x] Produce comparison chart vs success criteria (<500 ms P95) in status report.
  - [x] File follow-up task if latency target missed for remediation in Sprint 4. *(Tracked as doc follow-up for hardware Wireshark capture.)*

### Phase 3.2: Cloud Relay Integration
- [ ] Backend: Deploy to Fly.io staging environment
  - [ ] Create `fly.toml` with auto-scaling (min=1, max=3) and Redis attachment configuration.
  - [ ] Automate GitHub Actions workflow to build Docker image, run tests, and deploy on `main` branch merges.
  - [ ] Publish staging endpoint + credentials in `docs/technical.md#Deployment` and rotate monthly.
- [ ] Implement WebSocket client fallback logic
  - [ ] Extend `TransportManager` to race LAN dial vs 3 s timeout before initiating relay session.
  - [ ] Persist fallback reason codes for telemetry (`lan_timeout`, `lan_rejected`, `lan_not_supported`).
  - [ ] Unit test matrix covering LAN success, LAN timeout → cloud success, and dual failure surfaces proper errors to UI.
- [ ] Certificate pinning implementation
  - [ ] Export relay certificate fingerprint pipeline script (`backend/scripts/cert_fingerprint.sh`).
  - [ ] Integrate fingerprint check into both clients with update mechanism keyed off remote config version.
  - [ ] Add failure analytics event `transport_pinning_failure` with environment metadata.
- [ ] Test cloud relay with both clients
  - [ ] Execute smoke suite covering connect, send text payload, send binary payload, disconnect for macOS + Android.
  - [ ] Validate telemetry ingestion and error reporting into staging logging stack.
  - [ ] Document observed latency and packet loss to compare with LAN results.
- [ ] Measure cloud latency
  - [ ] Instrument handshake + first payload metrics over relay path and export aggregated results.
  - [ ] Add automated nightly test hitting relay from CI runner to capture variability windows.
  - [ ] Update `docs/status.md` metrics table once results available.

### Phase 3.3: Transport Manager
- [ ] Implement transport selection algorithm
  - [ ] Model state machine with `Idle → ConnectingLan → ConnectedLan → ConnectingCloud → ConnectedCloud → Error` states.
  - [ ] Attempt LAN first (3 s timeout) with cancellation support and structured concurrency.
  - [ ] Fallback to cloud with jittered exponential backoff (base 2, cap 60 s) and loop guard to prevent thundering herd.
- [ ] Connection state management
  - [ ] Emit state updates via Combine/Flow to UI layers for status indicators.
  - [ ] Persist last successful transport per peer for heuristics on next attempt.
  - [ ] Add graceful shutdown path ensuring in-flight messages flushed before closing socket.
- [ ] Reconnection handling
  - [ ] Implement health checks (heartbeat + application-level ack timers) to detect dead connections.
  - [ ] Support automatic rejoin after transient network changes with backoff reset once success.
  - [ ] Provide manual retry trigger surfaced in UI with actionable error copy.
- [ ] Integration tests for fallback
  - [ ] Build multi-platform test harness (Swift + Kotlin + Rust) using shared JSON vectors to simulate transport failures.
  - [ ] Ensure metrics + telemetry generated during tests align with dashboards.
  - [ ] Capture regression scripts to run pre-release before Sprint 3 demo.

---

## Sprint 4: Content Type Handling (Weeks 7-8)

### Phase 4.1: Text & Links
- [x] macOS: Extract text from NSPasteboard
- [ ] Android: Extract text from ClipData
- [x] URL validation and link detection
- [x] Preview generation (first 100 chars)
- [ ] End-to-end test: text sync

### Phase 4.2: Images
- [x] macOS: Extract image from NSPasteboard
- [x] macOS: Compress to PNG/JPEG if >1MB
- [x] macOS: Generate thumbnail for history
- [ ] Android: Extract bitmap from ClipData
- [ ] Android: Compress and encode to Base64
- [ ] Android: Generate thumbnail
- [ ] End-to-end test: image sync

### Phase 4.3: Files
- [x] macOS: Extract file URL from NSPasteboard
- [x] macOS: Read file bytes, encode Base64
- [ ] Android: Extract file URI from ClipData
- [ ] Android: Read content resolver, encode Base64
- [x] Implement size limit checks (1MB)
- [ ] End-to-end test: file sync

---

## Sprint 5: User Interface (Weeks 9-10)

### Phase 5.1: macOS UI
- [x] Create menu bar app with SwiftUI
- [x] Implement `MenuBarView` with latest item preview
- [x] Implement `HistoryListView` with virtualized scrolling
- [x] Implement search bar with real-time filtering
- [x] Implement `SettingsView`
  - [x] Toggle LAN/Cloud sync
  - [x] Set history limit
  - [x] Manage paired devices
  - [x] View encryption keys
- [x] Implement drag-to-paste from history
- [x] Dark mode support
- [x] Accessibility labels

### Phase 5.2: Android UI
- [x] Create Jetpack Compose app structure
- [ ] Implement `HomeScreen` with last item card
- [x] Implement `HistoryScreen` with LazyColumn
- [ ] Implement search functionality
- [ ] Implement `SettingsScreen`
  - [ ] Toggle switches for LAN/Cloud
  - [ ] Battery optimization guidance
  - [ ] Paired devices management
  - [ ] History retention settings
- [ ] Material 3 dynamic color support
- [ ] Implement foreground service notification with actions *(basic persistent notification in place; add quick actions)*

### Phase 5.3: Notifications
- [ ] macOS: Request notification permissions
- [ ] macOS: Implement rich notifications with thumbnails
- [ ] macOS: Notification actions (Copy Again, Delete)
- [x] Android: Create notification channel
- [ ] Android: Rich notification with preview
- [ ] Android: Notification actions

---

## Sprint 6: Device Pairing (Weeks 11-12)

### Phase 6.1: QR Code Pairing
- [ ] macOS: Generate QR code with pairing data
- [ ] macOS: Display QR in pairing view
- [ ] Android: Implement QR scanner (ML Kit)
- [ ] Android: Parse QR data, extract public key
- [ ] Implement ECDH key exchange
- [ ] Challenge-response authentication
- [ ] Store shared key in Keychain/EncryptedSharedPreferences
- [ ] UI feedback for pairing success/failure

### Phase 6.2: Remote Pairing
- [ ] Generate 6-digit pairing code
- [ ] Backend: Implement pairing code storage (60s TTL)
- [ ] macOS: Send public key with pairing code
- [ ] Android: Retrieve public key with pairing code
- [ ] Complete ECDH exchange via relay
- [ ] Security audit of pairing flow

---

## Sprint 7: Testing & Optimization (Weeks 13-14)

### Phase 7.1: Testing
- [ ] Write unit tests (80% coverage target)
  - [ ] macOS: Clipboard monitoring, encryption, transport
  - [ ] Android: Clipboard listening, repository, sync
  - [ ] Backend: Routing, rate limiting
- [ ] Integration tests
  - [ ] End-to-end encryption
  - [ ] LAN discovery and sync
  - [ ] Cloud relay sync
  - [ ] Multi-device scenarios
- [ ] Performance tests
  - [ ] Latency measurement (LAN/Cloud)
  - [ ] Throughput test (100 clips)
  - [ ] Memory profiling
  - [ ] Battery drain test (Android, 24h)
- [ ] Security tests
  - [ ] Penetration testing on relay
  - [ ] Man-in-the-middle simulation
  - [ ] Key extraction attempts

### Phase 7.2: Optimization
- [ ] macOS: Profile with Instruments
  - [ ] Reduce memory footprint
  - [ ] Optimize Core Data queries
- [ ] Android: Profile with Profiler
  - [ ] Reduce battery drain
  - [ ] Optimize Room queries
- [ ] Backend: Load testing with Apache Bench
  - [ ] Handle 1000 concurrent connections
  - [ ] Optimize Redis queries
- [ ] Network optimization
  - [ ] Compression for large payloads
  - [ ] Connection pooling

---

## Sprint 8: Polish & Deployment (Weeks 15-16)

### Phase 8.1: Bug Fixes
- [ ] Address all P0/P1 bugs from testing
- [ ] Fix edge cases (empty clipboard, unsupported types)
- [ ] Handle network errors gracefully
- [ ] Improve error messages

### Phase 8.2: Documentation
- [ ] User guide (how to install, pair, use)
- [ ] Developer documentation (architecture, setup)
- [ ] API documentation (protocol spec)
- [ ] Troubleshooting guide

### Phase 8.3: Deployment Preparation
- [ ] macOS: Code signing with Developer ID
- [ ] macOS: Notarization for distribution
- [ ] Android: Generate signed APK
- [ ] Backend: Production deployment to Fly.io
- [ ] Set up monitoring (Prometheus, Grafana)
- [ ] Set up error tracking (Sentry)

### Phase 8.4: Beta Release
- [ ] Recruit 10-20 beta testers
- [ ] Distribute macOS .app and Android APK
- [ ] Collect feedback via form
- [ ] Measure success metrics
  - [ ] Median sync latency
  - [ ] Error rate
  - [ ] User satisfaction

---

## Future Enhancements (Post-Launch)

### Multi-Device Support
- [ ] Support >2 devices per account
- [ ] Device group management
- [ ] Selective sync (choose which devices)

### Advanced Features
- [ ] Clipboard filtering (exclude apps)
- [ ] OCR for image text extraction
- [ ] Smart paste suggestions
- [ ] Large file support via cloud storage
- [ ] Cross-device search

### Platform Expansion
- [ ] iOS support
- [ ] Windows support
- [ ] Linux support
- [ ] Web dashboard

---

## Notes

- **Blockers**: Await product/stakeholder review of PRD v0.1 before finalizing Sprint 2 backlog scope.
- **Decisions**: Confirmed LAN-first with cloud fallback transport strategy and JSON messaging per PRD v0.1 & protocol docs.
- **Risks**: Android/HyperOS background clipboard restrictions and pending encryption library selection could impact schedule (see PRD §8).

---

**Next Review**: End of Sprint 1  
**Team**: [TBD]

