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
| MSIX packaging | Packs unsigned; signing needs a certificate |
| winget | Not started — needs a signed package first |

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

**The tray application is the one part no test covers.** Its logic — what the
icon means, how history filters, what a pairing failure says — lives in
`Hypo.Windows` and is tested; the WPF project binds to that and does nothing
else, which is why the split exists. But whether the icon appears, the menu
opens, the window is legible or the app survives a display change is not
established by anything here. Only running it is.

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

Download `hypo-app-win-x64` from any green CI run and launch `Hypo.exe`. It puts
an icon in the notification area:

- **Clipboard history…** — search, and double-click an entry to put it back
- **Pair a device…** — devices running Hypo on this network
- **Pause syncing** — distinct from being disconnected, and the icon says which

The icon is a coloured dot: green when a device is reachable on this network,
amber when only the relay is, red when nothing is, grey when paused.

CI also packs an unsigned MSIX (`hypo-msix-unsigned-win-x64`). Windows will not
install it as it stands — see [`packaging/README.md`](packaging/README.md) for
signing, which is the step that is genuinely blocked on having a certificate.

There is also a console client, which is what CI tests against and what to reach
for when something is wrong:

```bash
cd windows && dotnet run --project src/Hypo.Windows -- discover
```

`discover` lists peers, `pair <device-id>` pairs with one, `run` syncs.

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
