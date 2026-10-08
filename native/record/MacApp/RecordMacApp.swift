import SwiftUI

@main
struct RecordMacApp: App {
    @StateObject private var recorder = RecordingManager()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environmentObject(recorder)
        }
    }
}
