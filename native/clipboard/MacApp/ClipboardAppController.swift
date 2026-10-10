import AppKit
import Combine
import Carbon.HIToolbox
import Foundation

@MainActor
final class ClipboardAppController: ObservableObject {
    let manager: ClipboardManager

    private let panelController: ClipboardPanelController
    private let statusBarController = StatusBarController()
    private let shortcutMonitor = GlobalShortcutMonitor.shared
    private var cancellables = Set<AnyCancellable>()

    /// Unit tests run inside this app as their host. They must not read the user's clipboard,
    /// write the real history file, or claim global shortcuts.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(manager: ClipboardManager? = nil) {
        let isTesting = Self.isRunningUnitTests
        let manager = manager ?? ClipboardManager(
            store: isTesting
                ? ClipboardHistoryStore(baseDirectory: FileManager.default.temporaryDirectory, namespace: "dev.subset.clipboard.test-host")
                : ClipboardHistoryStore(),
            startsMonitoring: !isTesting
        )
        self.manager = manager
        self.panelController = ClipboardPanelController(manager: manager)
        configureStatusBar()
        bindState()
        if !isTesting {
            registerShortcut()
        }
    }

    private func configureStatusBar() {
        statusBarController.configure(
            onOpenBottom: { [weak self] in
                self?.togglePanel(placement: .bottom)
            },
            onOpenSide: { [weak self] in
                self?.togglePanel(placement: .right)
            },
            onToggleCapture: { [weak self] in
                self?.manager.toggleCapturePaused()
            },
            onClearHistory: { [weak self] in
                self?.confirmClearHistory()
            },
            onEnablePaste: { [weak self] in
                self?.manager.openAccessibilitySettings()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    private func bindState() {
        // permissionStatus is included so the menu updates when Accessibility trust changes.
        manager.$items
            .combineLatest(manager.$isCapturePaused, manager.$statusMessage, manager.$permissionStatus)
            .sink { [weak self] items, isCapturePaused, statusMessage, _ in
                self?.statusBarController.refresh(
                    itemCount: items.count,
                    isCapturePaused: isCapturePaused,
                    statusMessage: statusMessage,
                    canPasteDirectly: ActiveAppPasteService.hasAccessibilityTrust()
                )
            }
            .store(in: &cancellables)
    }

    private func registerShortcut() {
        let didRegister = shortcutMonitor.start(shortcuts: [
            GlobalShortcutRegistration(
                id: 1,
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(cmdKey | shiftKey),
                onPress: { [weak self] in
                    self?.togglePanel(placement: .bottom)
                }
            ),
            GlobalShortcutRegistration(
                id: 2,
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(cmdKey | optionKey | shiftKey),
                onPress: { [weak self] in
                    self?.togglePanel(placement: .right)
                }
            )
        ])

        if !didRegister {
            manager.report(status: "Clipboard shortcuts are unavailable. Use the menu bar icon to open the shelf.")
        }
    }

    /// Clearing history cannot be undone, so the menu action asks first (Paste and Maccy both confirm).
    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes \(manager.items.count) saved item(s) from this Mac. It does not change what is on the clipboard now."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            manager.clearHistory()
        }
    }

    func openPanel() {
        if !panelController.isPresented {
            panelController.show(placement: .bottom)
        }
    }

    func togglePanel(placement: ClipboardShelfPlacement = .bottom) {
        if panelController.isPresented, panelController.currentPlacement == placement {
            panelController.hide()
        } else {
            panelController.show(placement: placement)
        }
    }
}
