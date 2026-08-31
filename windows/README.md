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
| Light and dark, following the system setting | Done |
| Version in the tray menu | Done |
| Oversized images compressed before sending | Done |
| Installer (MSIX, winget) | Not planned — distributed as a zip |
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
second machine.

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

- **Clipboard history…** — search, and double-click an entry to put it back;
  focus returns to whatever you were in, so the next paste lands there.
  **Alt+V** opens it from anywhere, and the menu item shows the combination
- **Pair a device…** — devices on this network, or a six-digit code for one
  that is not
- **Pause syncing** — distinct from being disconnected, and the icon says which
- Two sharing switches, **both off by default**

Those two decide how far a synced item travels once it reaches this machine.
Windows shares clipboard content in two directions that have nothing to do with
Hypo: the local Win+V history, and the cloud clipboard that roams to a Microsoft
account and every machine signed into it. By default Hypo opts out of both by
publishing the marker formats Windows looks for.

### Divergences from the design

Two, both deliberate:

- The history window is 520×620 and the pairing window 460×560, not the 360×480
  the design took from macOS. The
  Windows list shows a content type and a source device under every entry, which
  360 points cannot hold without trimming the entry itself.
- The theme is seven brushes rather than the WPF-UI Fluent dictionary, which
  would have restyled every control in the screenshot suite to get them.

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

The design named the WPF-UI Fluent dictionary for this. It is not used: the
whole theme is seven brushes, and a UI toolkit would have restyled every control
in the screenshots for them.

### The shortcut

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
