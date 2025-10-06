# Hypo Project Status

**Last Updated**: October 5, 2025
**Current Sprint**: Sprint 3 - Transport Layer (Execution)
**Project Phase**: Core Platform Bring-up
**Overall Progress**: 35%

---

## 🎯 Current Milestone: Core Sync Engine Completion

### Completed ✅
- [x] Project inception and PRD analysis
- [x] Created foundational architecture (docs/architecture.mermaid)
- [x] Wrote comprehensive technical specification (docs/technical.md)
- [x] Defined development tasks and sprints (tasks/tasks.md)
- [x] Created project status tracking (docs/status.md)
- [x] Initialize project structure (mono-repo layout)
- [x] Created comprehensive README with project overview
- [x] Defined protocol specification (docs/protocol.md)
- [x] Published JSON Schema for protocol validation (docs/protocol.schema.json)
- [x] Documented error catalogue, retry, and telemetry guidance for control messages (docs/protocol.md §4.4)
- [x] Initialized backend Rust project structure
- [x] Initialized Android project structure with Gradle
- [x] Bootstrapped macOS Swift package + SwiftUI menu bar shell
- [x] Implemented Android foreground sync service, Room persistence, and Compose history UI
- [x] Added Redis-backed WebSocket session manager with expanded tests
- [x] Wired Swift Package into reusable Xcode workspace (`macos/HypoApp.xcworkspace`)
- [x] Completed cross-platform cryptography library evaluation (`docs/crypto_research.md`)
- [x] Implemented backend AES-256-GCM facade with RFC 5116 vectors and tests
- [x] Added macOS CryptoKit-based encryption service with deterministic nonce support and unit coverage
- [x] Delivered Android AES-256-GCM CryptoService with HKDF key derivation and unit coverage
- [x] Added MockK-backed Android clipboard sync tests for repository fan-out
- [x] Published shared crypto interoperability vectors (`tests/crypto_test_vectors.json`)
- [x] Added backend session manager integration tests covering broadcast and direct routing
- [x] Provisioned Android SDK + Gradle wrapper for reproducible CI-friendly unit tests
- [x] Realigned Android project to Kotlin 1.9.22 and restored CryptoService/SyncCoordinator test pass
- [x] Documented Android test workflow alongside macOS/backend build verification
- [x] Added automated SDK bootstrap script for headless Android unit tests with JDK 17 compatibility
- [x] Wired encrypted clipboard envelopes end-to-end across macOS, Android, and the relay with shared tests
- [x] Implemented Android SyncEngine with secure key storage, encrypted envelope emission, and unit coverage for send/decode paths
- [x] Finalized device pairing flow specification and QR payload schema (PRD §6.1/6.2, Technical Spec §3.2)

### In Progress 🚧
- [x] TLS WebSocket client with certificate pinning on macOS and Android
- [ ] Cloud relay staging deployment on Fly.io with telemetry wiring

### Blocked 🚫
None currently

---

## 📊 Sprint Progress

### Sprint 1: Foundation & Architecture (Weeks 1-2)
**Progress**: 60%

| Phase | Status | Completion |
|-------|--------|------------|
| Phase 1.1: Project Setup | Completed | 100% |
| Phase 1.2: Protocol Definition | Completed | 100% |
| Phase 1.3: Security Foundation | In Progress | 30% |

**Next Steps**:
1. Schedule PRD v0.1 stakeholder review and sign-off.
2. Publish success metrics dashboard derived from PRD §9.

### Sprint 2: Core Sync Engine (Weeks 3-4)
**Progress**: 100%

| Phase | Status | Completion |
|-------|--------|------------|
| Phase 2.1: macOS Client - Core | Completed | 100% |
| Phase 2.2: Android Client - Core | Completed | 100% |
| Phase 2.3: Backend Relay - Core | Completed | 100% |

**Highlights**:
1. Cross-platform AES-256-GCM modules ship with shared interoperability vectors.
2. Android unit suites execute via Gradle wrapper against the provisioned SDK/JDK 17 toolchain.
3. Backend session routing fan-out validated with integration coverage.

### Sprint 3: Transport Layer (Weeks 5-6)
**Progress**: 55%

| Phase | Status | Completion |
|-------|--------|------------|
| Phase 3.1: LAN Discovery & Connection | Completed | 100% |
| Phase 3.2: Cloud Relay Integration | In Progress | 20% |
| Phase 3.3: Transport Manager | In Progress | 15% |

**Highlights (to date)**:
1. Implemented Bonjour-based LAN discovery/publishing with lifecycle-aware `TransportManager` integration and diagnostics deep link on macOS.
2. Brought up Android NSD discovery/registration with structured concurrency plus injectable network events for deterministic unit coverage.
3. Transport specs updated with OEM multicast caveats (HyperOS) and cross-platform LAN telemetry expectations.
4. Provisioned headless Android SDK installation script so CI containers can execute Gradle unit suites without manual setup.
5. Android foreground service now boots the LAN transport manager, exposing discovered peers and restartable advertising from a shared coroutine scope.
6. Published loopback LAN latency baseline with automated metrics hooks and manual QA checklist for same-network validation.

**Next Steps**:
1. ✅ Implement LAN TLS WebSocket clients with certificate pinning and idle watchdogs on macOS and Android.
2. ✅ Capture LAN loopback latency baseline and publish manual QA checklist (`docs/testing/lan_manual.md`).
3. Deploy the Rust relay to Fly.io staging and validate telemetry/monitoring integration.
4. Complete the transport state machine (LAN-first with cloud fallback) and expand integration coverage for failure cases.

---

## 🏗️ Architecture Decisions

### Technology Stack Decisions
| Component | Decision | Rationale | Date |
|-----------|----------|-----------|------|
| macOS Client | Swift 6 + SwiftUI | Native performance, modern concurrency | Oct 1, 2025 |
| Android Client | Kotlin 1.9.22 + Compose | Modern UI, coroutines for async | Oct 6, 2025 |
| Backend Relay | Rust + Actix-web | Performance, memory safety, WebSocket support | Oct 1, 2025 |
| Storage - macOS | Core Data | Native integration, CloudKit future-proof | Oct 1, 2025 |
| Storage - Android | Room | Official Jetpack library, Flow support | Oct 1, 2025 |
| State Storage - Backend | Redis | In-memory speed, ephemeral state | Oct 1, 2025 |
| Encryption | AES-256-GCM | Industry standard, authenticated encryption | Oct 1, 2025 |
| Key Exchange | ECDH | Forward secrecy, QR code compatibility | Oct 1, 2025 |
| Transport | WebSocket | Bi-directional, real-time, wide support | Oct 1, 2025 |

### Open Questions
- [ ] Should we use Protocol Buffers instead of JSON for performance?
  - **Context**: JSON is ~30% larger but more debuggable
  - **Decision Deadline**: End of Sprint 1
- [ ] Should we support iCloud/Google Drive integration in v1?
  - **Context**: Allows >1MB file sync but adds complexity
  - **Decision Deadline**: Sprint 4
- [ ] What's our target minimum Android API level?
  - **Context**: API 26+ for stable foreground service, but API 29+ for better clipboard API
  - **Decision Deadline**: End of Sprint 1

---

## 🎨 Design Decisions

### UX Patterns
- **macOS**: Menu bar app (no Dock icon) for minimal intrusion
- **Android**: Material 3 with dynamic color matching system theme
- **Notifications**: Rich previews with actionable buttons
- **History UI**: Search-first, reverse chronological

### Content Type Priority
1. **Text** (MVP, most common use case)
2. **Links** (MVP, high value for browser workflows)
3. **Images** (Sprint 4, requires compression)
4. **Files** (Sprint 4, limited to 1MB)

---

## 📈 Metrics Tracking

### Performance Targets
| Metric | Target | Current | Status |
|--------|--------|---------|--------|
| LAN Sync Latency (P95) | < 500ms | 44 ms (loopback harness, n=5) | On Track |
| Cloud Sync Latency (P95) | < 3s | Instrumentation in progress (staging relay) | In Progress |
| Memory Usage - macOS | < 50MB | N/A | Not Measured |
| Memory Usage - Android | < 30MB | N/A | Not Measured |
| Battery Drain - Android | < 2% per day | N/A | Not Measured |
| Error Rate | < 0.1% | Telemetry schema drafted | In Progress |

### Test Coverage
| Platform | Target | Current |
|----------|--------|---------|
| macOS Client | 80% | 0% |
| Android Client | 80% | 0% |
| Backend Relay | 90% | 0% |

---

## 🐛 Known Issues

*No issues yet - project in initialization phase*

---

## 🔄 Recent Changes

### October 1, 2025
- **Initialization**: Created project from PRD
- **Documentation**: Established foundational architecture docs (architecture, technical specs, protocol)
- **Planning**: Defined 8-sprint roadmap (16 weeks to beta)
- **Backend**: Initialized Rust project with Actix-web, Redis client, rate limiter
- **Android**: Initialized project with Gradle, Compose, Hilt DI setup
- **Infrastructure**: Set up Git repository, created 38 files totaling 4600+ lines

### October 2, 2025
- **Protocol**: Added formal JSON Schema definition for clipboard/control messages to support validation tooling

### October 3, 2025
- **macOS**: Added Swift Package with SwiftUI menu bar shell, history store actor, and NSPasteboard monitor.
- **Android**: Implemented foreground clipboard sync service, Room persistence, and Compose history UI with clearing support.
- **Backend**: Added session manager for WebSocket routing plus unit tests; updated protocol schema with optional target routing field.
- **Planning**: Updated roadmap, tasks, and status dashboards to reflect coding progress and JSON-first protocol decision.

### October 5, 2025
- **Security**: Delivered shared AES-256-GCM implementations across Android, macOS, and the relay with aligned HKDF salt/info parameters and JSON-hosted test vectors.
- **Android**: Added Tink-backed CryptoService along with MockK-based SyncCoordinator tests to validate repository fan-out behaviour.
- **Backend**: Added session manager integration tests to verify broadcast fan-out and direct routing paths.

### October 6, 2025
- **Tooling**: Added Gradle wrapper + SDK provisioning scripts enabling container-friendly Android unit tests.
- **Android**: Downgraded to Kotlin 1.9.22 for Compose compatibility, restored CryptoService/SyncCoordinator unit suites, and updated manifest resources for build stability.
- **Documentation**: Refreshed README build verification and status dashboards to reflect Sprint 2 completion and new testing workflow.

### October 9, 2025
- **Transport Planning**: Documented LAN discovery, TLS transport client, and cloud relay staging rollout plans in technical spec.
- **Task Breakdown**: Expanded Sprint 3 task list with detailed sub-tasks covering instrumentation, telemetry, and QA workflows.
- **Status Update**: Updated project dashboard with Sprint 3 progress metrics and performance instrumentation status.

---

## 🎯 Next Review

**Date**: October 8, 2025 (End of Sprint 1 Week 1)  
**Focus**: Review project structure, protocol definition, and crypto library selection

---

## 📝 Notes

### Development Environment Status
- **macOS Development**: Requires macOS 26+ with Xcode 15+
- **Android Development**: Any platform with Android Studio Hedgehog+
- **Backend Development**: Any platform with Rust 1.75+

### Team Composition
- **Current**: Solo development (autonomous principal engineer)
- **Future**: May need beta testers in Sprint 8

### Risk Register
1. **Android Background Restrictions**: HyperOS may impose stricter limits than stock Android
   - *Mitigation*: Foreground service + battery optimization exemption request
2. **Apple Sandbox**: Future Mac App Store distribution may conflict with clipboard monitoring
   - *Mitigation*: Research entitlements, may need direct distribution only
3. **Encryption Performance**: AES-GCM on every clipboard update may impact latency
   - *Mitigation*: Performance testing in Sprint 7, optimize if needed

---

**Status Legend**:
- ✅ Completed
- 🚧 In Progress
- 🚫 Blocked
- ⚠️ At Risk
- 📅 Scheduled

