#if canImport(UIKit)
import SwiftUI

@main
struct ClipboardiOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSClipboardHostView()
        }
    }
}
#endif
