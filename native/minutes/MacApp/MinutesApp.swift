import SwiftUI

@main
struct MinutesApp: App {
    @StateObject private var bot = BotRuntimeController()

    var body: some Scene {
        Window("Minutes", id: "main") {
            ContentView()
                .environmentObject(bot)
                .frame(minWidth: 760, minHeight: 540)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
