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

---

## 🏗️ Architecture

```
┌─────────────────┐         LAN (mDNS)         ┌──────────────────┐
│   macOS Client  │◄────────────────────────────►│ Android Client   │
│   (Swift/SwiftUI)│                              │ (Kotlin/Compose) │
└────────┬────────┘                              └────────┬─────────┘
         │                                                │
         │           Cloud Fallback (WebSocket)          │
         └────────────────────┬─────────────────────────┘
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

### macOS Client

```bash
# Navigate to macOS project
cd macos

# Open in Xcode
open Hypo.xcodeproj

# Set your development team in Signing & Capabilities
# Build and run (⌘R)
```

**Requirements**:
- macOS 26+ (Sequoia or later)
- Xcode 15+
- Swift 6

### Android Client

```bash
# Navigate to Android project
cd android

# Build debug APK
./gradlew assembleDebug

# Install on connected device
adb install app/build/outputs/apk/debug/app-debug.apk
```

**Requirements**:
- Android Studio Hedgehog or later
- Android SDK 26+ (API 26)
- Kotlin 2.0

### Backend Relay

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

**Requirements**:
- Rust 1.75+
- Redis 7+ (or Docker)

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
| **Sprint 1** | Weeks 1-2 | Foundation & Architecture ← *We are here* |
| **Sprint 2** | Weeks 3-4 | Core Sync Engine |
| **Sprint 3** | Weeks 5-6 | Transport Layer (LAN + Cloud) |
| **Sprint 4** | Weeks 7-8 | Content Type Handling (Text, Images, Files) |
| **Sprint 5** | Weeks 9-10 | User Interface Polish |
| **Sprint 6** | Weeks 11-12 | Device Pairing (QR + Remote) |
| **Sprint 7** | Weeks 13-14 | Testing & Optimization |
| **Sprint 8** | Weeks 15-16 | Beta Release |

**Detailed Tasks**: See [`tasks/tasks.md`](tasks/tasks.md)

---

## 📊 Current Status

**Phase**: Sprint 1 - Foundation & Architecture  
**Progress**: 5%  
**Last Updated**: October 1, 2025

**Recent Milestones**:
- ✅ Architecture designed
- ✅ Technical specifications complete
- ✅ Development roadmap defined
- 🚧 Project structure initialization

**Next Steps**:
1. Initialize platform-specific projects
2. Define JSON protocol schema
3. Research and select crypto libraries

**Full Status**: See [`docs/status.md`](docs/status.md)

---

## 🧪 Testing

```bash
# macOS: Run unit tests
cd macos
xcodebuild test -scheme Hypo -destination 'platform=macOS'

# Android: Run unit tests
cd android
./gradlew test

# Backend: Run unit tests
cd backend
cargo test

# Integration tests (coming soon)
cd tests
./run_integration_tests.sh
```

**Test Coverage Target**: 80% for clients, 90% for backend

---

## 📈 Performance Targets

| Metric | Target | Status |
|--------|--------|--------|
| LAN Sync Latency (P95) | < 500ms | Not yet measured |
| Cloud Sync Latency (P95) | < 3s | Not yet measured |
| Memory Usage (macOS) | < 50MB | Not yet measured |
| Memory Usage (Android) | < 30MB | Not yet measured |
| Battery Drain (Android) | < 2% per day | Not yet measured |

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

