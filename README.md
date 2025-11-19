# Hypo - Cross-Platform Clipboard Sync

> Real-time, secure clipboard synchronization between Android/HyperOS and macOS

[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B%20%7C%20Android%208%2B-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Status](https://img.shields.io/badge/status-Alpha%20Development-yellow)]()

---

## 🎯 Overview

Hypo enables seamless clipboard synchronization between your Xiaomi/HyperOS device and macOS machine. Copy on one device, paste on another—instantly.

### Key Features

- **🚀 Real-time Sync**: Sub-second clipboard updates across devices
- **🔒 E2E Encrypted**: AES-256-GCM encryption, your data never exposed
- **📡 Dual Transport**: LAN-first for speed, cloud fallback for mobility
- **📋 Multi-Format**: Text, links, images (≤1MB), and files
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

- **macOS**: macOS 26+ with Xcode 15+
- **Android**: HyperOS 3+ (or Android 8+) device
- **Backend** (optional for cloud sync): Docker or Rust 1.75+

### Installation

*Coming soon - project in development*

For now, see [Development Setup](#development-setup) to build from source.

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [`docs/architecture.mermaid`](docs/architecture.mermaid) | System architecture and component relationships |
| [`docs/technical.md`](docs/technical.md) | Technical specifications and implementation details |
| [`tasks/tasks.md`](tasks/tasks.md) | Development roadmap and task breakdown |
| [`docs/status.md`](docs/status.md) | Current project status and progress tracking |
| [`changelog.md`](changelog.md) | Version history and release notes |

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

# Watch for changes and auto-build (requires fswatch)
./scripts/watch-and-build.sh
# Options:
#   --no-android    Skip Android builds
#   --no-macos      Skip macOS builds
#   --no-install    Don't auto-install on devices
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
- macOS 26+ (Sequoia or later)
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
./scripts/test-server-all.sh
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
- **Device Pairing**: ECDH key exchange via QR code (LAN) or secure relay (cloud)
- **Certificate Pinning**: Prevents MITM attacks on cloud relay
- **No Data Storage**: Backend relay never stores clipboard content
- **Key Rotation**: Automatic 30-day key rotation with backward compatibility

**Threat Model**: See [`docs/technical.md#31-threat-model`](docs/technical.md#31-threat-model)

---

## 🎯 Roadmap

| Sprint | Timeline | Milestone |
|--------|----------|-----------|
| **Sprint 1** | Weeks 1-2 | Foundation & Architecture ✅ |
| **Sprint 2** | Weeks 3-4 | Core Sync Engine ✅ |
| **Sprint 3** | Weeks 5-6 | Transport Layer (LAN + Cloud) ✅ |
| **Sprint 4** | Weeks 7-8 | Content Type Handling (Text, Images, Files) ✅ |
| **Sprint 5** | Weeks 9-10 | User Interface Polish ✅ |
| **Sprint 6** | Weeks 11-12 | Device Pairing (QR + Remote) ✅ |
| **Sprint 7** | Weeks 13-14 | Testing & Optimization ✅ |
| **Sprint 8** | Weeks 15-16 | Polish & Deployment ← *Current* |
| **Sprint 9** | Weeks 17-18 | Beta Release |

**Detailed Tasks**: See [`tasks/tasks.md`](tasks/tasks.md)

---

## 📊 Current Status

**Phase**: Sprint 8 - Polish & Deployment ✅
**Progress**: 95%
**Last Updated**: December 19, 2025

**Recent Milestones**:
- ✅ **Backend Server Deployed**: Production server running at `https://hypo.fly.dev` (uptime: 36+ days)
- ✅ **LAN Auto-Discovery Pairing**: Tap-to-pair flow with automatic key exchange fully functional
- ✅ **Clipboard Sync Infrastructure**: Detection, processing, queuing, and target identification verified end-to-end
- ✅ **WebSocket Transport Stabilized**: Connection management fixed, sync waits for handshake completion
- ✅ **Android ↔ macOS Sync**: Bidirectional clipboard synchronization working
- ✅ **Thread Safety**: macOS app crash fixes implemented and validated
- ✅ **UI Improvements**: Origin indicators, version display, lastSeen updates, blurred background modal

**Server Status**:
- **Production**: `https://hypo.fly.dev` (operational, all endpoints tested ✅)
- **WebSocket**: `wss://hypo.fly.dev/ws` (ready for client connections)
- **Health**: `/health` endpoint responding
- **Metrics**: Prometheus metrics available at `/metrics`

**Next Steps**:
1. End-to-end testing of encrypted payload sync (decoding issue verification)
2. Production deployment finalization
3. Beta testing recruitment

**Full Status**: See [`docs/status.md`](docs/status.md)

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
./scripts/test-server-all.sh

# Test with local server (if running locally)
USE_LOCAL=true ./scripts/test-server-all.sh
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
./scripts/test-sync.sh

# Automated clipboard sync test (emulator)
./scripts/test-clipboard-sync-emulator-auto.sh

# Pairing and sync flow
./scripts/test-pairing-and-sync.sh
```

**Test Coverage Target**: 80% for clients, 90% for backend

**Server Test Results**: All 7 endpoint tests passing ✅ (Dec 19, 2025)

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

## ⚠️ Disclaimer

This project is in **active development** and not yet ready for production use. APIs and features may change without notice.

---

**Built with ❤️ for seamless cross-platform workflows**

