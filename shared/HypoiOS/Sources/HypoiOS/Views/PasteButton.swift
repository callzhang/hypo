import SwiftUI
import UIKit

/// The system paste button.
///
/// Tapping it grants this app one-shot access to the pasteboard with no "allow
/// paste?" prompt — the exemption Apple gives for a control the user pressed
/// themselves. Every other way of reading content this app did not write asks
/// permission, so on iOS this is what "send what I copied" has to be built on.
/// Android needs no equivalent: reading in the foreground there is free.
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

    /// Without this SwiftUI hands the control whatever width it proposes and
    /// the button stretches edge to edge.
    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIPasteControl,
        context: Context
    ) -> CGSize? {
        uiView.intrinsicContentSize
    }

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
