# Hypo - Cross-Platform Clipboard Sync

> Real-time, secure clipboard synchronization between any devices (Android, macOS, iOS, etc.)

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20Android%208%2B-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Status](https://img.shields.io/badge/status-Production%20Beta-green)]()
[![Deploy Backend Relay](https://github.com/callzhang/hypo/actions/workflows/backend-deploy.yml/badge.svg)](https://github.com/callzhang/hypo/actions/workflows/backend-deploy.yml)
[![Release](https://github.com/callzhang/hypo/actions/workflows/release.yml/badge.svg)](https://github.com/callzhang/hypo/actions/workflows/release.yml)

---

## 🎯 Overview

Hypo enables seamless clipboard synchronization between any devices. Copy on one device, paste on another—instantly. Supports Android↔Android, macOS↔macOS, Android↔macOS, and other cross-platform combinations.

### Key Features

- **🚀 Real-time Sync**: Sub-second clipboard updates across devices
- **🔒 E2E Encrypted**: AES-256-GCM encryption, your data never exposed
- **📡 Dual Transport**: LAN-first for speed, cloud fallback for mobility
- **📋 Multi-Format**: Text, links, images (≤10MB), and files (≤10MB)
- **🕒 Clipboard History**: Search and restore past clipboard items (macOS)
- **🔔 Rich Notifications**: Preview content before pasting
- **🎨 Native UI**: SwiftUI on macOS, Material 3 on Android
- **🔋 Battery Optimized**: Auto-idles WebSocket when screen is off (Android)

---

## 🏗️ Architecture

```
┌─────────────────┐         LAN (mDNS)           ┌──────────────────┐
│   macOS Client  │◄────────────────────────────►│ Android Client   │
│  (Swift/SwiftUI)│                              │ (Kotlin/Compose) │
└────────┬────────┘                              └────────┬─────────┘
         │                                                │
         │           Cloud Fallback (WebSocket)           │
         └────────────────────┬───────────────────────────┘
                              │
                    ┌─────────▼──────────┐
                    │  Backend Relay     │
                    │  (Rust/Actix-web)  │
                    │  + Redis           │
                    └────────────────────┘
```

**See**: [`docs/architecture.mermaid`](docs/architecture.mermaid) for detailed component diagram

---

## 🚀 Quick Start

### Prerequisites

- **macOS**: macOS 13+ with Xcode 15+
- **Android**: HyperOS 3+ (or Android 8+) device
- **Backend** (optional for cloud sync): Docker or Rust 1.75+

### Installation

**📖 Complete Installation Guide**: See [`docs/USER_GUIDE.md#installation`](docs/USER_GUIDE.md#installation) for detailed setup instructions for all platforms.

**Quick Links**:
- **macOS**: Download from [GitHub Releases](https://github.com/callzhang/hypo/releases) or [build from source](#macos-client)
- **Android**: Download APK from [GitHub Releases](https://github.com/callzhang/hypo/releases) or [build from source](#android-client)

For development setup, see [Development Setup](#development-setup) below.

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [`docs/architecture.mermaid`](docs/architecture.mermaid) | System architecture and component relationships |
| [`docs/technical.md`](docs/technical.md) | Technical specifications and implementation details |
| [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md) | Complete user guide including installation |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Common issues and solutions |
| [`tasks.md`](tasks.md) | Development roadmap and task breakdown |
| [`changelog.md`](changelog.md) | Version history and project status summary |

---

## 🛠️ Development Setup

### Project Structure

```
hypo/
├── macos/              # Swift/SwiftUI macOS client
├── android/            # Kotlin/Compose Android client
├── backend/            # Rust backend relay server
├── docs/               # Architecture and specifications
├── tasks/              # Development tasks and planning
└── tests/              # Cross-platform integration tests
```

### Build Scripts

```bash
# Build both platforms at once
./scripts/build-all.sh

# Build Android only
./scripts/build-android.sh

# Build macOS only
./scripts/build-macos.sh
```

### macOS Client

```bash
# Navigate to macOS project
cd macos

# Open the Swift Package workspace in Xcode
xed HypoApp.xcworkspace  # or: open HypoApp.xcworkspace

# Set your development team in Signing & Capabilities
# Build and run (⌘R)
```

**Requirements**:
- macOS 13+ (Ventura or later)
- Xcode 15+
- Swift 6

### Android Client

**Quick Start (Automated Build):**

```bash
# 1. Install prerequisites
brew install openjdk@17

# 2. Set up Android SDK (one-time setup)
./scripts/setup-android-sdk.sh

# 3. Build APK (automated script handles environment)
./scripts/build-android.sh

# 4. Install on connected device
$ANDROID_SDK_ROOT/platform-tools/adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

**Manual Build (Advanced):**

```bash
# Configure environment
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
export ANDROID_SDK_ROOT="$(pwd)/.android-sdk"
export GRADLE_USER_HOME="$(pwd)/.gradle"

# Build
cd android
./gradlew assembleDebug --stacktrace
```

**Output**: `android/app/build/outputs/apk/debug/app-debug.apk` (~41MB)

**Requirements**:
- **Java**: OpenJDK 17
- **Android SDK**: API 34 (via setup script or Android Studio)
- **Kotlin**: 1.9.22 (via Gradle wrapper 8.7)
- **Build Time**: ~4-6 seconds (incremental), ~15 seconds (clean)

**📖 Detailed Instructions**: See [`android/README.md`](android/README.md) for:
- Complete build instructions
- Xiaomi/HyperOS device setup
- Troubleshooting common issues
- Development tips

> **Note:** The repository omits the binary `gradle-wrapper.jar` in favour of a
> base64-encoded copy. The provided `gradlew` scripts reconstruct the official
> Gradle 8.7 wrapper JAR automatically the first time you run them, keeping the
> tree free of binaries while preserving reproducible builds.

### Backend Relay

**Production Server**: `https://hypo.fly.dev` (deployed on Fly.io)

**Local Development**:

```bash
# Navigate to backend project
cd backend

# Install dependencies and build
cargo build --release

# Run with Redis (Docker)
docker-compose up -d redis
cargo run --release

# Or run everything with Docker
docker-compose up
```

**Server Endpoints**:
- Health: `GET /health` - Server status and uptime
- Metrics: `GET /metrics` - Prometheus metrics
- WebSocket: `WS /ws` - Real-time message relay (requires `X-Device-Id` and `X-Device-Platform` headers)
- Pairing: `POST /pairing/code` - Create pairing code
- Pairing: `POST /pairing/claim` - Claim pairing code

**Requirements**:
- Rust 1.83+ (for local development)
- Redis 7+ (embedded in production Docker image, or Docker for local)
- Fly.io CLI (for deployment)

**Testing Server**:
```bash
# Test all server functions
./tests/test-server-all.sh
```

### Build Verification

The current toolchain compiles cleanly in this repository. To reproduce the
latest verification run:

```bash
# macOS Swift package build (from repo root)
cd macos
swift build

# Backend relay (from repo root)
cd backend
cargo build

# Android unit tests (requires Android SDK + JDK 17)
./scripts/setup-android-sdk.sh              # downloads command-line tools + platform 34 into .android-sdk/
export ANDROID_SDK_ROOT="$(pwd)/.android-sdk"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64" # adjust for your platform
cd android
./gradlew test --console=plain
```

The helper script `scripts/setup-android-sdk.sh` fetches the Android command-
line tools and installs platform 34 + Build Tools 34.0.0 in `.android-sdk/`. If
you already have an SDK installed, set `ANDROID_SDK_ROOT` to that location and
skip the script. Unit tests require JDK 17; set `JAVA_HOME` accordingly before
invoking Gradle.

---

## 🔒 Security

Hypo takes security seriously:

- **End-to-End Encryption**: All clipboard data encrypted with AES-256-GCM
- **Device Pairing**: ECDH key exchange via LAN auto-discovery or secure relay (cloud)
- **Certificate Pinning**: Prevents MITM attacks on cloud relay
- **No Data Storage**: Backend relay never stores clipboard content
- **Key Rotation**: Automatic 30-day key rotation with backward compatibility

**Threat Model**: See [`docs/technical.md#security-design`](docs/technical.md#security-design)

**Security Status**: Production-ready implementation with:
- ✅ End-to-end encryption (AES-256-GCM)
- ✅ Certificate pinning (prevents MITM attacks)
- ✅ Device pairing with signature verification
- ✅ Key rotation (pairing-time forward secrecy)
- ✅ No data storage on backend (privacy by design)

---

## 🎯 Roadmap

| Sprint | Timeline | Milestone |
|--------|----------|-----------|
| **Sprint 1** | Weeks 1-2 | Foundation & Architecture ✅ |
| **Sprint 2** | Weeks 3-4 | Core Sync Engine ✅ |
| **Sprint 3** | Weeks 5-6 | Transport Layer (LAN + Cloud) ✅ |
| **Sprint 4** | Weeks 7-8 | Content Type Handling (Text, Images, Files) ✅ |
| **Sprint 5** | Weeks 9-10 | User Interface Polish ✅ |
| **Sprint 6** | Weeks 11-12 | Device Pairing (LAN + Remote) ✅ |
| **Sprint 7** | Weeks 13-14 | Testing & Optimization ✅ |
| **Sprint 8** | Weeks 15-16 | Polish & Deployment ✅ |
| **Sprint 9+** | Weeks 17+ | Production Release & Future Features |

**Detailed Tasks**: See [`tasks.md`](tasks.md)

---

## 📊 Current Status

**Phase**: Production Release ✅  
**Version**: v1.1.0  
**Progress**: 100%  
**Last Updated**: January 13, 2026

**Recent Milestones**:
- ✅ **v1.1.0 Released** (Jan 13, 2026): macOS Architecture Refactor & Stability
  - TransportManager now owns peer state and persistence
  - SecurityManager manages encryption key summary and UI actions
  - ClipboardEventDispatcher replaces NotificationCenter for clipboard events
  - Pairing flow registers devices directly (no notification dependency)
- ✅ **v1.0.10 Released** (Dec 28, 2025): Reliability & Connectivity Fixes
  - Fixed race conditions in Android WebSocket client causing "Connecting..." hangs
  - Ensured clipboard listener restarts after service crashes for long-term stability
  - Improved history re-sync logic (distinguishes local vs remote items)
  - Comprehensive documentation update for troubleshooting Android background access
- ✅ **v1.0.6 Released** (Dec 13, 2025): Nonce Reuse Fix for Dual-Send Transport
- ✅ **v1.0.5 Released** (Dec 5, 2025): Text Selection Context Menu & Clipboard Processing Improvements
  - Android text selection context menu: "Copy to Hypo" appears first in menu
  - Force immediate clipboard processing for context menu selections
  - Fixed Android history item copying (FileProvider for images/files)
  - Improved duplicate detection: items move to top when copied
  - Universal "Copied to clipboard" toast for all item types
  - Reduced logging verbosity across all platforms
  - macOS UI improvements: hover tooltips, better connection status display
- ✅ **v1.0.4 Released** (Dec 4, 2025): Code Quality & Storage Optimization
  - Size constants consolidation (single source of truth)
  - Fixed gzip compression format compatibility
  - macOS local file storage optimization (pointer-only storage)
- ✅ **v1.0.3 Released** (Dec 4, 2025): Temp File Management & Performance Improvements
  - Automatic temp file cleanup (30s delay, clipboard change detection)
  - Size limit checks (50MB copy, 10MB sync) with user notifications
  - Android lazy loading for large content (prevents crashes)
  - Fixed macOS encryption encoding (base64 strings for Android compatibility)
- ✅ **v1.0.2 Released** (Dec 3, 2025): Build & Release Improvements
  - macOS app signing for free distribution (ad-hoc signing)
  - Automatic release notes generation
  - Android build optimizations (faster CI/CD builds)
  - Improved backend deployment workflow
  - macOS notification improvements (remote-only, better formatting)
  - Notification permission management in Settings
- ✅ **Production-Ready**: All critical bugs resolved, system fully operational
- ✅ **Backend Server Deployed**: Production server at `https://hypo.fly.dev`
- ✅ **LAN Auto-Discovery Pairing**: Tap-to-pair flow with automatic key exchange fully functional
- ✅ **Device-Agnostic Pairing**: Any device can pair with any other device (Android↔Android, macOS↔macOS, Android↔macOS)
- ✅ **Clipboard Sync**: Bidirectional synchronization verified end-to-end (LAN + Cloud)
- ✅ **Battery Optimization**: 60-80% battery drain reduction when screen off
- ✅ **Automated CI/CD**: Complete GitHub Actions workflow for builds and releases
- ✅ **Comprehensive Documentation**: All docs consolidated and up-to-date

**Server Status**:
- **Production**: `https://hypo.fly.dev` ✅ (operational, all endpoints tested)
- **WebSocket**: `wss://hypo.fly.dev/ws` ✅ (ready for client connections)
- **Health**: `/health` endpoint responding (~50ms)
- **Metrics**: Prometheus metrics available at `/metrics`
- **Infrastructure**: Auto-scaling, zero-downtime deploys

**Full Status**: See [`changelog.md`](changelog.md) for version history and project status

---

## 🧪 Testing

### Unit Tests

```bash
# macOS: Run unit tests
cd macos
swift test

# Android: Run unit tests (after provisioning the SDK + JDK 17)
cd android
./gradlew testDebugUnitTest --tests "*CryptoServiceTest" --tests "*SyncCoordinatorTest"

# Backend: Run unit tests
cd backend
cargo test
```

### Server Testing

```bash
# Test all backend server endpoints and functions
./tests/test-server-all.sh

# Test with local server (if running locally)
USE_LOCAL=true ./tests/test-server-all.sh
```

The server test script validates:
- ✅ Health endpoint
- ✅ Metrics endpoint (Prometheus format)
- ✅ Pairing code creation and claim
- ✅ WebSocket endpoint validation
- ✅ Error handling (404 responses)
- ✅ CORS headers

### Integration Tests

```bash
# Comprehensive sync testing (macOS + Android)
./tests/test-sync.sh

# Automated clipboard sync test (emulator)
./tests/test-clipboard-sync-emulator-auto.sh

# Pairing and sync flow
./tests/test-sync.sh
```

**Test Coverage Target**: 80% for clients, 90% for backend

**Test Status**:
- ✅ Backend: All unit and integration tests passing (32/32 tests)
- ✅ LAN sync: Verified end-to-end
- ✅ Cloud sync: Verified end-to-end
- ✅ Backend routing: Verified correct message delivery
- ✅ Android LAN server: Binary frame delivery verified

---

## 📈 Performance Targets

| Metric | Target | Status |
|--------|--------|--------|
| LAN Sync Latency (P95) | < 500ms | ✅ Achieved (measured ~200-400ms) |
| Cloud Sync Latency (P95) | < 3s | ✅ Achieved (measured ~1-2s) |
| Memory Usage (macOS) | < 50MB | ✅ Achieved (~35-45MB typical) |
| Memory Usage (Android) | < 30MB | ✅ Achieved (~20-25MB typical) |
| Battery Drain (Android) | < 2% per day | ✅ Achieved (screen-off optimization: 60-80% reduction) |
| Server Uptime | > 99.9% | ✅ Achieved (36+ days continuous uptime) |
| Server Response Time | < 100ms | ✅ Achieved (health endpoint: ~50ms) |

---

## 🤝 Contributing

*Note: Project currently in solo development phase. Contribution guidelines will be added before public beta.*

---

## 📝 License

MIT License - See [LICENSE](LICENSE) for details

---

## 🙏 Acknowledgments

- Inspired by Apple's Universal Clipboard
- Built for the Xiaomi/HyperOS community
- Powered by open-source technologies

---

## 📧 Contact

- **Issues**: [GitHub Issues](https://github.com/yourusername/hypo/issues) *(coming soon)*
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/hypo/discussions) *(coming soon)*

---

## ⚠️ Status

This project is in **production release** phase. The system is fully functional and has been extensively tested. All critical bugs have been resolved. Ready for distribution.

**Current Version**: v1.1.0  
**Stability**: Production-ready  
**Next Milestone**: Public beta testing and future feature development

---

**Built with ❤️ for seamless cross-platform workflows**
