import HypoApp
import Foundation

#if canImport(AppKit)
import AppKit
#endif

// The SwiftUI @main entry point lives in HypoMenuBarApp when building for macOS.
// This executable target allows command-line bootstrapping and diagnostics when running from tests.
@main
struct HypoCommandApp {
    static func main() {
        #if os(macOS)
        HypoMenuBarApp.main()
        #else
        print("Hypo executable is only supported on macOS.")
        #endif
    }
}
