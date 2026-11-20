import AppKit
import SubsetCore
import SwiftUI

/// The Subset manager: a menu bar item whose menu opens the main window. There is no Dock icon (LSUIElement in
/// Info.plist), so the menu is how the window is opened and reopened after it is closed. The window lists the catalog's
/// apps (SET-246), installs, updates and moves them to the Trash (SET-247), and shows
/// the `subset` command's status and the installed apps' commands (SET-248).
@main
struct SubsetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item is the first scene, so launching the app shows only the item; the window waits for Open
        // Subset.
        MenuBarExtra(SubsetIdentity.appName, systemImage: SubsetIdentity.menuBarSymbol) {
            SubsetMenu(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Window(SubsetIdentity.appName, id: SubsetIdentity.mainWindowID) {
            MainWindowView(model: appDelegate.model, actions: appDelegate.actions, commandLine: appDelegate.commandLine)
        }
        .defaultSize(width: 720, height: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The catalog and installed apps, shared by the menu and the window.
    let model = AppListModel(loader: CatalogLoader.standard(), finder: InstalledAppFinder.standard())
    /// The rows' Install, Update and Move to Trash buttons.
    lazy var actions = AppActions(installer: AppInstaller(setup: .standard()), model: model)
    /// Whether the `subset` command is on the PATH, for the window's Command Line section.
    let commandLine = CommandLineModel(detector: .standard())

    func applicationWillFinishLaunching(_: Notification) {
        // Info.plist sets LSUIElement for the bundled app; the SwiftPM executable has no Info.plist, so set the policy
        // here too and both stay out of the Dock.
        NSApp.setActivationPolicy(.accessory)
    }

    // Quitting while an install, update or move to the Trash runs cancels it and quits once it has cleaned up (no staged
    // copy, private folder or attached image is left behind).
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard actions.isWorking else { return .terminateNow }
        Task {
            await actions.cancelAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Refreshes on launch and every 6 hours; the window refreshes again when it opens.
        model.startAutoRefresh()
    }
}

/// The menu bar item's menu: how many updates are available, then the commands, built from `MenuCommand` so the menu and
/// its tests share one list.
struct SubsetMenu: View {
    @ObservedObject var model: AppListModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Choosing the updates line opens the window, which lists them.
        Button(model.updatesMenuTitle) { perform(.openSubset) }
        Divider()
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
