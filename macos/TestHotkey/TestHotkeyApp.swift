import SwiftUI
import AppKit
import Carbon
import ApplicationServices

// Minimal test app to verify Carbon hotkey registration
class TestAppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private static var eventHandlerInstalled = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 [TestAppDelegate] applicationDidFinishLaunching called")
        print("🚀 [TestAppDelegate] applicationDidFinishLaunching called")
        
        checkAccessibilityPermissions()
        setupCarbonHotkey()
    }
    
    func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        let msg = isTrusted ? "✅ Accessibility: GRANTED" : "⚠️ Accessibility: NOT GRANTED"
        NSLog(msg)
        print(msg)
    }
    
    func setupCarbonHotkey() {
        NSLog("🔧 [TestAppDelegate] setupCarbonHotkey() called")
        print("🔧 [TestAppDelegate] setupCarbonHotkey() called")
        
        // Install event handler once
        if !Self.eventHandlerInstalled {
            var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            
            let handlerProc: EventHandlerProcPtr = { (nextHandler, theEvent, userData) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                if err == noErr && hotKeyID.id == 1 {
                    let msg = "🎯 HOTKEY TRIGGERED: Shift+Cmd+V"
                    NSLog(msg)
                    print(msg)
                    
                    // Show alert to prove it works
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Hotkey Works!"
                        alert.informativeText = "Shift+Cmd+V was pressed successfully!"
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
                return noErr
            }
            
            // Use modern Carbon API - InstallEventHandler with function pointer
            var eventHandler: EventHandlerRef?
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                handlerProc,
                1,
                &eventSpec,
                nil,
                &eventHandler
            )
            
            if installStatus == noErr {
                Self.eventHandlerInstalled = true
                NSLog("✅ Event handler installed")
                print("✅ Event handler installed")
            } else {
                NSLog("❌ Failed to install event handler: \(installStatus)")
                print("❌ Failed to install event handler: \(installStatus)")
                return
            }
        }
        
        // Register hotkey: Shift+Cmd+V (keyCode 9 = 'V')
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x54455354) // "TEST" signature
        hotKeyID.id = 1
        
        var hotKeyRef: EventHotKeyRef?
        let keyCode = UInt32(9) // 'V' key
        let modifiers = UInt32(cmdKey | shiftKey) // Cmd+Shift
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr, let hotKey = hotKeyRef {
            self.hotKeyRef = hotKey
            let msg = "✅ Hotkey registered: Shift+Cmd+V (keyCode: \(keyCode), status: \(status))"
            NSLog(msg)
            print(msg)
        } else {
            let msg = "❌ Failed to register hotkey: status=\(status), hotKeyRef=\(hotKeyRef != nil)"
            NSLog(msg)
            print(msg)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
        }
    }
}

@main
struct TestHotkeyApp: App {
    @NSApplicationDelegateAdaptor(TestAppDelegate.self) var appDelegate
    
    var body: some Scene {
        MenuBarExtra("🔑", systemImage: "keyboard") {
            VStack(spacing: 20) {
                Text("Hotkey Test App")
                    .font(.headline)
                Text("Press Shift+Cmd+V")
                    .font(.subheadline)
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
            .frame(width: 200, height: 150)
        }
    }
}

