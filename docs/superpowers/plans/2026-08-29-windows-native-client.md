# Windows Client — Plan 6: The Windows Clipboard and a Runnable Client

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A program you can run on Windows that syncs the real clipboard with a
real phone. No tray icon, no window — those come next, and they are the parts
CI cannot judge.

Plans 2 through 5 are all cross-platform .NET and were verified against real
devices from a Mac. Everything from here is Windows-only, and the machine doing
the work is not a Windows machine. That constraint shapes this plan: it covers
exactly the Windows-specific code whose correctness a headless CI runner can
actually establish — P/Invoke signatures, the message loop, clipboard format
handling, ownership and retry — and stops before the parts where "it compiled"
is the only thing CI could tell us.

## What CI can and cannot see

The `Windows Core Tests` job runs `dotnet test` on `windows-latest`. It is a
real Windows kernel with a real clipboard, so a test may open the clipboard,
write to it, read it back, and observe `WM_CLIPBOARDUPDATE`. It has no
interactive desktop session in the way a logged-in user does, which is worth
remembering when a test hangs rather than fails.

It cannot judge a tray icon, a window layout, or whether a hotkey feels right.
Those belong to the plan after this one.

Plan 5 already produced the evidence that this split is worth making: a SQLite
connection-pool defect that made the store hold its file open was invisible on
macOS and turned seventeen tests red on Windows. Windows-only code needs
Windows-only tests, and this plan writes them.

---

## Task 1: Clipboard formats

**Files:**
- Create: `windows/src/Hypo.Windows/Clipboard/ClipboardFormats.cs`
- Create: `windows/tests/Hypo.Windows.Tests/ClipboardFormatsTests.cs`
- Create: `windows/src/Hypo.Windows/Hypo.Windows.csproj`
- Create: `windows/tests/Hypo.Windows.Tests/Hypo.Windows.Tests.csproj`

A new project, because `Hypo.Core` must keep building and testing on any
machine: it is what the Mac-side verification depends on. Target
`net10.0-windows`, and add both to `windows/Hypo.sln`.

- [ ] **Step 1: Decide what maps to what, and write it down**

`ContentType.Text` is `CF_UNICODETEXT`, `Link` is text that parses as an
absolute URI, `Image` is a PNG, and `File` is `CF_HDROP`. Say in the doc
comment that `CF_TEXT` is deliberately not used: it is code-page dependent and
loses anything outside the active ANSI page, which for this project means
Chinese text arriving as question marks. Plan 3 sent CJK over the wire
successfully; that must not be lost at the last step.

- [ ] **Step 2: Tests**

1. Round-trip a plain ASCII string.
2. Round-trip a string with CJK, emoji, and a lone surrogate-looking sequence.
   Encoding is where this breaks, and it breaks silently.
3. A string that parses as an absolute URI maps to `Link`; one that does not
   stays `Text`. `"C:\\Users"` is not a link.
4. An empty clipboard reports nothing rather than throwing.

- [ ] **Step 3: Implement, then verify** — `cd windows && dotnet test`.

---

## Task 2: The Win32 clipboard, with the retry everyone forgets

**Files:**
- Create: `windows/src/Hypo.Windows/Clipboard/WindowsClipboard.cs`
- Create: `windows/tests/Hypo.Windows.Tests/WindowsClipboardTests.cs`

- [ ] **Step 1: Open with a retry, and say why in a comment**

`OpenClipboard` fails when another process holds it, and on a busy desktop that
is routine rather than exceptional — Office, browsers and clipboard managers all
take it briefly. A single attempt produces a client that drops copies
intermittently and looks haunted. Retry a handful of times with a short delay,
and surface a real failure only after that.

- [ ] **Step 2: Tests**

1. Reading back what the test itself wrote.
2. A large payload (a megabyte of text) survives, exercising the global-memory
   path rather than the small-string one.
3. Two writes in a row leave the second value, with no leaked handles — assert
   by repeating it a few hundred times and checking the process handle count
   has not grown.
4. `EmptyClipboard` before `SetClipboardData` — omitting it is a documented way
   to leak the previous owner's memory.

- [ ] **Step 3: Implement, then verify.**

---

## Task 3: Notice when someone copies

**Files:**
- Create: `windows/src/Hypo.Windows/Clipboard/ClipboardListener.cs`
- Create: `windows/tests/Hypo.Windows.Tests/ClipboardListenerTests.cs`

`AddClipboardFormatListener` on a message-only window (`HWND_MESSAGE`), pumping
`WM_CLIPBOARDUPDATE`. Not the old `SetClipboardViewer` chain, which breaks
whenever any application in it misbehaves.

- [ ] **Step 1: The echo suppression, which is the whole point**

`IClipboard` promises that a write does not raise `ContentChanged`. Windows
does not offer that: our own `SetClipboardData` raises `WM_CLIPBOARDUPDATE`
exactly like anyone else's.

Suppress by *sequence number*: `GetClipboardSequenceNumber` before and after our
own write, and ignore an update carrying a sequence we caused. Do not suppress
by comparing content — a peer may legitimately send the same content again a
moment later, and a content-based filter would swallow it.

- [ ] **Step 2: Tests**

1. An external write raises exactly one `ContentChanged`.
2. **A write through our own `SetAsync` raises none.** This is the loop test;
   write it first.
3. Ten rapid external writes do not deadlock the pump, and the last one is
   reported. A message loop that stops draining is a hang, not a failure, so
   give this test a timeout and let it fail loudly.
4. Disposing stops the listener and removes the format listener — a leaked
   message-only window keeps the process alive.

- [ ] **Step 3: Implement, then verify.**

---

## Task 4: A client you can actually run

**Files:**
- Create: `windows/src/Hypo.Windows/Program.cs`
- Modify: `.github/workflows/ci.yml`

A console program: discover, pair, then sync over both transports using
`SyncCoordinator`. Everything it needs already exists.

- [ ] **Step 1: Wire it up**

`MdnsPeerDiscovery` + `LanWebSocketServer`/`Client` + `CloudWebSocketClient`
behind `DualSyncTransport`, `WindowsClipboard` for `IClipboard`,
`FileSecretStore` for keys under `%LOCALAPPDATA%\Hypo`, and
`ClipboardHistoryStore` beside it.

- [ ] **Step 2: Make CI publish it**

Add a step that publishes a self-contained x64 build and uploads it as an
artifact, so a Windows machine can run it without a toolchain. This is the step
that turns "CI says it compiles" into "you can download it and try it".

- [ ] **Step 3: Verify** — the job is green and the artifact exists.

---

## Task 5: The honest limits

- [ ] **Step 1: Write down what remains unverified**

Add a section to this plan listing what no test here establishes: that the
client works on a logged-in interactive desktop, that clipboard ownership
behaves the same when a real user is switching applications, and that
performance is acceptable with a real clipboard manager installed.

Say it plainly rather than letting a green CI badge imply more than it means.
The next plan, or a person with a Windows machine, closes these.
