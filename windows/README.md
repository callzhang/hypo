# Hypo Windows Client

Clipboard sync between Windows and the macOS and Android clients, over the local
network and through the relay.

**Design:** [`docs/superpowers/specs/2026-08-28-windows-client-design.md`](../docs/superpowers/specs/2026-08-28-windows-client-design.md)

## Status

Working: text, links, images and files sync in both directions, over the LAN and
the relay. There is no graphical interface yet — the client is a console
program.

| Layer | State |
|-------|-------|
| Protocol, crypto, compression, framing | Done |
| mDNS discovery and LAN pairing | Done |
| LAN transport (listens, advertises, dials) | Done |
| Relay transport, keepalive, reconnect | Done |
| Clipboard history (SQLite) and content dedup | Done |
| Windows clipboard: text, links, images, files | Done |
| Tray icon, history window, settings | Not started |
| MSIX packaging and winget | Not started |

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

```bash
cd windows && dotnet run --project src/Hypo.Windows -- discover
```

`discover` lists peers on the network, `pair <device-id>` pairs with one, and
`run` syncs. State lives in `%LOCALAPPDATA%\Hypo`: keys, this device's id, and
`history.db`.

## Layout

- `src/Hypo.Core` — protocol, crypto, discovery, pairing, both transports,
  history, and the sync coordinator. `net10.0`, no Windows APIs. Keep it that
  way: it is what lets the protocol be verified against real devices from a Mac.
- `src/Hypo.Windows` — `net10.0-windows`. The Win32 clipboard and the console
  entry point, and nothing else.
- `tools/Hypo.Harness` — a console tool for driving discovery, pairing and sync
  against real peers. Its `sync` command builds the same `HypoClient` the
  application does, which is how that composition gets exercised off Windows.
- `tests/Hypo.Core.Tests`, `tests/Hypo.Windows.Tests`.

Note that `net10.0-windows` does not stop code running elsewhere —
`SupportedOSPlatform` is an analyser annotation, not a runtime gate — so
Windows-only tests skip explicitly.
