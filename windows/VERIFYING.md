# Verifying Hypo on a real Windows machine

Everything in `windows/` is tested, and CI runs those tests on a
`windows-latest` runner that shows windows, renders them and takes pictures.
None of that is the same as someone using it.

This is the list of things a runner cannot answer, ordered by how likely each
one is to be broken. Work down it; the first few are where the risk is.

## Getting a build

Any green CI run publishes `hypo-app-win-x64` and `hypo-app-win-arm64` as
artifacts. Download, unzip somewhere real — `%LOCALAPPDATA%\Programs\Hypo` —
and run `Hypo.exe`. Not from inside the zip: Windows unpacks it to a temporary
folder that disappears.

ARM64 if this is a Windows VM on an Apple Silicon Mac, or a Copilot+ PC.

SmartScreen will say "Windows protected your PC" the first time. That is
expected for an unsigned zip: **More info → Run anyway**.

## 1. The things most likely to be wrong

These depend on cooperation from other applications, which nothing here can
simulate.

- [ ] **Focus handoff.** Type in Notepad, press <kbd>Alt</kbd>+<kbd>V</kbd>,
      choose an entry with <kbd>Enter</kbd>, then <kbd>Ctrl</kbd>+<kbd>V</kbd>.
      The text must land in Notepad. This is the whole feature: if focus does
      not go back, the history is inert. `SetForegroundWindow` is subject to the
      foreground lock and `ForegroundHandoff` attaches the input queue to get
      around it — that is the part that could fail on a real desktop.
- [ ] The same, from a browser, and from an application started as
      administrator. A elevated window is a different case.
- [ ] **The shortcut against real applications.** Alt+V is not reserved, but
      something you run may hold it. If it does, Hypo should say so in a balloon
      and drop the combination from the menu item rather than failing silently.
      Check Settings says the same thing.
- [ ] **Drag and drop into real targets.** Drag a text entry into Word, an image
      into Paint, a file into an Explorer window. Each uses a different format
      and only the target can tell you it accepted it.

## 2. Windows integration

- [ ] **The firewall prompt** on first launch. Tick **Private networks** — that
      is what LAN discovery needs. Declining should leave it working through the
      relay, more slowly.
- [ ] **Win+V coexistence.** With "Show synced items in Windows clipboard
      history" **off** (the default), copy something on the phone and then press
      <kbd>Win</kbd>+<kbd>V</kbd>. The synced item must **not** be there. Turn
      the setting on and check it now is.
- [ ] **Cloud clipboard.** Same test with a Microsoft account signed in and
      clipboard sync enabled in Windows Settings. This is the one that matters
      most: it is the difference between a password from a phone's password
      manager staying on this machine and roaming to every machine you are
      signed into.
- [ ] **A received file.** Copy a file on another device; it should land in
      `%LOCALAPPDATA%\Hypo\received` and paste into an Explorer window as a
      file, not as a path.
- [ ] **Run at login.** Turn it on in Settings, sign out, sign back in.

## 3. Appearance

- [ ] **Mica** on Windows 11 — the history window should pick up the wallpaper
      behind it. On Windows 10 it should be a flat colour, not transparent and
      not black.
- [ ] **Switch the system theme while Hypo is running.** Both windows should
      follow immediately, including their title bars.
- [ ] **A second monitor at a different scaling.** Drag the history window from
      a 100% display to a 200% one. Nothing here can test that; the DPI tests
      render at a fixed scale on one screen.
- [ ] 125% and 150%, which are what most laptops actually use.

## 4. Over time

- [ ] **Sleep and resume.** The relay connection should come back on its own.
- [ ] **Lock the session for twenty minutes.** The relay's idle timeout is 900
      seconds and the client pings at 840; this is the window where a
      keepalive bug shows.
- [ ] **Leave it running for a day** and copy things throughout. Memory should
      be flat, the history should trim at the limit, and the tray icon should
      still reflect the truth.

## 5. Two devices

- [ ] **Pair over the LAN** with the Mac or the phone, and sync both ways: text,
      a link, an image, a file.
- [ ] **Pair by six-digit code** with a device on a different network, and sync
      both ways again. This exercises the relay path end to end.
- [ ] **Unpair** from Settings and confirm syncing stops in both directions.
- [ ] Watch the row captions: an item that came over the LAN should say so, and
      one that went through the relay should say that instead. If they disagree
      with where the devices actually are, transport selection is wrong.

## What to do with a failure

`windows/README.md` describes what each part is meant to do and why. Two hazards
already caught on Windows and not reproducible on a Mac are written down there —
both about the clipboard sequence number — and are worth reading before
diagnosing anything clipboard-shaped.

The tray menu shows the version. Include it, and the version on the other
device, in anything you write down: the two ends disagreeing is a common enough
cause to rule out first.
