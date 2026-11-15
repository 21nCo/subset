import AppKit
import SubsetCore
import SwiftUI

/// The Subset manager: a menu bar item whose menu opens the main window. There is no Dock icon (LSUIElement in
/// Info.plist), so the menu is how the window is opened and reopened after it is closed. The window is empty until
/// listing (SET-246) and installing (SET-247) fill it.
@main
struct SubsetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item is the first scene, so launching the app shows only the item; the window waits for Open
        // Subset.
        MenuBarExtra(SubsetIdentity.appName, systemImage: SubsetIdentity.menuBarSymbol) {
            SubsetMenu()
        }
        .menuBarExtraStyle(.menu)

        Window(SubsetIdentity.appName, id: SubsetIdentity.mainWindowID) {
            MainWindowView()
        }
        .defaultSize(width: 720, height: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_: Notification) {
        // Info.plist sets LSUIElement for the bundled app; the SwiftPM executable has no Info.plist, so set the policy
        // here too and both stay out of the Dock.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The menu bar item's menu, built from `MenuCommand` so the menu and its tests share one list.
struct SubsetMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(MenuCommand.allCases, id: \.self) { command in
            if command.startsGroup { Divider() }
            commandButton(command)
        }
    }

    @ViewBuilder
    private func commandButton(_ command: MenuCommand) -> some View {
        let button = Button(command.title) { perform(command) }
        if let key = command.keyEquivalent {
            button.keyboardShortcut(KeyEquivalent(key))
        } else {
            button
        }
    }

    private func perform(_ command: MenuCommand) {
        switch command {
        case .openSubset:
            openWindow(id: SubsetIdentity.mainWindowID)
            // An accessory app is not active until asked; activate so the window comes to the front with focus.
            NSApp.activate()
        case .about:
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
