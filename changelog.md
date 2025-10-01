# Changelog

All notable changes to the Hypo project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

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
**Last Updated**: October 1, 2025

