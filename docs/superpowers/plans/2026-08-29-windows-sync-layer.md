# Windows Client — Plan 5: The Sync Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Turn two working transports into a clipboard that actually syncs —
one copy in, one entry out, remembered across restarts — and make the phone's
double-send stop showing up twice.

Plans 2 through 4 built the wire. Nothing above it exists yet: the harness
encrypts and decrypts inline, keeps nothing, and prints whatever arrives.

## What Plan 4 left for this plan

**The phone sends the same clipboard item twice over the relay, with different
envelope ids.** Measured, not suspected: two envelopes, same content, same
sender, both addressed to us rather than broadcast. `DualSyncTransport` dedups
by envelope id, which is correct for the case it was built for — one message
arriving on both the LAN and the relay — and cannot help here, because these
are two messages.

Suppressing them needs a hash of the *decrypted* content. A transport cannot
compute it: it sees ciphertext, and two encryptions of the same plaintext under
different nonces share no bytes. So content dedup lives here, above the
transport and after decryption, which is where Android does it too.

**Android's log hash is worth matching.** It logs the first 16 hex characters
of `SHA-256(content)` on every accepted item. Emitting the same value costs
nothing and makes the two devices' logs directly comparable, which is the
difference between "both say they handled something" and "both handled the same
thing".

**Android dedups by message id and does not content-dedup inbound.** Observed
directly: the phone applied a message, a Mac on the same account echoed it back
over the relay seconds later with a fresh id, and the phone applied it again.
Do not assume the peer will suppress anything on our behalf.

---

## Task 1: Content identity

**Files:**
- Create: `windows/src/Hypo.Core/Sync/ClipboardContent.cs`
- Create: `windows/tests/Hypo.Core.Tests/ClipboardContentTests.cs`

- [x] **Step 1: Tests first**

1. The same bytes and content type hash equal; different bytes do not.
2. The same bytes under *different* content types do not collide — a text item
   and a file item that happen to share bytes are not the same clipboard entry.
3. The short form is the first 16 hex characters of `SHA-256(content)`, matching
   what Android logs, pinned against a value computed independently with
   `python3 -c "import hashlib; ..."`.
4. Hashing is stable across process runs — no `GetHashCode`, no
   `Random`-seeded anything. Dedup that resets on restart is not dedup.

- [x] **Step 2: Implement, then verify** — `cd windows && dotnet test`.

---

## Task 2: Suppress the duplicate

**Files:**
- Create: `windows/src/Hypo.Core/Sync/ContentDeduplicator.cs`
- Create: `windows/tests/Hypo.Core.Tests/ContentDeduplicatorTests.cs`

- [x] **Step 1: Decide the window, and write down why**

Identical content is not always a duplicate — a person can copy the same string
twice on purpose, and that is a real second event they will expect to see.
So the rule is time-bounded: identical content within a short window of the
last accepted item is a duplicate; the same content later is a new entry.

Pick a window in the low seconds and justify it in the doc comment against the
measurement: Plan 4's two copies arrived within the same second.

- [x] **Step 2: Tests**

1. Two identical items in quick succession yield one.
2. The same content after the window yields two — a person copying the same
   thing twice is not a bug to be swallowed.
3. Different content inside the window yields two.
4. An injected clock drives the window. A test that sleeps is a test that is
   slow and flaky; the behaviour under test is the rule, not the wait.
5. The cache is bounded, and eviction is by age. A count cap is a backstop
   only: it *can* discard an entry the window still covers, so set it far above
   any realistic burst and write a test that documents that trade rather than
   one that pretends it does not exist. The real bound is arrival rate times the
   window, which is a few thousand entries even at implausible rates.

- [x] **Step 3: Implement, then verify** — `dotnet test`.

---

## Task 3: A clipboard we can test without a clipboard

**Files:**
- Create: `windows/src/Hypo.Core/Sync/IClipboard.cs`
- Create: `windows/tests/Hypo.Core.Tests/FakeClipboard.cs`

- [x] **Step 1: Define the seam**

Read the current item, write an item, and raise an event when it changes. The
Windows implementation (`AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE`)
belongs to the Windows plan; this plan needs only the interface and a fake,
because everything above it must be testable on any machine.

State plainly in the interface doc that a write must not be re-published as a
change. Applying a peer's item raises the OS's change notification, and a
coordinator that re-sends it puts the two devices in a loop. This is the single
most likely way to build an infinite sync loop, so it is the interface's job to
say so.

- [x] **Step 2: Verify** — `dotnet test`.

---

## Task 4: Remember

**Files:**
- Create: `windows/src/Hypo.Core/History/ClipboardHistoryStore.cs`
- Create: `windows/tests/Hypo.Core.Tests/ClipboardHistoryStoreTests.cs`

SQLite via `Microsoft.Data.Sqlite`, matching what the macOS and Android clients
keep.

- [x] **Step 1: Tests**

1. An item survives closing and reopening the store.
2. Items come back newest first.
3. Re-adding existing content moves it to the top rather than duplicating it —
   this is what the phone does, and matching it keeps the two histories legible
   side by side.
4. The store is bounded, and the oldest go first.
5. Opening a store whose file is corrupt does not throw at construction. A
   clipboard tool that will not start because its history is damaged has turned
   a cosmetic problem into a fatal one; rebuild and carry on.

- [x] **Step 2: Implement, then verify** — `dotnet test`.

---

## Task 5: Wire it together

**Files:**
- Create: `windows/src/Hypo.Core/Sync/SyncCoordinator.cs`
- Create: `windows/tests/Hypo.Core.Tests/SyncCoordinatorTests.cs`

Outbound: clipboard change → history → encrypt → transport.
Inbound: transport → decrypt → dedup → history → clipboard.

- [x] **Step 1: Tests, with the loop test first**

1. **No echo.** Applying an inbound item must not send it back out. Write this
   one first; it is the failure that is unbounded rather than merely wrong.
2. An outbound item is encrypted with a fresh nonce every time. Send the same
   content twice and assert the two nonces differ — reuse under one key is
   catastrophic, and `CryptoService.Encrypt`'s remarks say so.
3. An inbound item whose AAD does not match the sender is rejected. A peer
   claiming to be someone else in the body is exactly what the associated data
   exists to catch.
4. An inbound duplicate (Task 2's case) reaches the clipboard once.
5. An item from an unpaired peer is dropped with a clear reason, not a crash.

- [x] **Step 2: Implement, then verify** — `dotnet test`.

---

## Task 6: One copy on the phone, one entry on Windows

**Files:**
- Modify: `windows/tools/Hypo.Harness/Program.cs`
- Modify: this plan (record the outcome)

- [x] **Step 1: Put the coordinator behind the harness**

Have `listen` and `cloud` go through `SyncCoordinator` instead of decrypting
inline, so the thing being tested is the thing that will ship.

- [x] **Step 2: Reproduce the double-send, then show it absorbed**

The phone's duplicate only appeared on the relay path with no LAN route, so
reproduce it that way: `cloud` with no mDNS started.

```
adb shell "am start -n com.hypo.clipboard/.ProcessTextActivity \
  -a android.intent.action.PROCESS_TEXT -t text/plain \
  --es android.intent.extra.PROCESS_TEXT '<text>'"
```

Quote the whole `am` invocation for the device shell. Two envelopes should
still arrive — that is the phone's behaviour and this plan does not change it —
and exactly one entry should reach the history and the clipboard.

- [x] **Step 3: Check the phone's side with the system's logs, not the app's**

The Hypo tags (`IncomingClipboardHandler`, `ClipboardSyncService`) stopped
appearing partway through Plan 4 after the app restarted under a new pid, and
chasing them produced a wrong conclusion twice. The system's own
`ClipboardService` lines (`clipboardAccessAllowed … callingPackage=com.hypo.clipboard`)
come from a different process and kept working.

- [x] **Step 4: Record the outcome**, including anything this plan asserted that
      turned out to be false.

### Task 6 outcome — one copy, one entry

Verified on 2026-08-29 over the deployed relay.

Two envelopes with different ids carrying identical content, addressed rather
than broadcast — the shape Plan 4 measured the phone producing — were sent 200 ms
apart to a second harness running the coordinator:

```
sent id 0242633d-4566-45b1-95f0-b6484159cd2a
sent id 048d92cd-b10b-4647-be78-fe3a51e58dd6

[applied] Text hash=f81919e243c4253b from=Pretend Phone: one copy should become one entry
[dropped] Duplicate of a recent item from 11111111-…-555555555555 (hash=f81919e243c4253b).
```

One applied, one dropped, and the history holds exactly one row. The log hash
matches `python3 -c "import hashlib; hashlib.sha256(text).hexdigest()[:16]"`,
which is the value Android prints, so the two devices' logs line up.

**The duplicate was reproduced, not organic, and that is a real limitation.**
Step 2 asked for the phone's own double-send. It could not be obtained: the
phone stopped being able to reach the relay partway through this task.

**The phone's relay credentials are being rejected.** From its own logs:

```
❌ Connection failed: wss://hypo.fly.dev/ws
   - Expected HTTP 101 response but was '401 Unauthorized' (ProtocolException)
```

Our client authenticates against the same relay with the token from the
repo-root `.env`, and both `RELAY_WS_AUTH_TOKEN` entries in that file are
identical, so this is not an ambiguous config. The installed APK carries a
`RELAY_WS_AUTH_TOKEN` baked in at build time that no longer matches the relay's
secret. **The phone therefore has no cloud sync at all right now** — this is a
product problem, not a test-harness one, and rebuilding the app is the fix.
Nothing here reinstalls it, because that is the user's device.

Worth noting for whoever picks this up: the phone was on cellular (LTE), not
Wi-Fi, when this was observed. That makes the no-LAN condition unusually clean
if the auth is fixed and the organic test is retried.

**A trap found while wiring the harness.** `SqliteConnection.Dispose` returns
the connection to a pool and keeps the file handle, so the history store's
"delete the corrupt file and start again" path was quietly undone — the next
open handed back the very connection that had just failed on the old file.
`SqliteConnection.ClearPool` before the delete is what makes it work, and the
test only caught it because it wrote genuinely invalid bytes rather than an
empty file.
