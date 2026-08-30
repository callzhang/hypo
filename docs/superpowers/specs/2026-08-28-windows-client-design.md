# Windows Client — Design Specification

**Status**: Approved, pending implementation plan
**Date**: August 28, 2026
**Target**: Feature parity with the macOS client (`macos/`)
**Protocol**: `docs/protocol.md` v1.1.6 — no protocol or backend changes required

---

## 1. Scope

Ship a Windows client with full feature parity to the macOS menu-bar client: tray
residency, bidirectional clipboard sync over LAN and cloud relay, device pairing,
searchable clipboard history with pinning and drag-to-paste, toast notifications,
and a global hotkey.

`device.platform` already enumerates `windows` (protocol §3.4), and the pairing
system is device-agnostic as of the November 2025 refactor. Windows pairs with
macOS, Android, and other Windows devices through the same code paths.

### Support matrix

| Axis | Decision |
|------|----------|
| OS floor | Windows 10 22H2 (build 19045) |
| Architectures | x64 and ARM64 |
| Runtime | .NET 10 (LTS) |
| UI framework | WPF with the WPF-UI Fluent theme |
| Distribution | MSIX on GitHub Releases (SignPath Foundation signing) + winget manifest |

### Out of scope for v1

- Microsoft Store submission — revisit after v1 stabilises. Store publishing is
  free for individual developers and Microsoft signs the package, but submission
  review adds compliance work (privacy policy, age rating) that would delay v1.
- Drag-to-tray-icon sending. The Windows notification area is not a valid drop
  target; the shell does not forward drag-and-drop to tray icons. Explorer's
  "Copy to Hypo" context menu covers the same need.

---

## 2. Architecture

The Windows client is a **structural mirror** of the macOS client, not a
redesign. Each macOS service has a same-named Windows counterpart so that
behavioural divergence between the two can be located by direct comparison.

```
windows/
├── Hypo.sln
├── src/
│   ├── Hypo.Core/                  net10.0 — no Windows APIs, no UI
│   │   ├── Models/                 ClipboardEntry, ClipboardContent, PairedDevice,
│   │   │                           DevicePlatform, TransportOrigin
│   │   ├── Protocol/               SyncEnvelope, ClipboardPayload, TransportFrameCodec
│   │   ├── Crypto/                 CryptoService, DeviceKeyProvider, IKeyStore
│   │   ├── Transport/              ISyncTransport, LanWebSocketServer,
│   │   │                           LanWebSocketTransport, CloudRelayTransport,
│   │   │                           DualSyncTransport, TransportManager
│   │   ├── Discovery/              MdnsPublisher, MdnsBrowser
│   │   ├── Pairing/                PairingSession, PairingRelayClient
│   │   ├── Storage/                HistoryStore (SQLite), SettingsStore
│   │   ├── Sync/                   SyncEngine, ClipboardEventDispatcher,
│   │   │                           IncomingClipboardHandler, TokenBucket
│   │   └── Abstractions/           IClipboardService, INotificationService,
│   │                               ISecretStore, IAutoStartService,
│   │                               IGlobalHotkeyService
│   ├── Hypo.Platform.Windows/      net10.0-windows — Win32/WinRT implementations
│   ├── Hypo.App/                   net10.0-windows — ViewModels (MVVM), no View types
│   ├── Hypo.Wpf/                   WinExe — windows, controls, tray icon, entry point
│   └── Hypo.ShellExtension/        NativeAOT — IExplorerCommand COM server
├── tests/
│   ├── Hypo.Core.Tests/
│   └── Hypo.Platform.Windows.Tests/
└── packaging/                      MSIX manifest, assets, signing and build scripts
```

### Dependency rule

Dependencies flow one way: `Hypo.Wpf → Hypo.App → Hypo.Platform.Windows → Hypo.Core`.
`Hypo.Core` does not know it runs on Windows and does not know a UI exists.
`Hypo.ShellExtension` depends on nothing in this tree; it talks to the running
app over a named pipe.

This constraint buys three things:

1. `Hypo.Core.Tests` needs no message loop and no real clipboard, so the
   repository's ≥80% client coverage target is achievable.
2. Replacing WPF with WinUI 3 later means rewriting only `Hypo.Wpf`.
3. Crypto and protocol code can be validated against the shared test vectors in
   isolation — the primary defence against a third client implementation
   drifting from the other two.

### Library selection

| Concern | Choice | Rationale |
|---------|--------|-----------|
| AES-256-GCM | .NET `AesGcm` | Built in, hardware accelerated |
| HKDF-SHA256 | .NET `HKDF` | Built in |
| X25519 key agreement | BouncyCastle `X25519Agreement` | .NET has no built-in X25519 |
| Ed25519 pairing signatures | BouncyCastle `Ed25519Signer` | Matches `Curve25519.Signing` |
| Gzip | .NET `GZipStream` | Matches Android's `GZIPOutputStream` |
| WebSocket client | `ClientWebSocket` | Built in |
| WebSocket server | Kestrel | Plain TCP on LAN, matching macOS |
| mDNS | `Makaretu.Dns.Multicast` | Pure managed; does not require Bonjour for Windows |
| History storage | SQLite (`Microsoft.Data.Sqlite`) | See §2.1 |
| Key storage | DPAPI (`ProtectedData`, CurrentUser) | Counterpart to the macOS encrypted file store |

BouncyCastle is chosen over libsodium bindings (NSec) specifically because it is
pure managed code, which removes native-binary packaging concerns on ARM64.

### 2.1 Intentional divergence: history storage

macOS `HistoryStore` keeps entries in memory and persists JSON to `UserDefaults`,
deliberately skipping large blobs on write — image and file bytes do not survive
an app restart, only metadata does.

Windows uses SQLite with blobs stored in-table, so history genuinely persists.
This is not gold-plating: in .NET, SQLite is *simpler* than hand-rolling a JSON
file with a blob-skipping rule, so the more capable option is also the cheaper
one.

---

## 3. Sync data flow

### 3.1 Outbound

```
Win32 message-only window (HWND_MESSAGE)
  │ WM_CLIPBOARDUPDATE
  ▼
ClipboardMonitor
  │ read GetClipboardSequenceNumber();
  │ equals the value recorded when we last wrote → discard (loop suppression)
  │ read formats by priority: CF_HDROP → "PNG" → CF_DIBV5 → CF_BITMAP → CF_UNICODETEXT
  ▼
ClipboardEntry ── SHA-256 content hash
  │ hash == lastSentHash or lastReceivedHash → discard (protocol §6)
  ▼
TokenBucket (capacity 3, one token per 300 ms) — over budget: drop and log
  ▼
SyncEngine.Transmit()
  │ 1. serialise ClipboardPayload to JSON
  │ 2. gzip (always on)
  │ 3. AES-256-GCM, associated data = deviceId + timestamp
  ▼
DualSyncTransport ──┬─► LanWebSocketTransport
                    └─► CloudRelayTransport (wss://hypo.fly.dev/ws)
```

**`DualSyncTransport` invariant.** A single clipboard event is sent over LAN and
cloud simultaneously. Both envelopes carry the **same message id** so the
receiver can deduplicate, and **independently generated nonces**. Nonce reuse
under one AES-GCM key leaks plaintext; this is a correctness requirement, not an
optimisation.

### 3.2 Inbound

```
LanWebSocketServer (:7010) or CloudRelayTransport
  ▼
TransportFrameCodec.Decode
  │ 4-byte big-endian length prefix + JSON body
  │ snake_case keys, ISO 8601 timestamps, 20 MB frame ceiling
  ▼
deduplicate by message id (LAN and cloud each deliver a copy; first wins)
  ▼
IncomingClipboardHandler
  │ 0. if nonce or tag is empty -> plain-text mode: skip decryption,
  │    the ciphertext field is gzipped but unencrypted (see below)
  │ 1. AES-256-GCM decrypt and verify tag
  │ 2. gunzip (on failure, treat as uncompressed — legacy compatibility)
  │ 3. discard if timestamp older than 5 minutes (replay protection)
  ▼
  ├─► HistoryStore.Insert()
  ├─► write to system clipboard, then record the new sequence number
  └─► toast notification with content preview
```

### 3.2.1 Plain-text mode

Both shipping clients support an unencrypted mode, and the Windows client must
implement the receive side of it or messages from a peer in that mode fail with
no useful diagnosis.

An **empty `nonce` or empty `tag`** is the signal. The `ciphertext` field then
holds the gzipped `ClipboardPayload` JSON with no encryption applied — it is
still compressed, so the gunzip step is unchanged. macOS detects it as
`envelope.payload.encryption.nonce.isEmpty || ...tag.isEmpty`
(`SyncEngine.swift`), and Android does the same.

`Hypo.Core`'s models already represent this correctly: `Base64ByteArrayConverter`
decodes both an absent-but-null and an empty-string field to a zero-length
array, so an empty nonce arrives as `[]` rather than throwing. What is missing
is the branch in the inbound handler, which is Plan 2's work.

The Windows client should **receive** plain-text messages but never **send**
them. Nothing in the product requires it, and a send path that can silently skip
encryption is a liability.

### 3.2.2 The pairing channel is not framed

Measured against a shipping Android client and confirmed in both clients' source.
This is the single most consequential thing Plan 2 discovered, and nothing in
`docs/protocol.md` says it.

**Clipboard traffic and pairing traffic use different framings on the same
socket.**

| | Clipboard | Pairing |
|---|---|---|
| WebSocket opcode | `0x2` binary | `0x1` text |
| Length prefix | 4-byte big-endian | **none** |
| Body | `SyncEnvelope` JSON | bare `PairingChallengeMessage` / `PairingAckMessage` JSON |

`macos/Sources/HypoApp/Services/LanWebSocketServer.swift` has two send paths for
exactly this: clipboard data goes through `sendFrame(payload:opcode: 0x2)` after
length-prefixing, while the pairing ack goes through
`sendFrame(payload:opcode: 0x1)` with the raw JSON body.

Two consequences a client must handle, both of which broke the first Windows
interop attempt:

1. **A challenge must be sent as a bare `PairingChallengeMessage`, never wrapped
   in a `SyncEnvelope`.** Both peers classify inbound messages by looking for
   `initiator_device_id` and `initiator_pub_key` — macOS parses the payload as
   JSON and tests the top-level keys (`LanWebSocketServer.swift:1021`), Android
   does a literal substring match on the frame body
   (`LanWebSocketServer.kt:88`). Wrapping the challenge so those fields end up
   base64-encoded inside `payload.ciphertext` hides them from both, and the
   message is silently handled as clipboard data instead. The peer does not
   error; it simply never replies.

2. **A receiver must not feed the pairing reply to a length-prefix reader.** The
   ack arrives as raw JSON, so a frame reader interprets `{"ch` as a big-endian
   length of 2,065,851,240, exceeds any sane ceiling and faults the connection.
   The Windows client hit exactly this: even a correctly shaped challenge would
   have torn down the transport on the reply.

The practical shape for a client is to treat a WebSocket **text** frame as
pairing traffic to be parsed directly, and a **binary** frame as length-prefixed
clipboard traffic. That is what the opcodes are already carrying.

**What did interoperate, first try.** Once the framing was bypassed, a bare-JSON
challenge from `Hypo.Core` was accepted by a live Android peer and its ack
verified in under a second. That exercised the X25519 agreement over the
advertised `pub_key`, the HKDF salt and info, AES-256-GCM, the device-id
associated data, snake_case field names, lowercase challenge ids, and the
response-hash check. The cryptography and the message models are correct; only
the transport shape was wrong.

### 3.3 Transport selection

*Revised during implementation. This section previously said every message is
dual-sent, "preserving macOS behaviour". `DualSyncTransport` does not do that,
and should not: sending one clipboard item over both channels delivers it to the
peer twice and leaves the peer to sort it out. The Android client's duplicate
sends were exactly this class of bug seen from the other side.*

`DualSyncTransport` prefers the LAN and falls back to the relay, **per peer
rather than per transport**. "The LAN is up" says nothing about whether a given
device is on it: a phone on cellular and a laptop in the next room are both
paired, and only one is reachable. So a send routes on the envelope's target;
`LanSyncTransport` reports `PeerUnreachableException` when it holds no
connection for that peer, and that is the only failure the dual transport falls
back on. Falling back on any exception would hide a genuine send error behind a
second attempt that quietly succeeds.

Both channels connect concurrently and either alone is enough to start. LAN is
preferred because it is faster, does not leave the building, and works when the
relay is down.

Inbound messages are deduplicated by envelope id, which covers one message
arriving on both channels. It does **not** cover a peer sending the same content
twice as two messages — those carry different ids — so content-level dedup lives
above the transport, after decryption, where a hash of the plaintext is
available. See `ContentDeduplicator`.

### 3.4 Windows clipboard hazards

1. **Images travel as the registered `"PNG"` format, and only that.** Reading
   `CF_DIB` directly produces black backgrounds on semi-transparent images, and
   the protocol already carries PNG bytes — converting to DIB would mean decoding
   and re-encoding an image to hand back something worse. Every browser and image
   editor publishes and accepts `"PNG"`. *The DIB and `CF_BITMAP` fallbacks this
   section originally called for are not implemented: they would only matter for
   an application that publishes a bitmap and no PNG, and none has been observed.
   Writes verify the PNG signature first, so a peer sending JPEG is refused
   rather than advertised as something it is not.*
1. **Files arrive as bytes and have to become a path.** `CF_HDROP` carries paths,
   not contents, so an inbound file is written under
   `%LOCALAPPDATA%\Hypo\received` first. The name comes from a peer: it is
   reduced to a leaf and stripped of characters Windows forbids before anything
   is created, and the reserved device names (`CON`, `NUL`, `COM1`…) are escaped,
   because creating one of those does not fail — it opens a device. The
   sanitising rules are written out rather than taken from
   `Path.GetInvalidFileNameChars`, which answers for the *host*: on Unix a
   backslash is an ordinary character, so those APIs sanitise nothing when the
   code is tested anywhere but Windows.
2. **The clipboard is a globally exclusive resource.** `OpenClipboard` fails when
   another process holds it, which on a desktop with Office, a browser and any
   clipboard manager is routine rather than exceptional. Access goes through a
   wrapper that retries 25 times with 20 ms backoff before reporting failure.
   *Two corrections to the original text. The retry count was 5; that is too few
   when a clipboard manager is active. And "never throws" was replaced with
   "throws where a caller can handle it": the listener's message pump catches it
   and drops one update, because missing an update is survivable and dying on the
   pump thread is not.*
3. **`WM_CLIPBOARDUPDATE` requires a window.** A message-only window
   (`HWND_MESSAGE`) hosts the listener. It is invisible, absent from the taskbar,
   and lives for the process lifetime.
4. **Every clipboard call runs on the message-pump thread.** Not tidiness —
   correctness, in two ways CI demonstrated. Recording our own clipboard sequence
   number from a caller's thread races the update that write causes: the
   notification can be handled before the field is assigned, the echo escapes,
   and two devices bounce one item between them. And a reader on the pump thread
   contends with a writer on a caller's thread for a resource only one can hold,
   which surfaces as `EmptyClipboard` failing on a clipboard we believed we
   owned.
5. **Read the sequence number *after* the clipboard session closes.** It advances
   when the change is committed at `CloseClipboard`, so reading it inside the
   open session returns the value from before our own write — the comparison
   never matches and the echo suppression silently does nothing.

---

## 4. Pairing and key management

### 4.1 Primitive mapping

| Purpose | macOS (CryptoKit) | Windows |
|---------|-------------------|---------|
| Key agreement | `Curve25519.KeyAgreement` | BouncyCastle `X25519Agreement` |
| Pairing signature | `Curve25519.Signing` (Ed25519) | BouncyCastle `Ed25519Signer` |
| Key derivation | `hkdfDerivedSymmetricKey(SHA256, salt, info)` | `HKDF.DeriveKey(SHA256, ikm, 32, salt, info)` |
| Payload encryption | `AES.GCM` | `AesGcm` |

The HKDF `salt` and `info` constants must match `CryptoConstants` byte for byte.
This is a precondition for interoperability and is covered by the shared test
vectors (§8.1).

### 4.2 LAN discovery pairing

```
On start ──► MdnsPublisher advertises _hypo._tcp.local (service name, port, TXT)
         └─► MdnsBrowser watches for the same service type

User selects a discovered device in Settings
         │ the TXT record already carries device_id, pub_key and
         │ signing_pub_key; SRV gives host and port
         ▼
Send PairingChallengeMessage (fresh ephemeral X25519 public key, nonce,
ciphertext, tag)
         ▼
Receive PairingAckMessage (peer's fresh ephemeral X25519 public key)
         ▼
Both sides derive the shared key from (own ephemeral private, peer ephemeral
public) and persist it via DPAPI
```

#### The advertised TXT record

Measured against live macOS and Android peers on a real network, and confirmed
against `macos/Sources/HypoApp/Utilities/BonjourPublisher.swift`:

| Key | Example | Notes |
|-----|---------|-------|
| `device_id` | `007e4a95-0e1a-4b10-91fa-87942efaa68e` | Bare lowercase UUID |
| `pub_key` | base64, 32 bytes | X25519 |
| `signing_pub_key` | base64, 32 bytes | Ed25519 |
| `version` | `1.1.6`, `1.1.6-debug` | App version |
| `fingerprint_sha256` | 64 hex chars | Advertised but not verified by any client |
| `protocols` | `ws+tls` | **Inaccurate — see below** |

Four things this measurement settled, each of which would otherwise have cost
Plan 2 real debugging time:

1. **`protocols=ws+tls` is false advertising.** Both peers announce TLS support
   they do not have: `LanSyncTransport.swift` connects with `ws://` and
   `LanWebSocketServer.swift` binds with `NWParameters.tcp`. A Windows client
   that honoured this field and dialled `wss://` would fail to connect to every
   peer. Ignore the field; the LAN transport is plain WebSocket, and payload
   encryption is the security boundary (section 3.2).
2. **`fingerprint_sha256` is inert, though not meaningless.** It is the SHA-256
   of the advertised key agreement public key, added so peers could pin each
   other; it is not a TLS certificate fingerprint, and there is no certificate
   to pin because there is no TLS. No client verifies it today.
3. **`device_name` is read but never written.** `BonjourBrowser` populates
   `LanEndpoint.deviceName` from a `device_name` TXT key that
   `BonjourPublisher` does not emit, so it is always nil. Display names must
   come from the DNS-SD instance name instead.
4. **Instance names arrive DNS-escaped.** A real peer appears as
   `derek\8217s\032MacBook\032Air\032(2)`, where `\032` is a space and
   `\8217` is a right single quote. The client must unescape decimal escapes
   before showing a name to the user.

#### The pairing exchange, as implemented

`docs/protocol.md` section 9.2 states that the responder returns its ephemeral
public key inside the ACK and that the initiator then re-derives the shared key.
`PairingAckMessage` has no such field. Reading `PairingSession.swift` gives the
actual sequence:

```
Responder  PairingSession.start()
           generates a fresh X25519 pair for this attempt and publishes the
           public half as peer_pub_key, before any challenge arrives
                     ▼
Initiator  derives shared = X25519(own ephemeral private, responder pub_key)
           sends PairingChallengeMessage:
             challenge_id, initiator_device_id, initiator_device_name,
             initiator_pub_key, nonce, ciphertext, tag
           ciphertext = AES-GCM({ challenge, timestamp }),
             aad = utf8(initiator_device_id)
                     ▼
Responder  derives shared = X25519(own ephemeral private, initiator_pub_key)
           replies PairingAckMessage:
             challenge_id, responder_device_id, responder_device_name,
             nonce, ciphertext, tag
           ciphertext = AES-GCM({ response_hash = SHA256(challenge), issued_at }),
             aad = utf8(responder_device_id)
```

Both sides now hold the same key without the ACK carrying one. The responder's
key is published *before* the challenge, not returned after it.

Key rotation is real: `start()` generates a new agreement key on every attempt,
so a re-pairing does not reuse the previous key.

Two more details measured from `TransportManager`:

- **`protocols` is a hardcoded literal**, `["ws+tls"]`, not derived from any
  capability. This is the origin of the false advertising in the previous
  section.
- **`fingerprint_sha256` is the SHA-256 of the advertised key agreement public
  key**, not of a TLS certificate — the code comment says it exists "so peers
  can pin us". The intent was key pinning. No client verifies it, so it is
  currently inert, but it is not meaningless the way a certificate fingerprint
  without TLS would be. A Windows client should publish it the same way and may
  verify it against `pub_key`, which is free.
- **The advertised port is hardcoded to 7010** rather than read back from the
  listener, so a macOS instance that failed to bind 7010 advertises a port it is
  not on. The Windows server reads its bound port back and advertises that, which
  is the behaviour spec section 7 asks for.

#### mDNS library interoperability — validated

Spec section 11 flagged `Makaretu.Dns.Multicast` as the highest-risk dependency
in the project. It was spiked before Plan 2 was written, on a network carrying
live peers, and interoperates in both directions:

- **Windows → peers.** A .NET advertisement was discovered and resolved by
  macOS `dns-sd`, with TXT properties intact.
- **Peers → Windows.** The .NET browser discovered a live macOS client at
  `10.0.0.252:7010` and a live Android client at `10.0.0.17:7010`, with SRV, A
  and TXT records all parsed correctly.

One behaviour to design around: `ServiceDiscovery.ServiceInstanceDiscovered`
fires for **every** service type on the network, not only the one queried — the
spike saw AirPlay, Spotify Connect and Roku instances. Filtering by
`_hypo._tcp.local` is the caller's responsibility, or the device list will fill
with televisions.

### 4.3 Remote code pairing

Six-digit code, 60 second TTL, brokered by the relay:

```
Initiator: POST /pairing/code                        → code + expires_at
           poll GET  /pairing/code/{code}/challenge
           POST /pairing/code/{code}/ack

Responder: user enters the code
           POST challenge → poll GET /pairing/code/{code}/ack
```

Windows implements **both roles**. The protocol is device-agnostic, so
Windows↔Windows, Windows↔macOS and Windows↔Android must all work.

### 4.4 Correctness requirements

1. **Keys rotate on every pairing.** Both parties generate fresh ephemeral key
   pairs even when re-pairing an already-known device. This is the source of
   forward secrecy; reusing an existing key to "save work" breaks it.
2. **`challenge_id` is always lowercase.** Android emits lowercase UUIDs and the
   macOS code carries explicit comments accommodating this. .NET's
   `Guid.ToString("D")` is lowercase by default, but serialisation must assert
   it — an incidental `ToUpper` anywhere silently breaks pairing with Android.
3. **Device IDs are bare lowercase UUIDs.** Platform-prefixed IDs
   (`windows-<uuid>`) were removed in protocol v1.1. Platform is declared only in
   `device.platform`, with the value `windows`.

### 4.5 Key storage

*What shipped is `FileSecretStore`, not the `DpapiSecretStore` this section
originally specified.* It writes one file per key under `%LOCALAPPDATA%\Hypo\`,
restricted to the owner. Key names are validated against `[a-z0-9-_]`, because a
key is a path component and a peer-supplied device id must not be able to
escape the directory.

DPAPI remains the right upgrade and is nobody's commitment yet. It buys
encryption at rest against another account on the same machine that can already
read the files; owner-only permissions already prevent that, so the gain is
against an attacker who has bypassed file permissions — real, but not what
blocked shipping.

`%LOCALAPPDATA%` rather than `%APPDATA%`: roaming profiles synchronise
`%APPDATA%` to other domain machines, where DPAPI ciphertext could not be
decrypted. That reasoning holds for the DPAPI upgrade and costs nothing now.

Four items are stored: this device's id (`local-device-id`), the Ed25519 pairing
signing key, an X25519 agreement key, and one shared key per paired device. The
peers are the GUID-shaped keys; `HypoClient.PairedPeers` filters on that shape
rather than keeping a second list, so pairing stays the single source of truth.

The relay's shared secret is deliberately **not** stored here. It is read at run
time from `HYPO_RELAY_AUTH_TOKEN` or a repo-root `.env`, because baking it into
an MSIX that strangers install makes it a secret only until someone unzips it.
How a shipped build obtains relay credentials is an open question for
packaging.

---

## 5. User interface

### 5.1 History panel behaviour

The macOS history panel is **not** a popover anchored to the menu bar icon. It is
a 360×480 screen-centred floating window (`HistoryPopupPresenter.centeredFrame`).

It also performs **focus handoff**: the frontmost application is recorded before
the panel appears, and focus is returned to it after an entry is chosen, so the
user can immediately paste with the system paste shortcut. Reproducing this is
mandatory — without it the feature is inert.

```
Show:  hPrev = GetForegroundWindow()   ← capture before Show()
Hide:  Hide() → SetForegroundWindow(hPrev)
```

`SetForegroundWindow` is subject to foreground lock; the standard remedies
(`AllowSetForegroundWindow`, or attaching the input queue with
`AttachThreadInput`) apply.

### 5.2 Windows

**Tray icon** (`Hypo.Wpf`, H.NotifyIcon)
- Left click → show history panel
- Right click → version, Show Clipboard, Pause Sync, Settings, Exit
- Icon reflects connection state: connected / cloud-only / offline

**History panel** (`HistoryWindow`, 360×480, centred)

```
WindowStyle=None, ShowInTaskbar=False, Topmost=True
WS_EX_TOOLWINDOW  → excluded from Alt+Tab
Deactivated       → auto-hide
Esc               → hide
```

Contents, matching the macOS feature set:
- Live-filtering search box
- Type filter: all / text / link / image / file
- Date filter: today / this week / all
- Row: type icon, content preview, source device name, transport-origin badge
  (LAN or cloud), encryption indicator, timestamp
- Pinning; pinned entries sort first
- Double-click or Enter → write to clipboard and hand focus back
- **Drag-to-paste** via `DragDrop.DoDragDrop`. Text as `CF_UNICODETEXT`, images as
  `CF_DIBV5` plus `"PNG"`, files as `FileDrop` — file bytes are materialised to
  `%TEMP%\Hypo\` first (counterpart to macOS `TempFileManager`)
- `VirtualizingStackPanel` so 200 entries with thumbnails stay smooth

**Settings window** (`SettingsWindow`, ordinary window, appears in taskbar)
- Devices: paired list (online state, last seen, unpair), LAN discovery list,
  initiate or enter a six-digit pairing code
- Transport: enable LAN, enable cloud relay, LAN port
- History: retention limit (default 200), clear history
- General: run at login, global hotkey, Windows clipboard history integration,
  cloud clipboard upload
- Status: live connection state and transport statistics

**Notifications**: Windows App SDK `AppNotificationManager`, with content
preview; clicking opens the history panel. Locally originated copies do **not**
notify — only remote arrivals do (macOS has an explicit suppression branch for
the local-echo case).

**Global hotkey**: `RegisterHotKey`, default `Alt+V` (macOS uses Option+V),
reconfigurable. `Win+V` is reserved by the system clipboard history. Registration
failure — typically another application holding the combination — is surfaced in
Settings rather than failing silently.

### 5.3 Theming

`Hypo.Wpf` uses the WPF-UI Fluent resource dictionary and follows the system
light/dark setting. On Windows 11, Mica is enabled via `DwmSetWindowAttribute`
(`DWMWA_SYSTEMBACKDROP_TYPE`). On Windows 10 the app falls back to a solid
background. The fallback is written explicitly; it is not left to chance.

---

## 6. Windows platform enhancements

### 6.1 Explorer context menu — "Copy to Hypo"

Declared in the MSIX manifest as a `desktop4:FileExplorerContextMenus`
extension. One implementation serves both the Windows 10 classic menu and the
Windows 11 menu, and uninstalling removes it cleanly with no registry residue.

**Constraint**: Explorer loads shell extension DLLs into its own process, and
managed code inside Explorer has long been discouraged because CLR version
conflicts destabilise the desktop shell. `Hypo.ShellExtension` is therefore a
separate **NativeAOT-compiled** project using source-generated COM to implement
`IExplorerCommand`, producing a native DLL with no runtime dependency.

The extension contains no sync logic. It passes selected file paths to the main
application over a named pipe, `\\.\pipe\hypo-<user SID>`, whose ACL is
restricted to the current user so other accounts on the machine cannot inject
content. If the main application is not running, the extension launches it.

### 6.2 Windows clipboard history (Win+V) coexistence

Content written to the clipboard is picked up by the system clipboard history
automatically **unless** the writer adds the
`ExcludeClipboardContentFromMonitorProcessing` format. The setting therefore
controls whether that exclusion marker is written, not whether content is pushed.

Two independent settings, both **default off**:

| Setting | Default | Effect when off |
|---------|---------|-----------------|
| Share with Windows clipboard history | Off | Write `ExcludeClipboardContentFromMonitorProcessing` |
| Allow cloud clipboard upload | Off | Write `CanUploadToCloudClipboard = 0` |

They are separate because the exposures differ in kind. Local Win+V history stays
on the machine and the user can clear it themselves. Cloud clipboard uploads
synced content to a Microsoft account and roams it to the user's other machines,
which is in tension with the project's "the relay never stores clipboard content"
posture. Both are opt-in, and the cloud setting states the consequence in the UI.

---

## 7. Error handling

| Condition | Handling |
|-----------|----------|
| Firewall prompt on first bind | Manifest declares `privateNetworkClientServer`; the UI forewarns the user before the first bind and advises selecting "Private network" |
| Port 7010 already in use | Fall back to an OS-assigned ephemeral port and **advertise the actual port over mDNS**. The port must never be hardcoded on the wire; `PairingPayload` already carries it |
| mDNS multicast blocked (enterprise networks) | Degrade to cloud-only and display "LAN unavailable" in the status area. Never fail silently |
| Clipboard held by another process | Retry up to 5 times with 20 ms backoff, then skip the round and log |
| Payload over 10 MB | Images degrade per protocol §3.2.3 (scale if longest side > 2560 px, JPEG 85%, then 75% → 40%); files are skipped with a user notification |
| Message timestamp older than 5 minutes | Discard (replay protection) |
| DPAPI decryption failure (profile copied to another machine) | Clear stored keys and prompt to re-pair, rather than looping on errors |
| System theme changes at runtime | WPF-UI follows; Mica is reapplied |

---

## 8. Testing

### 8.1 Shared test vectors

`Hypo.Core.Tests` (xUnit) consumes the fixtures already shared by the macOS and
Android suites. Both existing clients read these same two files:

| Fixture | Covers |
|---------|--------|
| `tests/crypto_test_vectors.json` | HKDF salt and info constants, an AES-256-GCM case (RFC 5116 case 17), and an X25519 key agreement with its expected derived key |
| `tests/transport/frame_vectors.json` | `TransportFrameCodec` framing — base64 wire bytes paired with the decoded envelope |

The HKDF constants are `salt = "hypo-clipboard-ecdh"` and
`info = "hypo-aes-256-gcm"`, recorded base64-encoded in the fixture.

Passing these establishes byte-level agreement on frame encoding, AES-GCM and
X25519/HKDF with the other two clients. This is the primary mechanism preventing
a third client implementation from drifting, not a supplementary one. It is also
why the Rust-shared-core approach was rejected (§10).

**Known gap: gzip is not covered by any shared fixture.** Compression sits
between JSON encoding and encryption (protocol §3.6) and is currently verified
only by each client's own round-trip tests, which cannot catch cross-client
divergence. The implementation plan adds a gzip vector to
`tests/crypto_test_vectors.json` and back-fills it into the macOS and Android
suites, so all three clients verify the same bytes.

The other two files under `tests/transport/` — `cloud_metrics.json` and
`lan_loopback_metrics.json` — are latency baselines for the transport metrics
aggregator, not correctness vectors.

### 8.2 Coverage and suites

- Coverage target ≥80%, matching the repository standard. This is attainable
  because `Hypo.Core` has no UI and no Win32 dependency.
- `Hypo.Platform.Windows.Tests`: clipboard retry logic, DPAPI round-trip, format
  priority (`"PNG"` → `CF_DIBV5` → `CF_BITMAP`).
- Cross-platform integration: `scripts/test-sync-matrix.sh` currently covers
  macOS↔Android and must be extended with Windows↔macOS, Windows↔Android and
  Windows↔Windows.

---

## 9. Packaging, distribution and CI

### 9.1 MSIX manifest declarations

```
windows.startupTask                  Run at login. Users can disable it in Task
                                     Manager; the Settings toggle calls
                                     StartupTask.RequestEnableAsync()
desktop4:FileExplorerContextMenus    "Copy to Hypo"
com:Extension (Hypo.ShellExtension)  NativeAOT IExplorerCommand COM server
privateNetworkClientServer           LAN send and receive
```

MSIX is required rather than merely preferred: the Windows 11 context menu
effectively requires package identity, and "Copy to Hypo" is in scope. Run-at-login
and clean uninstall are secondary benefits.

### 9.2 Distribution channels

1. **MSIX on GitHub Releases**, signed through **SignPath Foundation**, which
   provides free OV-level code signing to qualifying open-source projects. The
   private key is held in SignPath's HSM and the service verifies the binary was
   built from the public repository. Hypo qualifies: public codebase, MIT licence.
   A certificate chaining to a trusted root means users install by double-clicking
   with no certificate import and no SmartScreen interstitial.
2. **winget manifest** pointing at that MSIX — the primary entry point for
   developer-oriented users.
3. Microsoft Store is deferred (§1, out of scope).

**ARM64 is built and verified on real hardware separately.** A `.msixbundle` is
not assumed to cover it. LocalSend has an open issue where its Windows 11 ARM64
package cannot be installed, which is the failure mode this guards against.

**Contingency.** SignPath Foundation approval takes time and is not guaranteed.
If a release is needed before approval, or if approval does not come, fall back
to a portable ZIP plus an Inno Setup installer. The cost is that the context menu
must revert to classic `shellex` registration, which on Windows 11 appears only
under "Show more options". Core functionality is unaffected.

### 9.3 CI changes

- `ci.yml`: add a `windows-latest` job running `dotnet build` and `dotnet test`
- `release.yml`: add MSIX packaging for the `x64` and `arm64` RIDs, combined into
  `Hypo-{version}.msixbundle`
- Signing credentials stored as GitHub Secrets
- `RELAY_WS_AUTH_TOKEN` injected at build time via an MSBuild-generated
  `BuildConstants.cs`, mirroring the macOS `Info.plist` and Android
  `build.gradle.kts` injection
- `scripts/update-version.sh` extended to update the MSIX manifest version

### 9.4 Build constraint

The Windows client cannot be built on macOS. `scripts/build-all.sh` does not
cover it. Development requires a Windows machine or VM; CI uses the
`windows-latest` runner.

---

## 10. Alternatives considered

**WinUI 3 instead of WPF.** WinUI 3 provides native Fluent rendering on Windows
11, but its two weakest areas are load-bearing features here: dragging content
out to external applications (particularly files) has long-standing unresolved
problems, and a borderless always-on-top window that auto-hides on deactivation
and stays out of Alt+Tab requires extensive Win32 interop against its
deliberately narrowed `AppWindow` model. On Windows 10 — half the support matrix —
the two frameworks look identical, since Mica does not exist there. WPF can also
enable Mica on Windows 11 through `DwmSetWindowAttribute`, leaving the real
difference at the level of control animation and scroll feel. The three-layer
split (§2) keeps a WinUI 3 migration to a rewrite of `Hypo.Wpf` alone.

**Shared Rust core with a C# shell, or Tauri 2.** The appeal is implementing
crypto and protocol once. But `backend/` is a relay that only forwards
ciphertext — it contains no clipboard monitoring, pairing or history logic — so
there is no existing Rust client core to reuse, and writing one is no less work
than writing C#. Added costs: a hand-written FFI boundary, doubled CI toolchains,
and ARM64 cross-compilation. The consistency problem it solves is already
addressed more cheaply by the shared test vectors (§8.1). Tauri additionally
conflicts with the PRD's native-UI requirement and would still require
hand-written Win32 code for clipboard formats.

**Traditional installer instead of MSIX.** Rejected because the Windows 11
context menu requires package identity. Retained as the contingency plan if
SignPath approval does not materialise (§9.2).

---

## 11. Open items for the implementation plan

- Confirm `desktop4:FileExplorerContextMenus` behaviour on the Windows 10 22H2
  floor during implementation; adjust to classic `shellex` registration if it
  proves unavailable there.
- ~~Determine whether `Makaretu.Dns.Multicast` interoperates with macOS Bonjour
  and Android NSD advertisements in practice.~~ **Done.** Spiked against live
  macOS and Android peers before Plan 2 was written; interoperates in both
  directions. See section 4.2 for the measured TXT schema and the four
  behaviours it settled.
- Apply to SignPath Foundation early — approval latency is on the critical path
  for the first signed release.
