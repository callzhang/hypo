import SwiftUI
import HypoiOS

@main
struct HypoApp: App {
    @State private var context = HypoiOSContext()

    var body: some Scene {
        WindowGroup {
            RootView(context: context)
        }
    }
}
