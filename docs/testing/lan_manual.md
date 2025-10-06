# LAN Discovery & TLS WebSocket Manual QA

_Last updated: October 7, 2025_

This checklist documents the LAN discovery verification steps, telemetry capture, and artifact locations for Sprint 3 Phase 3.1. The scenarios were exercised with the loopback instrumentation harness that pairs the macOS and Android LAN transports against local echo servers.

## Test Matrix

| ID | Scenario | macOS Result | Android Result | Notes |
|----|----------|--------------|----------------|-------|
| QA-LAN-01 | Bonjour discovery between two peers on same subnet | ✅ Pass (loopback harness) | ✅ Pass (loopback harness) | Harness replayed cached TXT records and verified pruning via unit hooks. |
| QA-LAN-02 | Bonjour publish lifecycle (foreground/terminate) | ✅ Pass | ✅ Pass | Observed advertise/withdraw lifecycle in debug logs using `hypo://debug/lan`. |
| QA-LAN-03 | NSD registration and multicast lock reacquisition | ✅ Pass | ✅ Pass | Exercised via `LanDiscoveryRepositoryTest` with injected network change stream. |
| QA-LAN-04 | TLS WebSocket handshake (LAN) with fingerprint pinning | ✅ Pass | ✅ Pass | Verified handshake succeeds with pinned SHA-256 fingerprint vector. |
| QA-LAN-05 | TLS WebSocket idle watchdog timeout | ✅ Pass | ✅ Pass | macOS + Android unit harness confirm watchdog closes connection after idle threshold. |
| QA-LAN-06 | TLS WebSocket frame codec echo | ✅ Pass | ✅ Pass | Encoded payload echoed through local loopback, round-trip metrics captured. |

> **Note**: Real dual-device validation still requires execution on physical hardware. Use the steps below to rerun the checklist on macOS and Android devices connected to the same Wi-Fi network.

## Execution Steps

1. **macOS preparation**
   - Build `HypoApp` in Xcode or via `swift build --package-path macos`.
   - Launch the menu bar app and ensure `hypo://debug/lan` reports an active Bonjour service.
2. **Android preparation**
   - Install the debug APK (`./android/gradlew installDebug`).
   - Start `ClipboardSyncService` in foreground mode; confirm multicast lock acquisition via `adb logcat`.
3. **Handshake validation**
   - Initiate pairing from macOS (QR scan or manual entry).
   - Observe TLS handshake success with pinned fingerprint in both logs (`LanWebSocketTransport` / `LanWebSocketClient`).
4. **Discovery restart**
   - Toggle Wi-Fi off/on on Android; confirm NSD rediscovery and Bonjour refresh within 5 seconds.
5. **Metrics capture**
   - Run `swift test --filter LanWebSocketTransportTests/testMetricsRecorderCapturesHandshakeAndRoundTrip` and `./android/gradlew -p android testDebugUnitTest --tests com.hypo.clipboard.transport.ws.LanWebSocketClientTest` to refresh simulated baselines.
   - Review `tests/transport/lan_loopback_metrics.json` for aggregated handshake/round-trip timings produced by the harness.
6. **Telemetry export**
   - Upload captured Wireshark trace (if collected on hardware) to the shared drive and reference in `docs/status.md` under Performance Targets.

## Artifact Locations

- **Loopback metrics**: `tests/transport/lan_loopback_metrics.json`
- **Simulated handshake log**: `android/app/build/reports/tests/testDebugUnitTest/index.html`
- **Bonjour diagnostics**: `hypo://debug/lan` output (copy to `docs/testing/artifacts/` as needed)

## Follow-ups

- [ ] Capture physical-device Wireshark trace (mdns + TLS) once hardware lab time is available.
- [ ] Validate metrics on heterogeneous network conditions (mesh router, 2.4 GHz congestion).
