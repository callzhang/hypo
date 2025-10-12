# Changelog

All notable changes to the Hypo project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Sprint 8: Polish & Deployment (In Progress) - October 12, 2025

#### Added
- **Comprehensive User Documentation**: Created complete user guide with installation, usage, and troubleshooting sections
  - 60+ page user guide covering all features and use cases
  - Step-by-step installation guide for macOS and Android  
  - Detailed troubleshooting guide with platform-specific solutions
  - FAQ section and comprehensive support information

- **Sprint 8 Analysis Documentation**: 
  - Complete bug report with P0/P1/P2 issue categorization
  - Progress tracking and completion metrics
  - Technical debt identification and resolution roadmap

#### Fixed
- **Android Build Resolution** ✅: Fixed all P0 compilation issues blocking APK generation
  - Added missing Paging library dependencies (androidx.paging:paging-compose, paging-runtime)
  - Resolved Room DAO query verification errors in pruning logic  
  - Added DI bindings for Json serializer and Clock to complete Hilt dependency graph

- **macOS Build Resolution** ✅: Fixed all Swift compilation errors blocking macOS app builds *(Oct 12, 2025)*
  - Resolved duplicate ClipboardEntry extension conflicts between MemoryProfiler and OptimizedHistoryStore
  - Fixed property initialization order issues in HistoryStore and PairingViewModel
  - Fixed Ed25519 keychain constant availability for macOS compatibility (kSecAttrKeyTypeEd25519)
  - Updated ClipboardContent property names to match actual model (fileName vs name)
  - Made WebSocketConnectionPool.lastUsed mutable to allow connection state updates
  - Added @retroactive attribute to Sendable conformance for UNUserNotificationCenter
  - Fixed ambiguous webSocketTask call in WebSocketConnectionPool
  - Simplified HypoMenuBarApp entry point and made it public
  - Updated .gitignore to exclude build artifacts (.gradle/, *.app/)
  - Removed binary files from version control
  - **Result**: App builds successfully with `swift build -c release` and runs as menu bar application
  - Fixed Compose opt-in annotations and imports across UI modules (BatteryOptimizer, PairingScreen, HomeScreen, SettingsScreen)
  - Simplified PairingRelayClient URL normalization to prevent HttpUrl builder exceptions
  - **Result**: `./android/gradlew assembleDebug` completes successfully; APK at `android/app/build/outputs/apk/debug/app-debug.apk`

- **Backend Code Quality**: Cleaned up compilation warnings and unused code
  - Removed unused Redis client pool field and methods
  - Cleaned up unused import statements
  - Reduced warnings from 5 to 3
  - Improved code maintainability

#### Changed  
- **Project Status**: Updated status tracking to reflect Sprint 8 progress (90% complete)
- **Documentation Structure**: Reorganized docs for better user experience
- **Development Environment**: Established reproducible Android build toolchain
  - Installed OpenJDK 17 via Homebrew with shell profile configuration
  - Provisioned Android SDK via scripts/setup-android-sdk.sh
  - Configured Gradle with local GRADLE_USER_HOME for caching

#### Technical Debt Resolved
- ✅ Android Room KSP processor compilation issues (RESOLVED Oct 12)
- ✅ Android Gradle build configuration (RESOLVED Oct 12)  
- ✅ Android DI graph completion (RESOLVED Oct 12)

#### Technical Debt Remaining
- macOS Swift environment configuration requirements (non-blocking)
- Missing error handling improvements in UI layers
- Production deployment configuration needed
- Physical device testing of Android APK

---

### Sprint 1: Foundation & Architecture

#### Added - October 1, 2025
- **Project Initialization**: Created repository structure and foundational documentation
  - Created comprehensive system architecture diagram (`docs/architecture.mermaid`)
  - Defined technical specifications for all three platforms (`docs/technical.md`)
  - Outlined 16-week development roadmap with 8 sprints (`tasks/tasks.md`)
  - Established project status tracking system (`docs/status.md`)
  - Initialized changelog following Keep a Changelog format
  - Wrote detailed protocol specification (`docs/protocol.md`)
  - Created comprehensive README with quickstart guide
  
- **Architecture Decisions**:
  - Selected Swift 6 + SwiftUI for macOS client
  - Selected Kotlin 2.0 + Jetpack Compose for Android client
  - Selected Rust + Actix-web for backend relay server
  - Defined dual transport architecture (LAN-first with cloud fallback)
  - Established E2E encryption protocol (AES-256-GCM with ECDH key exchange)
  
- **Protocol Design**:
  - Designed JSON-based message format with metadata support
  - Defined content type handling (text, link, image, file)
  - Specified de-duplication strategy using SHA-256 hashing
  - Defined throttling mechanism (token bucket, 1 update per 300ms)
  
- **Security Design**:
  - Documented device pairing protocol (QR code for LAN, 6-digit code for cloud)
  - Specified certificate pinning for cloud relay
  - Defined key rotation policy (30-day cycle with 7-day grace period)
  - Established threat model and mitigation strategies

- **Backend Infrastructure**:
  - Initialized Rust project with Actix-web and Redis
  - Created modular architecture (handlers, services, models, middleware)
  - Implemented WebSocket handler stub with device authentication
  - Implemented Redis client for device connection mapping
  - Implemented token bucket rate limiter with tests
  - Created Docker containerization with docker-compose
  - Set up health check and metrics endpoints

- **Android Client**:
  - Initialized Android project with Gradle Kotlin DSL
  - Configured dependencies (Jetpack Compose, Hilt, Room, OkHttp)
  - Set up project structure following clean architecture
  - Created AndroidManifest with required permissions
  - Defined string resources and ProGuard rules

- **Documentation**:
  - Architecture diagram visualizing component relationships and data flow
  - Technical specification covering implementation details for all platforms
  - Task breakdown with clear dependencies and deliverables
  - Status tracking with metrics, decisions, and risk register
  - Protocol specification with JSON schema and encryption details
  - Platform-specific README files with setup instructions

#### Added - October 2, 2025
- **Protocol Validation**: Published JSON Schema for clipboard and control messages (`docs/protocol.schema.json`) to enable automated validation in tooling and test suites

#### Added - October 3, 2025
- **macOS Client Foundations**: Introduced Swift Package with SwiftUI menu bar shell, history store actor, and NSPasteboard monitor implementation.
- **Android Client Foundations**: Implemented foreground clipboard sync service, Room-backed history persistence, Hilt DI graph, and Compose history UI.
- **Backend Relay Enhancements**: Added in-memory session manager for WebSocket routing with targeted broadcast logic and unit tests.
- **macOS Tooling**: Created reusable Xcode workspace (`macos/HypoApp.xcworkspace`) to streamline local builds of the Swift Package.
- **Security Planning**: Documented cross-platform cryptography library evaluation (`docs/crypto_research.md`) selecting CryptoKit, Tink, and RustCrypto AES-GCM.
- **Protocol Hardening**: Expanded structured error catalogue with offline, conflict, and internal error codes.
- **Roadmap Alignment**: Updated task tracker and project status to reflect coding progress and JSON protocol decision for MVP.

#### Added - October 7, 2025
- **Encrypted Clipboard Envelopes**: Updated the protocol to transmit AES-256-GCM ciphertext with explicit encryption metadata and refreshed the specification to reflect the new structure.
- **Relay Key Registry**: Added an in-memory device key store, control-message handlers for registering keys, and validation that all clipboard payloads include properly sized nonce/tag values.
- **macOS Sync Engine**: Wired CryptoKit encryption/decryption into the menu bar client with injectable key providers, producing encrypted envelopes and decoding remote payloads in unit tests.
- **Cross-Platform Tests**: Added Swift unit coverage for the SyncEngine, extended Rust tests for the WebSocket handler, and tightened AES-GCM utilities to track authentication tags explicitly.
- **Status Tracking**: Marked end-to-end encryption plumbing complete in the project dashboard to unblock Sprint 3 LAN discovery work.
#### Infrastructure
- Initialized Git repository with comprehensive .gitignore
- Created MIT license file
- Set up mono-repo structure (backend/, android/, macos/, docs/, tasks/)
- Configured build systems for all platforms

---

## Release History

*No releases yet - project in initial development phase*

---

## Planned Releases

### [0.1.0] - Alpha Release (Target: ~Week 8)
**Goal**: Core functionality working between paired devices on LAN

**Planned Features**:
- Basic clipboard sync (text only)
- LAN discovery and direct connection
- Device pairing via QR code
- Simple UI on both platforms
- De-duplication and throttling

### [0.2.0] - Beta Release (Target: ~Week 12)
**Goal**: Full feature set with cloud fallback

**Planned Features**:
- Support for links, images, and small files
- Cloud relay fallback
- Clipboard history (200 items)
- Search functionality
- Rich notifications
- Remote pairing

### [0.3.0] - Beta 2 (Target: ~Week 16)
**Goal**: Polished experience ready for wider testing

**Planned Features**:
- Optimized performance (latency <500ms LAN, <3s cloud)
- Comprehensive error handling
- Battery optimization for Android
- Full test coverage
- User documentation
- Monitoring and analytics

### [1.0.0] - Public Release (Target: TBD)
**Goal**: Stable, production-ready application

**Planned Features**:
- All beta features refined based on feedback
- Mac App Store distribution (if feasible)
- Google Play Store distribution
- Auto-update mechanism
- Comprehensive user guide

---

## Version Numbering

- **Major (X.0.0)**: Breaking changes, major feature additions
- **Minor (0.X.0)**: New features, backward compatible
- **Patch (0.0.X)**: Bug fixes, performance improvements

---

## Contributing

*Note: Project currently in solo development phase. Contribution guidelines will be added before public beta.*

---

**Changelog Maintained By**: Principal Engineering Team
**Last Updated**: October 3, 2025

