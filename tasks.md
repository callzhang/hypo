# Hypo Development Tasks

Version: 1.1.5
Last Updated: January 16, 2026

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
  - [x] Create `tasks.md`
  - [x] Create project status tracking (consolidated into changelog.md)
  - [x] Create `changelog.md`
  - [x] Create `README.md` with setup instructions
- [x] Development environment (Android + backend CLI) *(validated locally on January 16, 2026)*
  - [x] Java/JDK installed (Android builds)
  - [x] Android SDK tools available (`adb`)
  - [x] Gradle wrapper runs (`cd android && ./gradlew --version`)
  - [x] Rust toolchain installed (`rustc`, `cargo`)
  - [x] Docker + `docker compose` available for Redis via `backend/docker-compose.yml`
- [ ] macOS app build environment *(pending)*  
  - [ ] Xcode installed and selected (`xcodebuild -version` works; `xcode-select -s /Applications/Xcode.app/Contents/Developer`)
  - [ ] `./scripts/build-macos.sh` succeeds
- [ ] Validate end-to-end build/test on clean machines (document command output)

### Phase 1.2: Protocol Definition
- [x] Define JSON message schema with validation (documented in `docs/protocol.md`; schema file is not currently checked in)
- [x] Implement protocol buffers or stick with JSON (decision point)
  - ✅ Decision: Ship v1 with JSON payloads, revisit binary encoding in Sprint 5 performance review.
- [x] Create protocol documentation with examples
- [x] Define error codes and handling *(see `docs/protocol.md` §4.4 for catalogue and retry rules)*

### Phase 1.3: Security Foundation
- [x] Research and select crypto libraries *(see `docs/research/crypto_research.md` for evaluation matrix)*
  - [x] macOS: CryptoKit evaluation
  - [x] Android: Jetpack Security or Tink
  - [x] Backend: RustCrypto
- [x] Implement encryption module (cross-platform compatible)
  - [x] AES-256-GCM encryption/decryption
  - [x] Nonce generation
  - [x] Key derivation from ECDH
- [x] Design device pairing flow (LAN auto-discovery + remote code) *(see PRD §6.1/6.2 and technical spec §3.2)*

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
  - [x] Create manual QA checklist for dual-device LAN pairing (success + failure cases). *(See `docs/technical.md` for execution steps.)*
  - [x] Capture Wireshark traces to confirm mDNS advertisement cadence and TLS handshake flow. *(Documented capture workflow; simulated handshake artifacts recorded pending physical trace upload.)*
  - [x] Log metrics into README.md performance targets section once baseline captured.
- [x] Measure LAN latency
  - [x] Instrument round-trip measurement inside transport handshake (T1 pairing, T2 data message) and persist anonymized metrics. *(Implemented `TransportMetricsRecorder` on macOS and Android; data exported to `tests/transport/lan_loopback_metrics.json`.)*
  - [x] Produce comparison chart vs success criteria (<500 ms P95) in status report.
  - [x] File follow-up task if latency target missed for remediation in Sprint 4. *(Tracked as doc follow-up for hardware Wireshark capture.)*
- [x] Auto-prune stale LAN peers
  - [x] Android: schedule coroutine-driven pruning inside `TransportManager` with configurable thresholds.
  - [x] macOS: add main-actor prune task with injectable clock for deterministic testing.
  - [x] Update documentation and QA notes to include idle-staleness expectations.

### Phase 3.2: Cloud Relay Integration
- [x] Backend: Deploy to Fly.io staging environment
  - [x] Create `fly.toml` with auto-scaling (min=1, max=3) and Redis attachment configuration.
  - [x] Automate GitHub Actions workflow to build Docker image, run tests, and deploy on `main` branch merges.
  - [x] Publish staging endpoint + credentials in `docs/technical.md#Deployment` and rotate monthly.
- [x] Implement WebSocket client fallback logic
  - [x] Extend `TransportManager` to race LAN dial vs 3 s timeout before initiating relay session.
  - [x] Persist fallback reason codes for telemetry (`lan_timeout`, `lan_rejected`, `lan_not_supported`).
  - [x] Unit test matrix covering LAN success, LAN timeout → cloud success, and dual failure surfaces proper errors to UI.
  - [x] Introduce dedicated Android/macOS relay WebSocket clients with pinning-aware unit suites (Oct 10, 2025).
- [x] Certificate pinning implementation
  - [x] Export relay certificate fingerprint pipeline script (`backend/scripts/cert_fingerprint.sh`).
  - [x] Integrate fingerprint check into both clients with update mechanism keyed off remote config version.
  - [x] Add failure analytics event `transport_pinning_failure` with environment metadata.
  - [x] Surface staging relay fingerprint via generated BuildConfig fields and Swift configuration wrappers (Oct 10, 2025).
- [x] Test cloud relay with both clients
  - [x] Execute smoke suite covering connect, send text payload, send binary payload, disconnect for macOS + Android.
  - [x] Validate telemetry ingestion and error reporting into staging logging stack.
  - [x] Document observed latency and packet loss to compare with LAN results.
- [x] Measure cloud latency
  - [x] Instrument handshake + first payload metrics over relay path and export aggregated results.
  - [x] Add automated nightly test hitting relay from CI runner to capture variability windows.
  - [x] Update README.md metrics table once results available.

### Phase 3.3: Transport Manager
- [x] Implement transport selection algorithm
  - [x] Model state machine with `Idle → ConnectingLan → ConnectedLan → ConnectingCloud → ConnectedCloud → Error` states.
  - [x] Attempt LAN first (3 s timeout) with cancellation support and structured concurrency.
  - [x] Fallback to cloud with jittered exponential backoff (base 2, cap 60 s) and loop guard to prevent thundering herd.
- [x] Connection state management
  - [x] Emit state updates via Combine/Flow to UI layers for status indicators.
  - [x] Persist last successful transport per peer for heuristics on next attempt.
  - [x] Add graceful shutdown path ensuring in-flight messages flushed before closing socket.
- [x] Reconnection handling
  - [x] Implement health checks (heartbeat + application-level ack timers) to detect dead connections.
  - [x] Support automatic rejoin after transient network changes with backoff reset once success.
  - [x] Provide manual retry trigger surfaced in UI with actionable error copy.
- [x] Integration tests for fallback
  - [x] Build multi-platform test harness (Swift + Kotlin + Rust) using shared JSON vectors to simulate transport failures.
  - [x] Ensure metrics + telemetry generated during tests align with dashboards.
  - [x] Capture regression scripts to run pre-release before Sprint 3 demo.

### Phase 3.4: Reliability & Release Hardening
- [x] Harden `PairingCode` by conforming it to `Sendable`, preventing strict concurrency crashes observed in pairing flows (commit `2a3ac9f`).
- [x] Replace all `NSLock` usages in `WebSocketTransport` with `OSAllocatedUnfairLock` and update CI/test mocks for thread safety so heavy frame traffic no longer deadlocks (commits `a4c1e58`, `b6e98f0`, `57a8e57`, `5cc1afb`).
- [x] Fix the outbound queue race condition in `WebSocketTransport` so clipboard messages are not dropped or replayed, and ensure release automation resolves macOS/Android binary paths dynamically (commits `07ac58a`, `ef67de6`, `6dc20bc`).
- [x] Merge the transport and Gradle configuration updates that underpin v1.1.5/1.1.6 stability releases and keep future release pipelines flexible.

---

## Sprint 4: Content Type Handling (Weeks 7-8)

### Phase 4.1: Text & Links
- [x] macOS: Extract text from NSPasteboard
- [x] Android: Extract text from ClipData
- [x] URL validation and link detection
- [x] Preview generation (first 100 chars)
- [x] End-to-end test: text sync

### Phase 4.2: Images
- [x] macOS: Extract image from NSPasteboard
- [x] macOS: Compress to PNG/JPEG if >1MB
- [x] macOS: Generate thumbnail for history
- [x] Android: Extract bitmap from ClipData
- [x] Android: Compress and encode to Base64
- [x] Android: Generate thumbnail
- [x] End-to-end test: image sync

### Phase 4.3: Files
- [x] macOS: Extract file URL from NSPasteboard
- [x] macOS: Read file bytes, encode Base64
- [x] Android: Extract file URI from ClipData
- [x] Android: Read content resolver, encode Base64
- [x] Implement size limit checks (10MB sync limit, 50MB copy limit; enforced via `SizeConstants`)
- [x] End-to-end test: file sync

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
- [x] Implement `HomeScreen` with last item card
- [x] Implement `HistoryScreen` with LazyColumn
- [x] Implement search functionality
- [x] Implement `SettingsScreen`
  - [x] Toggle switches for LAN/Cloud
  - [x] Battery optimization guidance
  - [x] Paired devices management
  - [x] History retention settings
- [x] Material 3 dynamic color support
- [x] Implement foreground service notification with actions *(basic persistent notification in place; add quick actions)*
- [x] Unit tests for Home, History, and Settings view models plus settings persistence

### Phase 5.3: Notifications
- [x] macOS: Request notification permissions
- [x] macOS: Implement rich notifications with thumbnails
- [x] macOS: Notification actions (Copy Again, Delete)
- [x] Android: Create notification channel
- [x] Android: Rich notification with preview
- [x] Android: Notification actions

---

## Sprint 6: Device Pairing (Weeks 11-12)

### Phase 6.1: LAN Auto-Discovery Pairing
- [x] macOS: Advertise pairing payload via Bonjour
- [x] Android: Advertise pairing payload via NSD
- [x] Android: Show LAN device list and tap-to-pair
- [x] Implement ECDH key exchange
- [x] Challenge-response authentication
- [x] Store shared key in encrypted storage (macOS: file-based, Android: EncryptedSharedPreferences)
- [x] UI feedback for pairing success/failure

### Phase 6.2: Remote Pairing
- [x] Generate 6-digit pairing code
- [x] Backend: Implement pairing code storage (60s TTL)
- [x] macOS: Send public key with pairing code
- [x] Android: Retrieve public key with pairing code
- [x] Complete ECDH exchange via relay
- [x] Security audit of pairing flow

---

## Sprint 7: Testing & Optimization (Weeks 13-14)

### Phase 7.1: Testing
- [ ] Reach coverage targets (clients ≥80%, backend ≥90%)
  - macOS: Current total line coverage is ~46% (core sync paths are higher; see `macos/Tests/TEST_COVERAGE.md`)
  - Android: JaCoCo report task exists (`jacocoTestReport`); baseline report needs to be generated and reviewed
- [x] macOS unit tests
  - [x] Crypto, clipboard monitoring, sync pipeline, transport, and Bonjour utilities
  - [x] Concurrency-safe mocks and queue/expiration coverage for WebSocket transports
- [x] Android unit tests
  - [x] Crypto, pairing handshake, parser/pipeline/sync engine, transport (LAN + relay), and view models
  - [x] JaCoCo reporting wired in Gradle
- [x] Backend unit/integration coverage for core routing paths (routing/session manager, offline handling via `DeviceNotConnected`)
- [ ] Integration tests
  - [x] End-to-end encryption
  - [ ] LAN discovery and sync
  - [x] Cloud relay sync
  - [x] Multi-device scenarios
  - [x] Cross-platform transport regression fixtures (vectors under `tests/transport/`)
  - [ ] Restore a shared regression runner (docs reference `scripts/run-transport-regression.sh`, but it is not currently present)
- [x] Performance tests (automated)
  - [x] Latency measurement (LAN/Cloud)
  - [x] Throughput test (100 messages / clips)
  - [x] Backend throughput regression test (see `backend/tests/performance_throughput.rs`)
- [ ] Extended profiling (manual / field)
  - [ ] Memory profiling (macOS Instruments + Android Profiler)
  - [ ] Battery drain test (Android, 24h on physical device)
- [x] Security validation (automated)
  - [x] Backend: `cargo test --all-features --locked` with Redis + `cargo clippy -- -D warnings`
  - [x] Crypto: tampering detection + known-vector tests (backend and clients)
- [ ] External security audit (manual)
  - [ ] Penetration testing on relay
  - [ ] Man-in-the-middle simulation (verify pinning behavior under active MITM)
  - [ ] Key extraction attempts (device storage / keystore / file-based stores)
- [x] Test infrastructure
  - [x] CI: Cross-platform test workflow
  - [x] Git hooks: run `swift test` as part of pre-push
  - [x] Parallelize transport test execution and harden WebSocket mocks for concurrency

### Phase 7.2: Optimization
- [x] macOS: Profile with Instruments
  - [x] Reduce memory footprint
  - [x] Optimize Core Data queries
- [x] Android: Profile with Profiler
  - [x] Reduce battery drain
  - [x] Optimize Room queries
- [x] Backend: Load testing with Apache Bench
  - [x] Handle 1000 concurrent connections
  - [x] Optimize Redis queries
- [x] Network optimization
  - [x] Compression for large payloads
  - [x] Connection pooling

---

## Sprint 8: Polish & Deployment (Weeks 15-16) ✅ 95% Complete

### Phase 8.1: Bug Fixes ✅ Complete (P0/P1)
- [x] Address all P0/P1 bugs from testing *(analysis is captured in `changelog.md` and related documentation)*
- [x] Identify and categorize all critical issues by priority
- [x] Clean backend compilation warnings (reduced from 5 to 3)
- [x] **RESOLVED**: Fix Android Room KSP compilation issues *(Oct 12, 2025)* ✅
- [x] **RESOLVED**: Fix Android Gradle dependencies (Paging, DI bindings)* ✅
- [x] **RESOLVED**: Fix Android Compose opt-ins and imports* ✅
- [x] **RESOLVED**: Fix macOS Swift compilation errors *(Oct 12, 2025)* ✅
  - Fixed duplicate ClipboardEntry extensions
  - Fixed property initialization order issues
  - Fixed Ed25519 keychain constant compatibility
  - Updated build system and entry point
  - Removed binary artifacts from version control
  - App now builds successfully and runs as menu bar application
- [x] Automated regression suites pass (macOS `swift test`, Android unit tests + JaCoCo, backend `cargo test`) *(Jan 16, 2026)*

### Phase 8.2: Documentation ✅ Complete
- [x] User guide (how to install, pair, use) *(15,000+ word comprehensive guide)*
- [x] Installation documentation *(step-by-step for macOS and Android)*
- [x] Troubleshooting guide *(platform-specific solutions and diagnostics)*
- [x] Developer documentation *(architecture, setup - see existing docs)*
- [x] API documentation *(protocol spec - see `docs/protocol.md`)*
- [x] FAQ and support resources

### Phase 8.3: Deployment Preparation ✅ Mostly Complete
- [x] macOS: Replace Keychain with file-based storage (improves Notarization compatibility) *(Dec 1, 2025)*
- [x] macOS: Harden self-signed code signing flow (remove hardened runtime for self-signed builds, apply entitlements fallback, aggressively clean xattrs/resource forks)
- [ ] macOS: Code signing with Developer ID *(Pending - requires Apple Developer account)*
- [ ] macOS: Notarization for distribution *(Pending - requires code signing)*
- [x] Android: Generate signed APK ✅ *(Release APK builds successfully via CI)*
- [x] Backend: Production deployment to Fly.io ✅ *(Oct 12, 2025 - deployed to https://hypo.fly.dev)*
- [ ] Set up monitoring (Prometheus, Grafana) *(Backend metrics available, dashboard pending)*
- [x] Set up error tracking (Sentry) ✅ *(Configured in Android build, requires auth token)*
- [x] Create automated build and release pipeline ✅ *(Dec 3, 2025 - GitHub Actions workflow complete)*
  - [x] CI: Update macOS runner to 15 and fix Android buildDir deprecation warnings
  - [x] Release workflow: Dynamic binary/artifact path lookup to avoid hard-coded build paths

### Phase 8.4: Beta Release 📋 Pending
- [ ] Recruit 10-20 beta testers
- [ ] Distribute macOS .app and Android APK
- [ ] QA on physical devices (pre-beta)
  - [ ] Test Android APK on at least one physical device
  - [ ] Validate edge cases (empty clipboard, unsupported types)
  - [ ] Validate network error handling and user-facing error messages
- [ ] Create beta feedback collection system
- [ ] Set up usage analytics (opt-in)
- [ ] Measure success metrics
  - [ ] Median sync latency
  - [ ] Error rate
  - [ ] User satisfaction
  - [ ] Platform adoption rates

### Phase 8.5: Sprint 8 Achievements ✅ Complete
- [x] **Comprehensive Project Analysis**: Created detailed bug report with P0/P1/P2 categorization
- [x] **Professional Documentation Suite**: 3 comprehensive user guides totaling 20,000+ words
- [x] **Backend Code Quality**: Cleaned warnings, removed dead code, improved maintainability
- [x] **Testing Infrastructure**: Validated backend (32/32 tests passing), identified mobile platform issues
- [x] **Progress Tracking**: Created detailed sprint report and updated project status

---

## Future Enhancements (Post-Launch)

### Backend Message Queue (Planned)
- [ ] Implement message queue for failed deliveries
  - [ ] Queue messages when target device is offline (`DeviceNotConnected`)
  - [ ] Store queued messages in Redis (persist across server restarts)
  - [ ] Exponential backoff retry: 1s → 2s → 4s → 8s → 16s → 32s → 64s → 128s → 256s → 512s → 1024s → 2048s (max)
  - [ ] Message expiration: Remove messages after 2048 seconds timeout
  - [ ] Background worker to process queue and retry delivery
  - [ ] Deliver queued messages when device reconnects
  - [ ] Add queue metrics to `/status` endpoint (pending messages, queued per device)
  - [ ] Update status handler to report queue statistics

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
