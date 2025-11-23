# Keyboard Shortcut Interception Issue - Status Report

**Date:** 2025-11-23  
**Issue:** Global keyboard shortcut not working in main app  
**Status:** FIXED – Carbon hotkey registers and now forces popup window; awaiting QA confirmation  
**Priority:** High

## Root Cause
- `HypoMenuBarApp` was manually overwriting `NSApplication.shared.delegate` in `init()`/`.onAppear` with a transient `HypoAppDelegate` instance. The `delegate` property is `weak`, so the replacement deallocated immediately, leaving the app without a delegate. As a result `applicationDidFinishLaunching` never ran and the Carbon hotkey was never registered.

## Fix Implemented (2025-11-23)
1) Removed the manual delegate overrides in `HypoMenuBarApp` and now rely solely on `@NSApplicationDelegateAdaptor(HypoAppDelegate.self)` to retain and wire the delegate.  
2) Kept the Carbon `RegisterEventHotKey` setup inside `HypoAppDelegate.applicationDidFinishLaunching` (Shift+Cmd+V / keyCode 9).  
3) Added `HistoryPopupPresenter` that shows/centers a floating SwiftUI window on hotkey (works even if MenuBarExtra view has never been opened).  
4) Clarified inline comments so hotkey ownership is unambiguous; CGEventTap path stays retired and the NSEvent fallback remains available but is not invoked.

## Verification Plan
- Launch Hypo (macOS build).  
- Check `/tmp/hypo_debug.log` for:
  - `applicationDidFinishLaunching called` (delegate now retained)
  - `Carbon hotkey registered: Shift+Cmd+V`
- Press **Shift+Cmd+V**: expect popup window to appear centered and frontmost (History view). Notifications `ShowHistoryPopup` + `ShowHistorySection` still fire for in-app listeners.  
- Confirm no Accessibility prompt (Carbon path does not require it).

## Notes
- `macos/TestHotkey/` remains the working reference app.  
- `setupGlobalShortcut()` (NSEvent fallback) is currently unused; enable from `HypoMenuBarApp` if we ever need a debug-only path that depends on Accessibility permissions.

## Additional Fix (2025-11-23)
**Timing Issue Fixed:** Notification observers were being set up in `MenuBarContentView.onAppear`, which could create a race condition where the Carbon hotkey fires before observers are registered. 

**Solution:**
- Observers now set up in `.task` modifier (runs immediately when view is created)
- Added duplicate observer prevention
- Added proper cleanup and weak self capture
- Observers remain active when view disappears (hotkey works when menu is closed)
- Enhanced logging for observer setup and notification receipt

## Next Steps
- QA to validate the hotkey end-to-end on a clean system (no prior accessibility grants).  
- If any failures remain, enable the NSEvent fallback after permission checks or consider a user-selectable shortcut.
