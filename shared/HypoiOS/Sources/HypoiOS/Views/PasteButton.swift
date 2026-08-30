import SwiftUI
import UIKit

/// The system paste button.
///
/// Tapping it grants this app one-shot access to the pasteboard without the
/// "allow paste?" prompt that a programmatic read triggers on iOS 16 and later.
/// It is the only way to read the clipboard on iOS without interrupting the
/// user, which is why sending is driven from here rather than from a poll.
public struct PasteButton: UIViewRepresentable {
    private let onPaste: @MainActor @Sendable (String) -> Void

    public init(onPaste: @escaping @MainActor @Sendable (String) -> Void) {
        self.onPaste = onPaste
    }

    public func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .labelOnly
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        return control
    }

    public func updateUIView(_ uiView: UIPasteControl, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    /// A UIResponder, not an NSObject: both `pasteConfiguration` and
    /// `paste(itemProviders:)` come from UIResponder, and UIPasteControl's
    /// target has to be one.
    public final class Coordinator: UIResponder {
        private let onPaste: @MainActor @Sendable (String) -> Void

        init(onPaste: @escaping @MainActor @Sendable (String) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        public override func paste(itemProviders: [NSItemProvider]) {
            for provider in itemProviders {
                _ = provider.loadObject(ofClass: NSString.self) { [onPaste] object, _ in
                    guard let string = object as? String else { return }
                    Task { @MainActor in onPaste(string) }
                }
            }
        }
    }
}
