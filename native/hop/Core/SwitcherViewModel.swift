import CoreGraphics

/// The open switcher: the windows it lists, the selection, the grid they are laid out in, the scrolled position, and
/// the message about the last operation. Pure state; the host builds one from a fresh window list when a switch
/// starts, feeds it the session's events and the mouse, performs the operations it asks for, and draws it.
///
/// The selection is the index of a listed window, or nil when the list is empty. It follows its window, not its place:
/// when the list changes, the selected window stays selected, and if it is gone the selection moves to the window that
/// followed it.
public struct SwitcherViewModel: Sendable, Equatable {
    /// An operation for the host to perform on a listed window.
    public struct Request: Sendable, Equatable {
        public var operation: WindowOperation
        public var window: WindowEntry

        public init(_ operation: WindowOperation, on window: WindowEntry) {
            self.operation = operation
            self.window = window
        }
    }

    public private(set) var entries: [WindowEntry]
    public private(set) var selection: Int?
    public private(set) var layout: SwitcherLayout
    public private(set) var firstVisibleRow = 0
    /// A short, user-facing note about the last operation that did not succeed; never contains a window title.
    public private(set) var message: String?
    /// The usable size of the screen the switcher is on.
    public let available: CGSize

    /// Opens on the previous window (index 1), the usual target, or on the only window there is, whichever direction
    /// the shortcut started in.
    public init(entries: [WindowEntry], available: CGSize, metrics: SwitcherMetrics = .standard) {
        self.entries = entries
        self.available = available
        layout = SwitcherLayout(count: entries.count, available: available, metrics: metrics)
        selection = entries.isEmpty ? nil : min(1, entries.count - 1)
    }

    public var selectedEntry: WindowEntry? {
        selection.map { entries[$0] }
    }

    public var visibleIndices: Range<Int> {
        layout.visibleIndices(firstVisibleRow: firstVisibleRow)
    }

    // MARK: - Session events

    /// Applies a session event: a further trigger or step moves the selection by one, wrapping around; ↑ and ↓ move it
    /// by a row; an operation key returns the operation to perform on the selected window. Other events change
    /// nothing here: the host ends the switcher on them.
    @discardableResult
    public mutating func handle(_ event: SwitchSession.Event) -> Request? {
        switch event {
        case let .trigger(direction), let .step(direction):
            step(direction)
        case let .row(direction):
            guard let selection else { return nil }
            select(layout.index(moving: direction, from: selection))
        case let .operation(operation):
            return selectedEntry.map { Request(operation, on: $0) }
        case .modifierReleased, .escape, .interrupted:
            break
        }
        return nil
    }

    private mutating func step(_ direction: SwitchDirection) {
        guard let selection, !entries.isEmpty else { return }
        let offset = direction == .forward ? 1 : -1
        select(((selection + offset) % entries.count + entries.count) % entries.count)
    }

    /// Selects the window at `index`, as hovering over it does, and scrolls it into view. An index outside the list
    /// changes nothing.
    public mutating func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selection = index
        firstVisibleRow = layout.firstVisibleRow(showing: index, from: firstVisibleRow)
    }

    /// Scrolls by `rows` (positive scrolls down), as the scroll wheel does; the selection stays where it is.
    public mutating func scroll(byRows rows: Int) {
        firstVisibleRow = layout.clampedFirstRow(firstVisibleRow + rows)
    }

    // MARK: - List changes

    /// Replaces the list with a fresh one, keeping the selection on its window, or on the window that followed it
    /// when it is gone (the one before it when none after it remains). The windows of `unread` apps, which did not
    /// answer this read, are not known to be gone: they stay listed, each after the window it followed.
    public mutating func refreshed(_ fresh: [WindowEntry], unread: Set<pid_t> = []) {
        let previous = entries
        var fresh = fresh
        var next = 0
        for old in unread.isEmpty ? [] : previous {
            if let index = fresh.firstIndex(where: { $0.ref == old.ref }) {
                next = index + 1
            } else if unread.contains(old.pid) {
                fresh.insert(old, at: next)
                next += 1
            }
        }
        let selected = selection
        entries = fresh
        layout = SwitcherLayout(count: fresh.count, available: available, metrics: layout.metrics)
        firstVisibleRow = layout.clampedFirstRow(firstVisibleRow)
        selection = nil
        guard !fresh.isEmpty else { return }
        guard let selected else { return select(min(1, fresh.count - 1)) }
        let followers = previous[selected...] + previous[..<selected].reversed()
        for old in followers {
            if let index = fresh.firstIndex(where: { $0.ref == old.ref }) { return select(index) }
        }
        select(min(selected, fresh.count - 1))
    }

    /// Records an operation's result: sets or clears the message and, until the next refresh confirms it, shows the
    /// windows as the operation left them (a minimized window or a hidden app flagged, a window or app found gone
    /// removed). A close or quit that was delivered removes nothing: the app may be asking to save, so the window
    /// stays listed and selected until a refresh no longer lists it.
    public mutating func finished(_ request: Request, result: OperationResult) {
        message = Self.message(for: result, of: request.operation, appName: request.window.appName)
        let ref = request.window.ref
        let pid = request.window.pid
        var updated = entries
        switch (request.operation, result) {
        case (_, .windowGone):
            updated.removeAll { $0.ref == ref }
        case (_, .appGone):
            updated.removeAll { $0.pid == pid }
        case (.minimize, .done):
            for index in updated.indices where updated[index].ref == ref { updated[index].isMinimized = true }
        case (.hideApp, .done):
            for index in updated.indices where updated[index].pid == pid { updated[index].isAppHidden = true }
        case (.focus, _), (.close, .done), (.quitApp, .done), (_, .refused), (_, .notPermitted):
            return
        }
        refreshed(updated)
    }

    /// Clears the message, when its time on screen is up.
    public mutating func clearMessage() {
        message = nil
    }

    /// The note for an operation's result, or nil when there is nothing to say: it succeeded, or the window or app it
    /// meant to close or quit is already gone. Names the app, never the window.
    public static func message(for result: OperationResult, of operation: WindowOperation, appName: String) -> String? {
        switch result {
        case .done:
            nil
        case .notPermitted:
            "Hop needs Accessibility access"
        case .appGone:
            operation == .quitApp ? nil : "\(appName) has quit"
        case .windowGone:
            operation == .close ? nil : "That \(appName) window has closed"
        case .refused:
            switch operation {
            case .focus: "Couldn't bring \(appName) forward"
            case .minimize: "Couldn't minimize the \(appName) window"
            case .close: "Couldn't close the \(appName) window"
            case .hideApp: "Couldn't hide \(appName)"
            case .quitApp: "Couldn't quit \(appName)"
            }
        }
    }
}

extension WindowEntry {
    /// The cell's text: the title, or the app's name when the window has no title.
    public var displayTitle: String {
        title.isEmpty ? appName : title
    }

    /// The badges the cell shows, in order.
    public var badges: [String] {
        (isMinimized ? ["minimized"] : []) + (isAppHidden ? ["hidden"] : [])
    }

    /// What VoiceOver reads for the cell: the title, the app's name, and the badges. Only VoiceOver reads it; it is
    /// never logged.
    public var accessibilityLabel: String {
        ((title.isEmpty ? [] : [title]) + [appName] + badges).joined(separator: ", ")
    }
}
