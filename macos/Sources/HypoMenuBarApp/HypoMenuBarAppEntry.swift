#if os(macOS)
import SwiftUI
import HypoApp

// The actual app implementation is in HypoApp library
// We just need to instantiate it here with @main
@main
enum MainApp {
    static func main() {
        HypoMenuBarApp.main()
    }
}

#else
@main
struct HypoMenuBarAppStub {
    static func main() {
        fatalError("HypoMenuBarApp is only available on macOS.")
    }
}
#endif
