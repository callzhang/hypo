# Cloud Relay Smoke Checklist

_Last updated: October 10, 2025_

## Prerequisites
- macOS device with the Hypo staging build
- Android device (or emulator) with the Hypo staging build
- Access to the Fly.io staging relay (`wss://hypo-relay-staging.fly.dev/ws`)
- Valid staging API credentials stored in 1Password

## Test Matrix
| Scenario | macOS Expected Result | Android Expected Result |
| --- | --- | --- |
| Connect via relay | `CloudRelayTransport` reports `connectedCloud` state, handshake < 3 s | `RelayWebSocketClient` logs `ConnectedCloud`, handshake < 3 s |
| Send text payload | Message arrives on counterpart, metrics event recorded | Message arrives on counterpart, metrics event recorded |
| TLS pinning failure (mismatched fingerprint) | Connection rejected, analytics event `pinningFailure` (environment `cloud`) | Connection rejected, analytics event `PinningFailure` (environment `cloud`) |
| Disconnect | Clean close frame with reason `client shutdown` | Clean close frame with reason `client shutdown` |

## Execution Steps
1. Launch macOS and Android clients, ensure LAN is disabled to force relay fallback.
2. Trigger clipboard sync from macOS → Android and Android → macOS; verify payload delivery.
3. Capture logs to confirm `lan_timeout` fallback reason on first attempt and `ConnectedCloud` state afterwards.
4. Update Android BuildConfig fingerprint to an incorrect value, rebuild, and confirm pinning analytics event is emitted.
5. Restore the correct fingerprint, rerun sync, and ensure metrics report `transport_handshake_ms` with label `cloud`.

## Artifacts
- Latency samples appended to `tests/transport/cloud_metrics.json`
- Analytics export uploaded to `/observability/relay/{date}.json`
- Wireshark capture stored in shared drive `/captures/relay/smoke/{date}`
