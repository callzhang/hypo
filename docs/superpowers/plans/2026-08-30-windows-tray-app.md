# Windows Client — Plan 7: The Tray Application

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Something a person runs and forgets about — a tray icon, a history
window, and pairing without a terminal.

Sync itself is done: text, links, images and files move in both directions over
the LAN and the relay. What is missing is every way of using it that is not a
console.

## The constraint that shapes this plan

There is no Windows machine here. CI has one, with a real clipboard, and it can
run anything headless — but it cannot tell you whether a window looks right, a
tray menu opens, or a hotkey feels responsive.

So the split is deliberate and load-bearing: **everything that can be decided
without pixels lives in `Hypo.Windows` and is tested; the WPF project is a shell
that binds to it and does nothing else.** A view model that filters history, a
rule that turns transport state into an icon and a tooltip, a command that
copies an entry back — none of that needs a window, and all of it is where the
bugs are.

If logic leaks into code-behind it becomes unverifiable, and on this project
unverifiable means unverified.

---

## Task 1: What the tray icon says

**Files:**
- Create: `windows/src/Hypo.Windows/App/TrayStatus.cs`
- Create: `windows/tests/Hypo.Windows.Tests/TrayStatusTests.cs`

- [ ] **Step 1: Tests first**

The icon and tooltip are a pure function of connection state and peer count.

1. Nothing connected reads as offline, and says so — not a cheerful default.
2. LAN only, relay only, and both are distinguishable. A user whose relay is
   down should be able to see that without opening anything.
3. The tooltip names the peers it can reach, truncated sensibly for many.
4. Paused is distinct from disconnected. "I turned it off" and "it broke" must
   not look the same.

- [ ] **Step 2: Implement, then verify** — `cd windows && dotnet test`.

---

## Task 2: The history, as a view model

**Files:**
- Create: `windows/src/Hypo.Windows/App/HistoryViewModel.cs`
- Create: `windows/tests/Hypo.Windows.Tests/HistoryViewModelTests.cs`

- [ ] **Step 1: Tests**

1. Entries come back newest first, with a preview suited to the content type —
   text inline, an image described by size, a file by name.
2. Filtering is case-insensitive substring over text, and matches a file's name.
   A filter that only searched raw bytes would never match an image or file.
3. Choosing an entry puts it back on the clipboard, and that must not be
   re-published as a local copy — otherwise picking an old item resends it to
   every peer. `IClipboard` already promises this; the test pins that the view
   model relies on it rather than reimplementing it.
4. Refresh after an item arrives shows it without a restart.
5. An empty history is a state, not an error.

- [ ] **Step 2: Implement, then verify.**

---

## Task 3: Pairing without a terminal

**Files:**
- Create: `windows/src/Hypo.Windows/App/PairingViewModel.cs`
- Create: `windows/tests/Hypo.Windows.Tests/PairingViewModelTests.cs`

- [ ] **Step 1: Tests**

1. Discovered peers appear, and an already-paired one is marked rather than
   offered again.
2. Pairing reports each outcome from `LanPairingCoordinator` in words a person
   can act on. "No reply" and "the ack did not verify" mean different things and
   must not both read as "failed".
3. Pairing succeeds → the peer becomes a sync target without a restart.
4. The device's own advertisement is never offered as a peer.

- [ ] **Step 2: Implement, then verify.**

---

## Task 4: The shell

**Files:**
- Create: `windows/src/Hypo.Windows.App/` (WPF, `net10.0-windows`)
- Modify: `windows/Hypo.sln`, `.github/workflows/ci.yml`

- [ ] **Step 1: Build it**

A tray icon with a menu (history, pair, pause, quit), a history window bound to
Task 2, and a pairing window bound to Task 3. `EnableWindowsTargeting` so it
compiles on any machine; the code-behind wires and nothing more.

- [ ] **Step 2: Single instance**

Two copies both listening on the LAN port and both writing the clipboard is a
fight the user watches. A named mutex; the second instance surfaces the first's
window and exits.

- [ ] **Step 3: CI publishes it**

Alongside the console build, so there is something to download and try.

- [ ] **Step 4: Verify** — CI green, both artifacts present.

---

## Task 5: Say what is still unverified

- [ ] Add an outcome section listing what no test here establishes: that the
      tray icon appears, that the menu opens, that the window is legible, that
      the hotkey works. A green badge means the logic is right, not that the
      application is usable. Only a person on Windows closes that.
