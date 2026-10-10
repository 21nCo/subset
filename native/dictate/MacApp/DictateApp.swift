import SwiftUI

@main
struct DictateApp: App {
    static let mainWindowID = "main"

    @StateObject private var appController = DictationAppController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Window("Dictate", id: Self.mainWindowID) {
            MacRootView()
                .environmentObject(appController.manager)
        }
        .windowResizability(.contentSize)

        // The app has no Dock icon, so the menu bar item is how the window is reopened after it is closed.
        MenuBarExtra {
            DictateMenu()
                .environmentObject(appController.manager)
        } label: {
            DictateMenuBarLabel()
                .environmentObject(appController.manager)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct DictateMenuBarLabel: View {
    @EnvironmentObject private var manager: DictationManager

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(manager.menuBarStateDescription)
    }

    private var symbolName: String {
        if manager.isFinalizing { return "ellipsis.circle" }
        return manager.transcriptState.isRecording ? "mic.fill" : "mic"
    }
}

private struct DictateMenu: View {
    @EnvironmentObject private var manager: DictationManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(manager.menuBarStateDescription)

        Divider()

        Button(manager.transcriptState.isRecording ? "Stop Dictation" : "Start Dictation") {
            manager.toggleDictationFromUI()
        }
        .disabled(manager.isFinalizing)

        Button("Copy Last Transcript") {
            manager.copyLastTranscript()
        }
        .disabled(manager.lastTranscript.isEmpty)

        Divider()

        Button("Open Dictate…") {
            openWindow(id: DictateApp.mainWindowID)
            NSApp.activate()
        }

        Divider()

        Button("Quit Dictate") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
