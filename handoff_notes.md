# Handoff Notes

## Status
- Work on Sprint 3 transport implementation has been paused per instruction.

## Completed Items
- Backend: WebSocket handler conflict resolved; control-channel key registration and payload validation added (`backend/src/handlers/websocket.rs`).
- Backend utilities: Added length-prefixed framing helpers with unit tests (`backend/src/utils/framing.rs`, `backend/src/utils/mod.rs`, `backend/tests/transport/framing.rs`).
- Backend DevOps: Added Fly.io deploy workflow, staging config, and certificate fingerprint helper (`.github/workflows/deploy.yml`, `backend/fly.toml`, `backend/scripts/cert_fingerprint.sh`).
- Backend dependencies: Declared new `bytes` dependency in `backend/Cargo.toml`.
- macOS client: Implemented Bonjour discovery/publisher, TLS WebSocket client, LAN-first transport, metrics recorder, exponential backoff helper, transport manager/provider wiring, plus unit tests (`macos/Sources/HypoApp/Services/*.swift`, `macos/Tests/HypoAppTests/*.swift`).
- Android client: Added NSD discovery/publisher, TLS WebSocket wrapper, transport manager with fallback metrics, and Robolectric test (`android/app/src/main/java/com/hypo/transport/*.kt`, `android/app/src/androidTest/java/com/hypo/transport/LanDiscoveryRepositoryTest.kt`).
- Documentation: Updated technical spec, status dashboard, sprint tasks, and LAN pairing QA checklist (`docs/technical.md`, `docs/status.md`, `tasks/tasks.md`, `docs/qa/lan_pairing.md`).

## Outstanding TODOs
- Run `swift test` for macOS client additions.
- Run `./gradlew test` (and relevant instrumentation tests) for Android transport modules.
- Execute integrated LAN/cloud pairing validation beyond the documented manual QA checklist.

## Additional Notes
- No `update_plan` call has been made so far.
- Transport metrics depend on the new `TransportHandle` flow; ensure `TransportManager.loadTransport()` consumers adopt it.
- Fly.io deploy workflow requires a configured staging app and `FLY_API_TOKEN` secret before activation.

## Next Steps
- Resume Sprint 3 testing and validation once work is unpaused, starting with the outstanding TODOs above.
