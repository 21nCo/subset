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
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = TimerController()
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController(controller: controller)
        controller.start()
    }

    /// Quitting stops only the board server this app started; the daemon and its timers keep running.
    func applicationWillTerminate(_ notification: Notification) {
        controller.stopBoard()
    }
}
