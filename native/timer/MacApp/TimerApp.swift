import AppKit

/// A menu bar app (`LSUIElement`) with no Dock icon or main window.
@main
@MainActor
enum TimerApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    /// The app shows no menu bar, but key equivalents still go through its main menu. This Edit menu gives the
    /// countdown fields the standard editing shortcuts, sent to the focused field through the responder chain.
    static func mainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, key) in items { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return menu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifications = SystemUserNotifications()
    private lazy var controller = TimerController(notifications: notifications)
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController(controller: controller)
        controller.start()
        // After `start()`, so an action that launched the app waits for the runtime rather than failing.
        notifications.onAction = { [controller] action, timerId in controller.run(action, timerId: timerId) }
        notifications.activate()
        // Asks for notification permission the first time; while it is granted, the app plays Timer's alerts.
        controller.checkNotifications(ask: true)
    }

    /// Permission may have changed in System Settings meanwhile.
    func applicationDidBecomeActive(_ notification: Notification) {
        controller.checkNotifications()
    }

    /// Quitting stops only the board server this app started; the daemon and its timers keep running.
    func applicationWillTerminate(_ notification: Notification) {
        controller.stopBoard()
    }
}
