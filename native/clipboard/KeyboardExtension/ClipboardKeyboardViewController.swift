#if canImport(UIKit)
import SwiftUI
import UIKit

final class ClipboardKeyboardViewController: UIInputViewController {
    private let controller = KeyboardClipboardController()
    private var hostingController: UIHostingController<ClipboardKeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?
    private var hasPerformedInitialSync = false

    override func viewDidLoad() {
        super.viewDidLoad()
        installHostingController()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        controller.updateSetupState(fullAccess: hasFullAccess)
        // needsInputModeSwitchKey is reliable only once the keyboard is about to appear;
        // rebuild the root view so the globe key shows when the device needs it.
        hostingController?.rootView = makeRootView()

        guard !hasPerformedInitialSync else {
            DispatchQueue.main.async { [weak self] in
                self?.controller.reload(forceSync: false)
            }
            return
        }

        hasPerformedInitialSync = true
        DispatchQueue.main.async { [weak self] in
            self?.controller.reload(forceSync: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        heightConstraint?.constant = preferredKeyboardHeight
    }

    private var preferredKeyboardHeight: CGFloat {
        traitCollection.horizontalSizeClass == .regular ? 432 : 328
    }

    private func installHostingController() {
        let host = UIHostingController(rootView: makeRootView())
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: preferredKeyboardHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        self.heightConstraint = heightConstraint
        host.didMove(toParent: self)
        hostingController = host
    }

    private func makeRootView() -> ClipboardKeyboardRootView {
        ClipboardKeyboardRootView(
            controller: controller,
            needsInputModeSwitchKey: needsInputModeSwitchKey,
            onAdvanceToNextInputMode: { [weak self] in
                self?.advanceToNextInputMode()
            },
            onBackspace: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onReload: { [weak self] in
                self?.controller.updateSetupState(fullAccess: self?.hasFullAccess ?? false)
                self?.controller.reload(forceSync: true)
            },
            onOpenKeyboardSettings: { [weak self] in
                self?.openKeyboardSettings()
            },
            onSelect: { [weak self] item in
                self?.activate(item)
            }
        )
    }

    private func activate(_ item: ClipboardItem) {
        controller.activate(item) { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        }
    }

    private func openKeyboardSettings() {
        guard let url = URL(string: "prefs:root=General&path=Keyboard") else {
            controller.showSettingsGuidance(openAttemptSucceeded: false)
            return
        }

        extensionContext?.open(url) { [weak self] success in
            Task { @MainActor [weak self] in
                self?.controller.showSettingsGuidance(openAttemptSucceeded: success)
            }
        }
    }
}
#endif
