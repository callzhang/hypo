# Hotkey Test App

Minimal reproducible example to test Carbon hotkey registration.

## Build and Run

```bash
cd macos/TestHotkey
swift build
./.build/debug/TestHotkey
```

## What to Test

1. **Launch the app** - You should see a 🔑 icon in the menu bar
2. **Check Console.app** - Filter for "TestAppDelegate" to see:
   - `🚀 [TestAppDelegate] applicationDidFinishLaunching called`
   - `✅ Hotkey registered: Shift+Cmd+V`
3. **Press Shift+Cmd+V** - You should see:
   - `🎯 HOTKEY TRIGGERED: Shift+Cmd+V` in logs
   - An alert dialog saying "Hotkey Works!"

## Watch Logs in Real-Time

```bash
log stream --predicate 'process == "TestHotkey"' --level debug
```

## Expected Behavior

- ✅ App launches and shows menu bar icon
- ✅ AppDelegate logs appear in Console
- ✅ Hotkey registration succeeds
- ✅ Pressing Shift+Cmd+V shows alert

## If It Doesn't Work

1. **Check Accessibility Permissions**
   - System Settings > Privacy & Security > Accessibility
   - Make sure the app is enabled

2. **Check App Sandbox**
   - If using Xcode, disable App Sandbox in Signing & Capabilities
   - Sandboxed apps cannot register global hotkeys

3. **Check Console Logs**
   - Look for error messages about hotkey registration
   - Check if `RegisterEventHotKey` returns an error code


