# Windows Client — Plan 4: Cloud Relay Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync clipboard between Windows and a real phone when they are not on
the same network, through the deployed relay at `wss://hypo.fly.dev/ws`, and
prefer the LAN whenever it is available.

Plan 3 closed the LAN in both directions. Everything below is the second
transport and the thing that chooses between them.

## What a spike against the live relay already established

Do not re-derive these. Each was verified on 2026-08-29 against the deployed
relay (`/health` reported version 1.1.6) and the OPPO test phone, which was
connected to the relay throughout.

**Auth is three request headers.** `X-Device-Id`, `X-Device-Platform`, and
`X-Auth-Token`, where the token is
`base64(HMAC-SHA256(key: RELAY_WS_AUTH_TOKEN, msg: lowercased device id))`.
The device id in the header is lowercased by the relay before the HMAC is
checked, so sign the lowercased form. Missing headers get a 400; a bad token
gets a 401. The shared secret lives in the repo-root `.env`, which is
gitignored — Android injects it at build time via `buildConfigField`.

**The relay says nothing on connect.** No welcome frame, no ack, no session id.
A client that waits for one waits forever.

**Framing is exactly the LAN's.** A binary WebSocket frame carrying a 4-byte
big-endian length prefix followed by the envelope JSON. The relay parses the
JSON only far enough to route, then forwards the frame byte-for-byte. Server
max frame size is 1 GB, far above our 20 MB ceiling.

**Routing is one optional field.** `payload.target`, lowercased by the relay.
Set it and the frame goes to that device alone; omit it and the frame is
broadcast to every other connected device on the account. Both were verified
delivering to the phone, which decrypted and applied them.

**The session key is transport-agnostic.** The key negotiated during *LAN*
pairing decrypted a cloud-delivered message on the phone with no changes. AAD
is still the sender's lowercased device id alone, as Plan 2 established.

**An offline target produces an error envelope, and it reuses your message id.**

```json
{"id": "<the id of the message you sent>", "type": "error", "version": "1.0",
 "timestamp": "2026-08-29T21:54:28.509290711+00:00",
 "payload": {"code": "device_not_connected",
             "message": "Target device … is not connected …",
             "target_device_id": "…", "original_message_id": "<same id>",
             "connected_devices": ["…", "…"]}}
```

Two consequences worth stating plainly. The payload has no `encryption` block,
so anything that assumes every inbound envelope is decryptable will throw on
the first undeliverable message. And because `id` is *your* id rather than a
fresh one, a dedup cache keyed on envelope id will treat the error as a message
it has already seen — or, worse, suppress the real delivery if the error
arrives first.

**Relay timestamps carry nine fractional digits** (`...28.509290711+00:00`)
rather than the seconds-precision `Z` form we emit.
`Utf8JsonReader.GetDateTimeOffset()` parses them, truncating to seven digits.
This was measured, not assumed; `Iso8601DateTimeOffsetConverter` needs no
change on the read side.

**Keepalive is the client's job.** The relay answers Ping with Pong and never
initiates. Fly.io closes idle connections at 900 s (`backend/fly.toml`), and
Android pings every 840 s. Match that: a shorter interval only costs battery on
the phone's side of an idle link, and a longer one gets the socket closed.

**Messages that fail the relay's `validate_encryption_block` are dropped
silently** — no error frame, no log the client can see. If a message vanishes
with the target online, suspect the encryption block's shape first.

## What already exists

`ISyncTransport` (`windows/src/Hypo.Core/Transport/ISyncTransport.cs`) was
written with this transport in mind, and `TransportOrigin.Cloud` is already
defined. Its doc comment says "Plan 3 adds the cloud relay" — the plans were
renumbered when the LAN turned out to need a plan of its own, so fix that
comment to say Plan 4 as you go past it.

`LanWebSocketClient` is the model to follow for connect/send/receive and state
transitions. The framing codec, crypto, gzip and JSON layers are all shared and
need no cloud-specific work.

---

## Task 1: Compute the relay auth token

**Files:**
- Create: `windows/src/Hypo.Core/Relay/RelayAuthToken.cs`
- Create: `windows/tests/Hypo.Core.Tests/RelayAuthTokenTests.cs`

- [ ] **Step 1: Write the failing tests first**

Three properties, and the third is the one that actually bites:

1. A known secret and device id produce a known base64 token. Generate the
   expected value with `python3 -c` using `hmac`/`hashlib` and paste it in, so
   the test pins the construction rather than restating it.
2. The token is standard base64 *with* padding — the relay accepts unpadded
   too, but we should emit one form and know which.
3. A device id given in **upper case** produces the same token as its lowercase
   form. The relay lowercases before verifying; a client that signs the
   uppercase string authenticates fine on macOS (which lowercases early) and
   fails on any path that does not.

- [ ] **Step 2: Implement**

A static class with one method. It takes the secret as a `string` and the
device id as a `string`, lowercases the id with `ToLowerInvariant()`, and
returns the base64 of `HMACSHA256.HashData(secretBytes, idBytes)`.

- [ ] **Step 3: Verify**

`cd windows && dotnet test` — all green.

---

## Task 2: Configure where the secret comes from

**Files:**
- Create: `windows/src/Hypo.Core/Relay/RelayOptions.cs`
- Create: `windows/tests/Hypo.Core.Tests/RelayOptionsTests.cs`

The secret must not be committed. Android reads repo-root `.env` at build time
and bakes it into `BuildConfig`; that is a build-time choice we should not copy
blindly, because the Windows client will eventually be an MSIX that strangers
install, and a baked-in shared secret in a public artifact is a secret only
until someone unzips it.

- [ ] **Step 1: Decide and write down the reasoning**

For now the harness and tests need the secret and the shipping app does not
exist yet, so read it from the `HYPO_RELAY_AUTH_TOKEN` environment variable and
fall back to repo-root `.env` when running from a source checkout. Record in
the class doc comment that this is a development affordance and that shipping
an MSIX with an embedded shared relay secret is an open question for the
packaging plan — do not let it be discovered later as an accident.

- [ ] **Step 2: Tests**

Missing secret produces a clear, actionable error rather than a null reference
or an empty-string HMAC. An empty-string secret is treated as missing: the
relay's own `verify_ws_auth` rejects an empty `RELAY_WS_AUTH_TOKEN`, so
accepting one here would only move the failure somewhere less legible.

- [ ] **Step 3: Verify** — `dotnet test`, and confirm nothing you added prints
      the secret. Grep your own diff for it.

---

## Task 3: The cloud transport

**Files:**
- Create: `windows/src/Hypo.Core/Transport/CloudWebSocketClient.cs`
- Create: `windows/tests/Hypo.Core.Tests/CloudWebSocketClientTests.cs`

- [ ] **Step 1: Tests against a local stub, not the live relay**

Stand up a `LanWebSocketServer`-style stub, or a bare `HttpListener`
WebSocket, on localhost and point the client at it. Assert:

1. The three headers are present on the upgrade request, and `X-Auth-Token`
   matches Task 1's output for the configured device id.
2. A sent envelope arrives as a **binary** frame whose first four bytes are the
   big-endian body length.
3. An inbound framed envelope raises `EnvelopeReceived` with
   `Origin == TransportOrigin.Cloud`.
4. An inbound `type: "error"` envelope does **not** raise `EnvelopeReceived`
   and does not throw. Use the exact JSON recorded above, `connected_devices`
   and all. This is the case that will happen in production on day one.

- [ ] **Step 2: Implement**

Mirror `LanWebSocketClient`: `ClientWebSocket`, `Options.SetRequestHeader` for
the three headers, the shared `TransportFrameCodec` and `FrameReader`, the same
`StateChanged` transitions.

Route inbound envelopes on `type`: `clipboard` raises `EnvelopeReceived`;
`error` raises a new `RelayErrorReceived` event carrying the code, the message,
the target and the original message id. Anything else is ignored, logged, and
does not kill the connection — the relay is a shared service and may grow
message types before we do.

`PeerDeviceId` on `EnvelopeReceivedEventArgs` has no handshake to come from
here, unlike the LAN. Take it from `payload.device_id` and say so in a comment:
the value is *unauthenticated* until the AAD check passes during decryption,
which is precisely the check that makes trusting it safe.

- [ ] **Step 3: Verify** — `dotnet test`.

---

## Task 4: Stay connected

**Files:**
- Modify: `windows/src/Hypo.Core/Transport/CloudWebSocketClient.cs`
- Create: `windows/tests/Hypo.Core.Tests/CloudKeepaliveTests.cs`

- [ ] **Step 1: Keepalive**

Fly.io closes idle connections at 900 s and the relay never pings first. Send a
WebSocket ping every 840 s, matching Android. Make the interval injectable so
the test does not take fourteen minutes; drive it from an injected interval,
and assert a ping is actually observed by the stub server rather than sleeping
and hoping.

- [ ] **Step 2: Reconnect with backoff**

On an unexpected close, reconnect with exponential backoff and jitter, capped
at a minute. Two things the test must pin: the backoff does not busy-loop when
the relay refuses the connection outright (a 401 from a bad secret will retry
forever otherwise, hammering a shared service), and an explicit
`DisconnectAsync` stops reconnection rather than racing it.

- [ ] **Step 3: Verify** — `dotnet test`.

---

## Task 5: Choose a transport

**Files:**
- Create: `windows/src/Hypo.Core/Transport/DualSyncTransport.cs`
- Create: `windows/tests/Hypo.Core.Tests/DualSyncTransportTests.cs`

- [ ] **Step 1: Decide the policy before writing it**

LAN is preferred when a peer is discoverable and connected: it is faster, it
does not leave the building, and it works when the relay is down. Cloud is the
fallback. State the rule in the class doc comment so the next reader does not
have to infer it from control flow.

- [ ] **Step 2: Tests**

1. With both transports connected, a send goes over LAN only.
2. With LAN disconnected, the same send goes over cloud.
3. A message received on both is surfaced **once**.
4. Dedup does not confuse a relay error with a delivery. The error envelope
   carries the id of the message *we sent*; a cache keyed on id alone will
   either drop a legitimate inbound message or mark our own send as seen.
   Assert the specific sequence: send a message with id X, receive an error
   envelope with id X, then receive a genuine inbound message with id X from
   the peer — the last one must still be surfaced.
5. Fanning one message across both transports must give each its own nonce.
   `ISyncTransport.SendAsync`'s remarks already warn about this; if the dual
   transport ever sends the same sealed envelope twice that is fine (the
   ciphertext is identical, one nonce, one key, one message), but if it ever
   *encrypts twice*, the two nonces must differ. Write the test that fails if
   someone later reuses one.

- [ ] **Step 3: Implement, then verify** — `dotnet test`.

---

## Task 6: Sync with the phone over the relay, with no LAN

The milestone. Everything before this is unverified in the way that matters.

**Files:**
- Modify: `windows/tools/Hypo.Harness/Program.cs` (add a `cloud` command)
- Modify: this plan (record the outcome)

- [ ] **Step 1: Add the harness command**

`cloud` connects to the relay with the stored device id and prints anything it
receives, exactly as `listen` does for the LAN. It should reuse the persisted
key store, so a peer paired over the LAN in Plan 3 is already usable here.

- [ ] **Step 2: Prove the LAN is genuinely out of the picture**

Otherwise a passing test proves nothing about the cloud. Either put the phone
on cellular with Wi-Fi off, or run `cloud` without ever starting mDNS. State in
the outcome which one you did — "it worked" without saying how the LAN was
excluded is not evidence.

- [ ] **Step 3: Both directions**

Windows to phone: send from the harness, confirm the phone applies it. The
phone's clipboard is not passively monitored on Android 10+, so to send *from*
the phone use its real entry point:

```
adb shell "am start -n com.hypo.clipboard/.ProcessTextActivity \
  -a android.intent.action.PROCESS_TEXT -t text/plain \
  --es android.intent.extra.PROCESS_TEXT '<text>'"
```

Quote the whole `am` invocation for the device shell — unquoted, `am` splits on
spaces and silently takes a later word as the package name, which looks like
success and delivers a truncated string.

- [ ] **Step 4: Watch for the echo**

The account may have a Mac on the relay too. A message you send can come back
to the phone attributed to that Mac a few seconds later, which reads like your
own message arriving twice. Check `device_id` in the log line, not the text.

- [ ] **Step 5: Record the outcome**

Add a "Task 6 outcome" section: what ran, how the LAN was excluded, what
arrived in each direction, and anything this plan asserted that turned out to
be wrong.
