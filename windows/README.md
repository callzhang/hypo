# Hypo Windows Client

Windows client for Hypo, at feature parity with the macOS menu-bar client.

**Design:** [`docs/superpowers/specs/2026-08-28-windows-client-design.md`](../docs/superpowers/specs/2026-08-28-windows-client-design.md)

## Status

| Layer | Plan | State |
|-------|------|-------|
| `Hypo.Core` — protocol, crypto, compression | Plan 1 | Implemented |
| Transport, discovery, pairing, storage | Plan 2 | Not started |
| Windows platform layer and tray app | Plan 3 | Not started |
| History panel and settings UI | Plan 4 | Not started |
| Shell extension, packaging, release | Plan 5 | Not started |

Plan 1 is [`docs/superpowers/plans/2026-08-28-windows-core-foundation.md`](../docs/superpowers/plans/2026-08-28-windows-core-foundation.md).
Plans 2–5 are not written yet; the split above follows the scope boundary that
plan sets out.

## Requirements

- .NET 10 SDK
- Windows 10 22H2 (build 19045) or later to run the app; `Hypo.Core` alone
  builds and tests on any platform the SDK supports

## Build and test

```bash
cd windows
dotnet build
dotnet test
```

## Layout

- `src/Hypo.Core` — protocol models, framing, cryptography, compression, and the
  `ISecretStore` persistence contract. Targets `net10.0` with no Windows APIs,
  which is what keeps the layer testable in isolation. Do not add a
  Windows-specific dependency here; the DPAPI-backed secret store arrives in
  Plan 3 behind `ISecretStore`.
- `tests/Hypo.Core.Tests` — xUnit suite. The crypto, framing and gzip tests read
  `tests/crypto_test_vectors.json` and `tests/transport/frame_vectors.json` from
  the repository root, the same fixtures the macOS and Android suites use. If a
  change makes one of those tests fail, the Windows client has diverged from the
  other two clients — fix the client, not the fixture.

## Interoperability notes

- Android encodes base64 without padding. Decode through `Base64Compat`, never
  `Convert.FromBase64String` directly.
- `System.Text.Json` writes `DateTimeOffset` with a numeric offset (`+00:00`),
  while both peer clients emit a `Z` designator. Serialize timestamps through
  `Iso8601DateTimeOffsetConverter`, which is already registered on the shared
  options in `ProtocolJson`.
- Compression is a gzip container (RFC 1952), not raw deflate.
- Device IDs are bare lowercase UUIDs. Platform-prefixed IDs were removed in
  protocol v1.1.
