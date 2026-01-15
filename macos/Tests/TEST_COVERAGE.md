# Test Coverage Strategy (90% Target)

**Status**: Draft  
**Last Updated**: January 15, 2026  

## Current Status
**Overall Coverage:** Improving (~22% project-wide). Core sync components now show high coverage (>90% for SyncEngine).

## Coverage Summary Table

| Category | Class | Line % | Notes |
| :--- | :--- | :---: | :--- |
| **Security** | `CryptoService` | 9.30% | Needs dedicated unit tests |
| | `FileBasedKeyStore` | 57.00% | |
| | `FileBasedPairingSigningKeyStore` | 61.04% | |
| | `KeychainKeyStore` | 0.00% | |
| **Transport** | `TransportManager` | 58.55% | Orchestrator logic covered |
| | `LanWebSocketTransport` | 51.84% | |
| | `WebSocketTransport` | 29.41% | `WebSocketTransportTests` skipped |
| | `CloudRelayTransport` | 42.31% | |
| | `TransportFrameCodec` | 91.67% | High confidence |
| | `BonjourBrowser` | 85.33% | |
| | `BonjourPublisher` | 57.85% | |
| | `LanWebSocketServer` | 11.58% | |
| **Sync** | `SyncEngine` | 92.31% | Core sync logic verified |
| | `ClipboardEventDispatcher` | 78.95% | |
| | `IncomingClipboardHandler` | 53.04% | Integration with encryption/history |
| | `ClipboardMonitor` | 0.00% | |
| **Data** | `HistoryStore` | 7.33% | Persistence logic verified in sync tests |
| | `StorageManager` | 45.61% | |
| **Utils** | `Logger` | 52.94% | |
| | `Compression` | 83.25% | Gzip/Zlib logic verified |

## Goals
- Reach **≥90% line coverage** for macOS, Android, and backend code.
- Prioritize correctness in security- and sync-critical paths over UI-only coverage.
- Keep coverage meaningful: favor behavior assertions over superficial line hits.

## Scope
**Included**
- Core sync pipeline: encryption, frame codec, transport, pairing, and storage.
- Connection management and fallback logic (LAN ↔ Cloud).
- Clipboard parsing and content-type handling.

**Excluded (by default)**
- Generated code and third-party SDKs.
- UI previews and platform boilerplate.
- Platform wrappers that cannot be deterministically tested (document exceptions).

Any exclusions must be documented in the relevant module test plan.

## Coverage Targets
| Platform | Target | Notes |
|---------|--------|-------|
| macOS | ≥90% line | Swift Testing-based unit tests |
| Android | ≥90% line | JVM unit tests (Compose UI excluded by default) |
| Backend | ≥90% line | Rust unit + integration tests |

## Measurement & Tooling
### macOS (Swift)
- **Command**: `swift test --enable-code-coverage`
- **Reporting**: Use `xcrun llvm-cov report` on the generated `.profdata`/test bundle.
- **Note**: Tests are now written using the **Swift Testing** framework (`import Testing`).

### Android (Kotlin)
- **Command**: `./gradlew testDebugUnitTest`
- **Coverage Tooling**: Add Jacoco reporting (TODO) to generate module-level coverage reports.
- **Scope**: Unit tests only (UI/instrumented tests excluded unless explicitly required).

### Backend (Rust)
- **Command**: `cargo test --all-features --locked`
- **Coverage Tooling**: `cargo llvm-cov --all-features` (requires LLVM tooling installed).

## Quality Gates
- CI should fail when any platform drops below 90% once tooling is wired in.
- New files must include tests that cover core behavior and failure paths.
- Critical modules (crypto, transport, pairing) must maintain ≥95% coverage.

## Prioritized Coverage Areas
1. **Pairing & Key Exchange** (auth, signature verification, expiry)
2. **Transport & Frame Codec** (handshake, heartbeat, payload framing)
3. **Clipboard Parsing** (file MIME detection, size limits, metadata)
4. **Sync Coordinator** (dedupe, retries, error propagation)
5. **Storage** (history insertions, limits, retention)

## Test Types
- **Unit tests**: deterministic, fast, mandatory for core logic.
- **Integration tests**: protocol compatibility, fallback flows, and metrics aggregation.
- **Regression tests**: fixtures under `tests/transport/` for cross-platform parity.

## Reporting & Review
- Coverage summaries should be included in PR descriptions once tooling is active.
- Any deliberate coverage reduction must be justified and documented.

