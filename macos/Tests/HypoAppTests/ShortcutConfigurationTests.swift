import Foundation
import Testing
#if canImport(Carbon)
import Carbon
#endif
@testable import HypoApp

struct ShortcutConfigurationTests {
    @Test
    func testKeyboardShortcutRoundTripsThroughDefaultsValue() {
        let shortcut = KeyboardShortcut(keyCode: 13, carbonModifiers: KeyboardShortcut.carbonModifiers(from: [.command, .shift]))

        let restored = KeyboardShortcut(defaultsValue: shortcut.defaultsValue)

        #expect(restored == shortcut)
    }

    @Test
    func testOptionNumberShortcutsAreReservedByHypo() {
        let optionOne = KeyboardShortcut(keyCode: 18, carbonModifiers: UInt32(optionKey))
        let optionV = KeyboardShortcut.defaultShowClipboard

        #expect(optionOne.isReservedByHypo)
        #expect(!optionV.isReservedByHypo)
    }

    @Test
    @MainActor
    func testViewModelLoadsPersistedShowClipboardShortcut() {
        let defaults = UserDefaults(suiteName: "ShortcutConfigurationTests.\(UUID().uuidString)")!
        let persisted = KeyboardShortcut(keyCode: 13, carbonModifiers: KeyboardShortcut.carbonModifiers(from: [.command, .shift]))
        defaults.set(persisted.defaultsValue, forKey: "show_clipboard_shortcut")

        let viewModel = ClipboardHistoryViewModel(
            store: HistoryStore(maxEntries: 10, defaults: defaults),
            defaults: defaults,
            notificationController: nil
        )

        #expect(viewModel.showClipboardShortcut == persisted)
    }

    @Test
    @MainActor
    func testViewModelLoadsClearedShowClipboardShortcut() {
        let defaults = UserDefaults(suiteName: "ShortcutConfigurationTests.Cleared.\(UUID().uuidString)")!
        defaults.set("", forKey: "show_clipboard_shortcut")

        let viewModel = ClipboardHistoryViewModel(
            store: HistoryStore(maxEntries: 10, defaults: defaults),
            defaults: defaults,
            notificationController: nil
        )

        #expect(viewModel.showClipboardShortcut == nil)
    }
}
