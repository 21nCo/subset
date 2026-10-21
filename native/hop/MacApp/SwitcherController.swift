import AppKit
import HopCore
import os

/// The switcher while a switch is in progress: opens it on a fresh window list, filtered by the Shown-windows settings
/// and excluded apps (`Settings.items(from:pointerDisplay:)`), applies the session's events and the mouse to its
/// `SwitcherViewModel`, performs the operations it asks for, and on commit hides it and brings the selected window
/// forward, or activates the selected windowless app. An operation, or a commit, that does not succeed shows its message for 1.5 seconds; one
/// that finds Hop without the Accessibility permission reopens onboarding instead. Nothing about a window, and never a
/// title, is logged.
///
/// An operation is pending until the list has been read again after its result: only that read shows whether a closed
/// window or a quit app is gone, or still there behind a save prompt. A further operation key, or a commit, that comes
/// while one is pending waits, in order, and then acts on the selection in the list as read; a commit hides the
/// switcher at once. A hover after a waiting key waits behind it too, and selects the window it was over, not the place.
/// A read that an app did not answer in time leaves that app's windows listed: they are unknown, not gone. The settings
/// are read each time the list is, so a change applies from the next read.
@MainActor
final class SwitcherController {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "switcher")
    /// How long a message stays up.
    static let messageDuration: Duration = .seconds(1.5)
    /// How long after an operation the list is read again, so a window that is closing has gone from Accessibility.
    static let refreshDelay: Duration = .milliseconds(250)

    /// Reads the window list, most recently used first, with the apps that did not answer; blocks for at most 0.3 s
    /// (`WindowListController.refresh()`).
    private let readWindows: () -> WindowList
    private let windowOperator: any WindowOperator
    private let settings: () -> Settings
    let panel = SwitcherPanel()
    private(set) var model: SwitcherViewModel?
    private var screen: NSScreen?
    /// The display the switcher opened on, for `ShownWindows.pointerDisplayOnly`; it stays the same while it is open.
    private var display: DisplayID?
    private var icons: [pid_t: NSImage] = [:]
    /// Bumped whenever the switcher opens or closes, so late results of an earlier switcher change nothing.
    private var generation = 0
    private var messageTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    /// Operations performed whose result has not yet been followed by a fresh read of the list.
    private var pending = 0
    /// What came while an operation was pending, carried out in order once none is.
    private var deferred: [Deferred] = []

    private enum Deferred {
        case event(SwitchSession.Event)
        /// Select this item, as a hover over it did, if it is still listed.
        case select(SwitcherItem.ID)
        /// Commit the selection, or only this item (a click chose it) if it is still listed.
        case commit(SwitcherItem.ID?)
    }

    /// The switcher ended the session itself (a click chose a window), so the host's session must end too.
    var onSessionEnded: () -> Void = {}
    /// An operation found Hop without the Accessibility permission.
    var onNotPermitted: () -> Void = {}

    init(
        readWindows: @escaping () -> WindowList,
        windowOperator: any WindowOperator,
        settings: @escaping () -> Settings = { .default }
    ) {
        self.readWindows = readWindows
        self.windowOperator = windowOperator
        self.settings = settings
        panel.switcherView.onHover = { [unowned self] index in
            guard let model, model.items.indices.contains(index) else { return }
            if deferred.isEmpty {
                if model.selection != index { update { $0.select(index) } }
                return
            }
            // Only the last hover matters once it waits.
            if case .select = deferred.last { deferred.removeLast() }
            deferred.append(.select(model.items[index].id))
        }
        panel.switcherView.onScroll = { [unowned self] rows in update { $0.scroll(byRows: rows) } }
        panel.switcherView.onChoose = { [unowned self] item in
            guard model?.items.contains(where: { $0.id == item }) == true else { return }
            onSessionEnded()
            commit(only: item)
        }
    }

    var isOpen: Bool { model != nil }

    /// Reads the window list and shows the switcher on the display under the pointer.
    func open() {
        reset()
        let screen = Self.screenUnderPointer()
        display = screen.flatMap(Self.displayID)
        let model = SwitcherViewModel(items: items(in: readWindows()), available: screen?.visibleFrame.size ?? .zero)
        self.model = model
        self.screen = screen
        loadIcons()
        observeTerminations()
        guard let screen else { return }
        panel.show(.switcher(model, icons: icons), on: screen)
        Self.log.debug("Switcher opened with \(model.items.count, privacy: .public) items")
    }

    /// The cells for a list, as the current settings show it on the switcher's display.
    private func items(in list: WindowList) -> [SwitcherItem] {
        settings().items(from: list, pointerDisplay: display)
    }

    /// Applies a session event: moves the selection, or performs an operation on the selected window. While an
    /// operation is pending, an operation key, and anything after it, waits.
    func apply(_ event: SwitchSession.Event) {
        guard model != nil else { return }
        if case .operation = event, pending > 0 { return deferred.append(.event(event)) }
        if !deferred.isEmpty { return deferred.append(.event(event)) }
        run(event)
    }

    private func run(_ event: SwitchSession.Event) {
        guard var model else { return }
        let request = model.handle(event)
        self.model = model
        render()
        if let request { perform(request) }
    }

    /// Hides the switcher and brings the selected window forward.
    func commit() {
        commit(only: nil)
    }

    /// Hides the switcher and brings `item` forward if it is still listed, or the selected item when it is nil: a
    /// window is focused and a windowless app activated. While an operation is pending, the item is chosen once the
    /// list has been read again after it.
    private func commit(only item: SwitcherItem.ID?) {
        guard pending == 0 else {
            deferred.append(.commit(item))
            panel.hide()
            return
        }
        let target = if let item { model?.items.first { $0.id == item } } else { model?.selectedItem }
        reset()
        guard let target else { return }
        let generation = generation
        Task { [windowOperator] in
            let result = await Self.perform(.focus, on: target, with: windowOperator)
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
        pending += 1
        Task { [windowOperator] in
            let result = await Self.perform(request.operation, on: request.item, with: windowOperator)
            Self.log.debug("""
                \(String(describing: request.operation), privacy: .public) finished: \
                \(String(describing: Self.kind(of: result)), privacy: .public)
                """)
            if result == .notPermitted { self.onNotPermitted() }
            guard self.generation == generation, self.model != nil else { return }
            self.update { $0.finished(request, result: result) }
            if self.model?.message != nil { self.scheduleMessageClear() }
            if result == .notPermitted { return self.settle() }
            self.scheduleRefresh(after: Self.refreshDelay, settling: true)
        }
    }

    /// An operation's result has been reconciled with the list; once none is pending, carries out what waited.
    private func settle() {
        pending -= 1
        while pending == 0, !deferred.isEmpty {
            switch deferred.removeFirst() {
            case let .event(event): run(event)
            case let .select(item):
                if let index = model?.items.firstIndex(where: { $0.id == item }) { update { $0.select(index) } }
            case let .commit(item): commit(only: item)
            }
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
        let list = readWindows()
        model?.refreshed(items(in: list), unread: Set(list.skippedApps.map(\.pid)))
        loadIcons()
        render()
    }

    /// Reads the list again after `delay`, unless the switcher has closed by then, and then settles the operation it
    /// follows if `settling`. Each request gets its own read, so an app quitting does not cancel the later read that
    /// waits for a closing window to go.
    private func scheduleRefresh(after delay: Duration, settling: Bool = false) {
        let generation = generation
        Task {
            try? await Task.sleep(for: delay)
            guard self.generation == generation else { return }
            self.refresh()
            if settling { self.settle() }
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
        pending = 0
        deferred = []
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
        let pids = Set(model.items.map(\.pid))
        icons = icons.filter { pids.contains($0.key) }
        for pid in pids where icons[pid] == nil {
            icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
    }

    private static func perform(
        _ operation: WindowOperation,
        on item: SwitcherItem,
        with windowOperator: any WindowOperator
    ) async -> OperationResult {
        switch item {
        case let .window(window): await windowOperator.perform(operation, on: window)
        case let .app(app): await windowOperator.perform(operation, onApp: app)
        }
    }

    private static func displayID(of screen: NSScreen) -> DisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
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
