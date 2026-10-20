import AppKit
import HopCore
import os

/// The switcher while a switch is in progress: opens it on a fresh window list, applies the session's events and the
/// mouse to its `SwitcherViewModel`, performs the operations it asks for, and on commit hides it and brings the
/// selected window forward. An operation, or a commit, that does not succeed shows its message for 1.5 seconds; one
/// that finds Hop without the Accessibility permission reopens onboarding instead. Nothing about a window, and never a
/// title, is logged.
@MainActor
final class SwitcherController {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "switcher")
    /// How long a message stays up.
    static let messageDuration: Duration = .seconds(1.5)
    /// How long after an operation the list is read again, so a window that is closing has gone from Accessibility.
    static let refreshDelay: Duration = .milliseconds(250)

    /// Reads the window list, most recently used first; blocks for at most 0.3 s (`WindowListController.refresh()`).
    private let readWindows: () -> [WindowEntry]
    private let windowOperator: any WindowOperator
    let panel = SwitcherPanel()
    private(set) var model: SwitcherViewModel?
    private var screen: NSScreen?
    private var icons: [pid_t: NSImage] = [:]
    /// Bumped whenever the switcher opens or closes, so late results of an earlier switcher change nothing.
    private var generation = 0
    private var messageTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    /// The switcher ended the session itself (a click chose a window), so the host's session must end too.
    var onSessionEnded: () -> Void = {}
    /// An operation found Hop without the Accessibility permission.
    var onNotPermitted: () -> Void = {}

    init(readWindows: @escaping () -> [WindowEntry], windowOperator: any WindowOperator) {
        self.readWindows = readWindows
        self.windowOperator = windowOperator
        panel.switcherView.onHover = { [unowned self] index in
            guard let model, model.selection != index else { return }
            update { $0.select(index) }
        }
        panel.switcherView.onScroll = { [unowned self] rows in update { $0.scroll(byRows: rows) } }
        panel.switcherView.onChoose = { [unowned self] window in
            guard let index = model?.entries.firstIndex(where: { $0.ref == window }) else { return }
            update { $0.select(index) }
            onSessionEnded()
            commit()
        }
    }

    var isOpen: Bool { model != nil }

    /// Reads the window list and shows the switcher on the display under the pointer.
    func open() {
        reset()
        let screen = Self.screenUnderPointer()
        let model = SwitcherViewModel(entries: readWindows(), available: screen?.visibleFrame.size ?? .zero)
        self.model = model
        self.screen = screen
        loadIcons()
        observeTerminations()
        guard let screen else { return }
        panel.show(.switcher(model, icons: icons), on: screen)
        Self.log.debug("Switcher opened with \(model.entries.count, privacy: .public) windows")
    }

    /// Applies a session event: moves the selection, or performs an operation on the selected window.
    func apply(_ event: SwitchSession.Event) {
        guard var model else { return }
        let request = model.handle(event)
        self.model = model
        render()
        if let request { perform(request) }
    }

    /// Hides the switcher and brings the selected window forward.
    func commit() {
        let target = model?.selectedEntry
        reset()
        guard let target else { return }
        let generation = generation
        Task { [windowOperator] in
            let result = await windowOperator.perform(.focus, on: target)
            Self.log.debug("Focus finished: \(String(describing: Self.kind(of: result)), privacy: .public)")
            if result == .notPermitted { return self.onNotPermitted() }
            // A switcher opened since then replaces the message.
            guard self.generation == generation,
                  let text = SwitcherViewModel.message(for: result, of: .focus, appName: target.appName),
                  let screen = self.screen ?? Self.screenUnderPointer()
            else { return }
            self.panel.show(.message(text), on: screen)
            self.messageTask = Task {
                try? await Task.sleep(for: Self.messageDuration)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.panel.hide()
            }
        }
    }

    /// Hides the switcher and leaves the windows as they were.
    func cancel() {
        reset()
    }

    private func perform(_ request: SwitcherViewModel.Request) {
        let generation = generation
        Task { [windowOperator] in
            let result = await windowOperator.perform(request.operation, on: request.window)
            Self.log.debug("""
                \(String(describing: request.operation), privacy: .public) finished: \
                \(String(describing: Self.kind(of: result)), privacy: .public)
                """)
            if result == .notPermitted { self.onNotPermitted() }
            guard self.generation == generation, self.model != nil else { return }
            self.update { $0.finished(request, result: result) }
            if self.model?.message != nil { self.scheduleMessageClear() }
            if result != .notPermitted { self.scheduleRefresh(after: Self.refreshDelay) }
        }
    }

    private func update(_ change: (inout SwitcherViewModel) -> Void) {
        guard var model else { return }
        change(&model)
        self.model = model
        render()
    }

    private func render() {
        guard let model, let screen else { return }
        panel.update(.switcher(model, icons: icons), on: screen)
    }

    private func refresh() {
        guard model != nil else { return }
        let windows = readWindows()
        model?.refreshed(windows)
        loadIcons()
        render()
    }

    /// Reads the list again after `delay`, unless the switcher has closed by then. Each request gets its own read, so
    /// an app quitting does not cancel the later read that waits for a closing window to go.
    private func scheduleRefresh(after delay: Duration) {
        let generation = generation
        Task {
            try? await Task.sleep(for: delay)
            guard self.generation == generation else { return }
            self.refresh()
        }
    }

    private func scheduleMessageClear() {
        messageTask?.cancel()
        let generation = generation
        messageTask = Task {
            try? await Task.sleep(for: Self.messageDuration)
            guard !Task.isCancelled, self.generation == generation else { return }
            self.update { $0.clearMessage() }
        }
    }

    /// Ends the current switcher or message: hides the panel and drops pending work.
    private func reset() {
        generation += 1
        model = nil
        messageTask?.cancel()
        messageTask = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        panel.hide()
    }

    /// While the switcher is open, an app that quits (such as after ⌘Q) leaves the list at once.
    private func observeTerminations() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(after: .zero) }
        }
    }

    private func loadIcons() {
        guard let model else { return }
        let pids = Set(model.entries.map(\.pid))
        icons = icons.filter { pids.contains($0.key) }
        for pid in pids where icons[pid] == nil {
            icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// A result's case without its reason, for the log.
    private static func kind(of result: OperationResult) -> String {
        switch result {
        case .done: "done"
        case .windowGone: "windowGone"
        case .appGone: "appGone"
        case .refused: "refused"
        case .notPermitted: "notPermitted"
        }
    }
}
