# Hypo Project Status

**Last Updated**: October 3, 2025
**Current Sprint**: Sprint 1 - Foundation & Architecture
**Project Phase**: Initialization
**Overall Progress**: 14%

---

## 🎯 Current Milestone: Foundation Setup

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
- [x] Added Redis-backed WebSocket session manager with tests

### In Progress 🚧
- [ ] Finalize macOS Xcode workspace wiring (SPM package hooked up, throttling pending)
- [ ] Research and select cryptographic libraries
- [ ] Set up local development environments for testing

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
| Phase 1.3: Security Foundation | Pending | 0% |

**Next Steps**:
1. Wire Swift package into Xcode workspace and implement clipboard throttling controls.
2. Extend backend validation tests to assert error catalogue coverage and retry hints.
3. Evaluate CryptoKit, Tink, and RustCrypto suites for AES-256-GCM + ECDH support.

---

## 🏗️ Architecture Decisions

### Technology Stack Decisions
| Component | Decision | Rationale | Date |
|-----------|----------|-----------|------|
| macOS Client | Swift 6 + SwiftUI | Native performance, modern concurrency | Oct 1, 2025 |
| Android Client | Kotlin 2.0 + Compose | Modern UI, coroutines for async | Oct 1, 2025 |
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
| LAN Sync Latency (P95) | < 500ms | N/A | Not Measured |
| Cloud Sync Latency (P95) | < 3s | N/A | Not Measured |
| Memory Usage - macOS | < 50MB | N/A | Not Measured |
| Memory Usage - Android | < 30MB | N/A | Not Measured |
| Battery Drain - Android | < 2% per day | N/A | Not Measured |
| Error Rate | < 0.1% | N/A | Not Measured |

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

