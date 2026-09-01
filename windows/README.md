# Hypo Windows Client

Clipboard sync between Windows and the macOS and Android clients, over the local
network and through the relay.

**Design:** [`docs/superpowers/specs/2026-08-28-windows-client-design.md`](../docs/superpowers/specs/2026-08-28-windows-client-design.md)

## Status

Working: text, links, images and files sync in both directions, over the LAN and
the relay, from a notification-area application.

| Layer | State |
|-------|-------|
| Protocol, crypto, compression, framing | Done |
| mDNS discovery and LAN pairing | Done |
| LAN transport (listens, advertises, dials) | Done |
| Relay transport, keepalive, reconnect | Done |
| Clipboard history (SQLite) and content dedup | Done |
| Windows clipboard: text, links, images, files | Done |
| Tray icon, history window, pairing window | Done |
| Clipboard sharing settings (both default off) | Done |
| Remote pairing by six-digit code | Done |
| Global shortcut (Alt+V), reconfigurable | Done |
| History usable from the keyboard alone | Done |
| Type and date filters, pinning, per-row detail | Done |
| Drag an entry into another application | Done |
| Transport settings: LAN, relay, port | Done |
| Light and dark, following the system setting | Done |
| Version in the tray menu | Done |
| Settings window: devices, history, startup | Done |
| Notification when something arrives | Done |
| Oversized images compressed before sending | Done |
| Installer (MSIX, winget) | Not planned — distributed as a zip |
| Explorer "Copy to Hypo" menu | Not built — needs the MSIX manifest |
| x64 and ARM64 builds | Done |

A file from a peer is written under `%LOCALAPPDATA%\Hypo\received` and its path
put on the clipboard as `CF_HDROP`, so pasting it into Explorer works. Existing
files are never overwritten — a peer resending `report.pdf` gets a timestamped
name rather than replacing one the user may not have opened. The peer-supplied
name is reduced to a leaf and stripped of characters Windows forbids before
anything is created; `..\..\autorun.inf` becomes a filename, not a traversal.

The protocol carries one file per message, so a multi-file selection sends the
first. Content types this client cannot place on the clipboard are kept in the
history and reported rather than lost.

## What is verified, and how

Everything except the Windows clipboard itself is cross-platform .NET and is
tested against real devices from any machine. The Win32 layer is tested on a
`windows-latest` runner in CI, which has a real clipboard: reads, writes,
ownership, the message loop, and the echo suppression all run there.

CI publishes `hypo-console-win-x64`, a self-contained build. Nothing here can
tell you how the client behaves on a logged-in interactive desktop, alongside a
real clipboard manager, or over hours — download that artifact and use it.

**The interface is tested, and CI takes pictures of it.** That was written off
for several plans on the assumption that a runner has no interactive desktop.
It does: `windows-latest` shows windows, renders them, creates a
notification-area icon and captures the screen. The Win32 clipboard tests
passing there had been evidence against the assumption the whole time, and
nobody checked.

So the history and pairing windows are opened for real, asserted on through
their controls, and captured. Every green build publishes
`hypo-ui-screenshots` — download it to see the interface without a Windows
machine. Two defects surfaced within minutes of looking at the first set: the
search box had no label, and an already-paired device looked identical to a new
one.

Display scaling is covered too: the history window is captured at 100%, 150%
and 200%, which catches a layout that only holds together at 100% without a
second machine. Both themes are captured as well, and the colours are checked
for contrast rather than looked at.

The shortcut is tested by pressing it: the test synthesises Ctrl+Alt+Shift+F7
with `SendInput` and waits for the event, because a registration that succeeds
is a weaker claim than a key that works. Registering the same combination twice
and disposing between the two are tested for the same reason — a shortcut that
leaks stays claimed for the session and the next launch cannot have it.

One caution about reading these pictures. Some controls are hidden on purpose:
the six-digit code row is not shown when the view model cannot pair by code, and
a window that is correctly not showing a row it has no use for looks exactly
like a window whose bottom fell off. The test that measures the code row builds
a model that can pair by code, and asserts the control is visible before asking
where it was painted.

`Hypo.Core` — the protocol, the crypto and the transports — is measured on every
run and CI fails below 80%. It sits around 89%. The number is there to notice a
fall, not to celebrate a rise.

Two things guard the shared fixtures, and they answer different questions.
`scripts/check-shared-fixtures.sh` runs on every build and asks whether each
client still reads them — that is the failure nothing else can catch, because a
client that *disagrees* fails its own suite while a client that quietly stopped
reading them stays green.

`scripts/test-sync-matrix.sh` runs the tests that read the shared fixtures under
`tests/` in all three clients: Swift, Kotlin and .NET each encode a frame,
derive a key and decompress a payload from the same bytes. That is the mechanism
stopping three independent implementations from drifting, and a client that
quietly stopped reading them would look exactly like a client that agrees. What
the script cannot do is put a real clipboard on one device and watch it appear
on another; that needs two machines and a person.

What is still open is what a runner cannot be: a second monitor, a session lock,
and a person's judgement about whether any of it is pleasant to use.

Two defects found by Windows CI that a Mac cannot reproduce are worth knowing
about if you touch this code:

- Recording our own clipboard sequence number from a caller's thread races the
  update that write causes, and the echo escapes. All clipboard calls run on the
  message-pump thread for that reason.
- The sequence number advances when the change is committed at
  `CloseClipboard`, so reading it inside the open session returns the value from
  *before* our own write, and the echo suppression silently does nothing.

## Requirements

- .NET 10 SDK
- Windows 10 22H2 (build 19045) or later to run it. `Hypo.Core` builds and tests
  on any platform the SDK supports, which is what keeps the protocol layer
  verifiable without a Windows machine.
- A relay secret in `HYPO_RELAY_AUTH_TOKEN`, or a repo-root `.env` defining
  `RELAY_WS_AUTH_TOKEN`, for cloud sync. LAN sync needs neither.

## Build and test

```bash
cd windows && dotnet test
```

On a non-Windows machine the Win32 tests skip rather than fail, so this command
is green everywhere; CI runs the skipped ones.

That has a sharp edge worth knowing about: **a Windows-only test can go stale
without anything here noticing.** Implementing file support turned an assertion
that files were refused into a lie, and the local run stayed green because that
test skips. After changing what the Windows clipboard accepts, read
`tests/Hypo.Windows.Tests` for assertions that the change has invalidated — the
local suite cannot tell you.

## Run

Download `hypo-app-win-x64` (or `hypo-app-win-arm64`) from any green CI run and
launch `Hypo.exe`. Releases carry both as
`Hypo-<version>-windows-x64.zip` and `-arm64.zip`.

ARM64 matters more than it sounds: a Windows VM on an Apple Silicon Mac is
ARM64, and so is every Copilot+ PC. The x64 build runs there under emulation;
the ARM64 one does not have to. It puts
an icon in the notification area:

- **Clipboard history…** — or one left click on the icon. Search, filter by type
  or date, pin what you want kept at the top, and double-click an entry to put
  it back;
  focus returns to whatever you were in, so the next paste lands there.
  **Alt+V** opens it from anywhere, and the menu item shows the combination
- **Pair a device…** — devices on this network, or a six-digit code for one
  that is not
- **Settings…** — the paired devices with their names and whether each is on
  this network, unpairing, how many entries the history keeps, clearing it,
  whether Hypo starts when you sign in, and what the shortcut is or why it is
  not working
- **Pause syncing** — distinct from being disconnected, and the icon says which
- Two sharing switches, **both off by default**

Those two decide how far a synced item travels once it reaches this machine.
Windows shares clipboard content in two directions that have nothing to do with
Hypo: the local Win+V history, and the cloud clipboard that roams to a Microsoft
account and every machine signed into it. By default Hypo opts out of both by
publishing the marker formats Windows looks for.

### Divergences from the design

All deliberate:

- The history window is 520×620, not the 360×480 the design took from macOS. The
  Windows list shows a content type, a source device and a transport under every
  entry, which 360 points cannot hold without trimming the entry itself.
- The theme is seven brushes rather than the WPF-UI Fluent dictionary, which
  would have restyled every control in the screenshot suite to get them.
- Notifications are notification-area balloons, not the Windows App SDK's
  `AppNotificationManager` the design named. That one requires the application
  to be packaged, and Hypo ships as a zip. A balloon is a real toast on Windows
  10 and 11.
- The Explorer "Copy to Hypo" context menu is not built. It is declared through
  the MSIX manifest, and there is no MSIX; the classic `shellex` alternative is
  what the design's own open items flag as unconfirmed on the Windows 10 floor.

### Light and dark

Hypo follows the Windows app theme (`AppsUseLightTheme`), switches with it while
running, and gives Windows 11 a Mica backdrop and a dark title bar through
`DwmSetWindowAttribute`. Windows 10 has no Mica; asking for it there is not an
error, it simply does nothing, so the solid-colour fallback is chosen explicitly
rather than being whatever the window happened to look like.

The palettes are in `ThemePalette`, not in XAML, so which colours follow from
the setting and which backdrop follows from the Windows version can both be
tested on a Mac. Their contrast is tested too, which is how the light theme's
search hint turned out to be at 2.67:1 — it is darker now.

Three controls have been left out of it so far — Button, Separator and ComboBox
— and each time a pale slab or a near-white line survived every test until a
person looked at a screenshot. There is a test for that class of mistake now: it
renders both windows dark and fails if any block of light chrome is left,
distinguishing a control's background from white text by asking for a run wide
enough to be a control repeated over enough rows to be its height.

Two of the three needed only a `Background` setter. **ComboBox needed a whole
`ControlTemplate`**: its default template paints its own chrome and ignores
`Background`, so it stayed pale after being "themed" — and the pixel test caught
that on its first run, which is the only reason it is not still pale. The
template covers what the two filter drop-downs need and nothing else; a template
carrying states nothing uses is a template nobody can check.

The design named the WPF-UI Fluent dictionary for this. It is not used: the
whole theme is seven brushes, and a UI toolkit would have restyled every control
in the screenshots for them.

### Transports

Either channel can be switched off, and the LAN port changed. All three are read
when the client is built and cannot be changed without starting again, which the
window says rather than pretending otherwise — the alternative is tearing down
and rebuilding both transports underneath a running application.

Turning the LAN off stops this machine advertising its name and address on the
network, which is usually the point of asking. Turning both off leaves an
application that keeps a history and syncs with nobody; that is a choice someone
is entitled to make, and the window says what it means rather than leaving it to
be worked out from the icon. Port 0 asks Windows for a free one, which is the
answer when something else already holds 7010; below 1024 is refused because
those need administrator rights and the bind would simply fail.

### Settings

Everything with a decision in it is in `SettingsViewModel` and tested on any
machine; the window is controls bound to it.

Unpairing takes the shared key **and** the remembered name. The key is what
matters — without it nothing from that device decrypts and nothing goes to it —
but a name left behind would keep an unpaired device in every list. It asks
first, because from here it cannot be undone: the two devices have to be
introduced to each other again.

Lowering the retention limit prunes immediately, and the window says how many
entries went. Clearing runs `VACUUM` as well as `DELETE`; a history file that
still holds the rows in its free pages has not done what was asked.

"Start Hypo when I sign in" writes the per-user `Run` key — never the
machine-wide one, which would start it for people who never installed it and
would need an administrator. Group policy can lock that key, so the switch shows
what the registry says afterwards rather than what was asked for.

The two sharing switches and the notification switch appear both here and in the
tray menu. They are written by one piece of code either way, and changing one in
the menu updates an open settings window — two paths writing one setting is how
a menu ends up disagreeing with a window in front of someone.

### Dragging

An entry can be dragged straight into another application, which puts it there
without disturbing the clipboard — worth having when what is on the clipboard
right now is the thing you want to keep. Text goes as text, images as PNG, and a
file's bytes are written to `%TEMP%\Hypo` first, because a drop target receives
a path and not bytes. Dragged files go there rather than to the received-files
folder: a copy made for a drop is not something a peer sent.

### Arrivals

Something copied on another device reaches this machine silently otherwise —
the only way to find out is to paste and see. A notification says which device
it came from and shows the first 80 characters. Locally copied items never
notify.

Eighty, not the 255 a balloon would take: enough to recognise what arrived, not
enough to read a password over someone's shoulder. Turn it off from the tray
menu; it is the only one of the three switches that starts on, because it
shares nothing beyond the screen already in front of you.

### The shortcut

Alt+V opens the history with the caret already in the search box: type to
narrow, ↑ and ↓ to choose without leaving the box, Enter to put the entry back
and return focus to whatever you were in, Escape to leave with nothing. Clicking
away closes it, and it stays out of Alt+Tab — it is a list a keystroke summons,
not a window to switch to.

Alt+V, because Win+V belongs to the Windows clipboard history and cannot be
taken. Change it with a `"Hotkey": "Ctrl+Alt+H"` line in `settings.json`; the
spellings `Ctrl`/`Control` and `Win`/`Windows` are all understood, case does not
matter, and a value that makes no sense falls back to Alt+V rather than stopping
the application.

If another application already holds the combination, Windows refuses it. Hypo
says so in a notification and drops the combination from the menu item, so the
menu never advertises a shortcut that will not fire — a shortcut that silently
does nothing is indistinguishable from a broken application.

They are off because Hypo carries whatever was copied on another device, and a
password from a phone's password manager silently roaming to a Microsoft account
is worse than the convenience is good. Turning either on is one click; turning it
off afterwards does not un-upload anything. The settings live in
`%LOCALAPPDATA%\Hypo\settings.json`, and a corrupt file falls back to both
being off — the only failure here that would matter is one that widens sharing
without being asked.

The icon is a coloured dot: green when a device is reachable on this network,
amber when only the relay is, red when nothing is, grey when paused.

There is no installer, by choice. Signing an MSIX needs a code-signing
certificate whose private key must live on FIPS 140-2 hardware — since June 2023
a CA cannot hand you a `.pfx` — which means either an OSS signing programme, a
subscription service, or a USB token, and none of that buys anything a zip does
not. Windows Defender SmartScreen will still warn on first run either way until
a signature builds reputation.

The MSIX manifest and packing script were written and then removed; `git log`
has them if winget ever becomes worth the certificate.

There is also a console client, which is what CI tests against and what to reach
for when something is wrong:

```bash
cd windows && dotnet run --project src/Hypo.Windows -- discover
```

`discover` lists peers, `pair <device-id>` pairs with one, `run` syncs.

For a device that is not on this network — a phone on cellular, a laptop
somewhere else — `code` shows a six-digit code and `enter <code>` uses one. The
LAN path is better when it is available: no third party and nothing to carry
between the two devices. This is the fallback, not the front door.

State lives in `%LOCALAPPDATA%\Hypo`: keys, this device's id, `history.db`, and
`received\` for files that arrive from a peer.

## Layout

- `src/Hypo.Core` — protocol, crypto, discovery, pairing, both transports,
  history, and the sync coordinator. `net10.0`, no Windows APIs. Keep it that
  way: it is what lets the protocol be verified against real devices from a Mac.
- `src/Hypo.Windows` — `net10.0-windows`, no WPF. The Win32 clipboard, the
  console entry point, and the application's presentation logic (`App/`), which
  lives here precisely so it can be tested.
- `src/Hypo.Windows.App` — the WPF shell: tray icon, two windows, wiring. Keep
  logic out of it; it is the only code here nothing can verify.
- `tools/Hypo.Harness` — a console tool for driving discovery, pairing and sync
  against real peers. Its `sync` command builds the same `HypoClient` the
  application does, which is how that composition gets exercised off Windows.
- `tests/Hypo.Core.Tests`, `tests/Hypo.Windows.Tests`.

Note that `net10.0-windows` does not stop code running elsewhere —
`SupportedOSPlatform` is an analyser annotation, not a runtime gate — so
Windows-only tests skip explicitly.
