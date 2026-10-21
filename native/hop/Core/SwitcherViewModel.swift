import CoreGraphics

/// The open switcher: the windows (and, with `ShownWindows.windowlessApps`, windowless apps) it lists, the selection,
/// the grid they are laid out in, the scrolled position, and the message about the last operation. Pure state; the
/// host builds one from a fresh window list when a switch starts, feeds it the session's events and the mouse,
/// performs the operations it asks for, and draws it.
///
/// The selection is the index of a listed item, or nil when the list is empty. It follows its item, not its place:
/// when the list changes, the selected item stays selected, and if it is gone the selection moves to the item that
/// followed it.
///
/// Every listed item passes `filter`, whichever way the list changed: a fresh list, the kept items of apps that did not
/// answer, an operation's result, or a new filter.
public struct SwitcherViewModel: Sendable, Equatable {
    /// An operation for the host to perform on a listed window, or on the app of an app cell.
    public struct Request: Sendable, Equatable {
        public var operation: WindowOperation
        public var item: SwitcherItem

        public init(_ operation: WindowOperation, on item: SwitcherItem) {
            self.operation = operation
            self.item = item
        }
    }

    public private(set) var items: [SwitcherItem]
    /// The Shown-windows options and excluded apps the listed items pass.
    public private(set) var filter: SwitcherFilter
    public private(set) var selection: Int?
    public private(set) var layout: SwitcherLayout
    public private(set) var firstVisibleRow = 0
    /// A short, user-facing note about the last operation that did not succeed; never contains a window title.
    public private(set) var message: String?
    /// The usable size of the screen the switcher is on.
    public let available: CGSize

    /// Opens on the previous window, the usual target, or on the only item there is, whichever direction the shortcut
    /// started in. `items` is the whole list, the current window first; only the items `filter` shows are listed.
    public init(
        items: [SwitcherItem],
        available: CGSize,
        metrics: SwitcherMetrics = .standard,
        filter: SwitcherFilter = .showingEverything
    ) {
        let listed = items.filter(filter.shows)
        self.items = listed
        self.filter = filter
        self.available = available
        layout = SwitcherLayout(count: listed.count, available: available, metrics: metrics)
        selection = Self.openingSelection(listed, of: items)
    }

    /// The previous window: index 1 when the first listed item is the first of `all`, the current window, and index 0
    /// when the filter left the current window out; or the only item there is.
    private static func openingSelection(_ listed: [SwitcherItem], of all: [SwitcherItem]) -> Int? {
        guard let first = listed.first else { return nil }
        return first.id == all.first?.id ? min(1, listed.count - 1) : 0
    }

    public var selectedItem: SwitcherItem? {
        selection.map { items[$0] }
    }

    public var visibleIndices: Range<Int> {
        layout.visibleIndices(firstVisibleRow: firstVisibleRow)
    }

    // MARK: - Session events

    /// Applies a session event: a further trigger or step moves the selection by one, wrapping around; ↑ and ↓ move it
    /// by a row; an operation key returns the operation to perform on the selected window. An app cell has no window
    /// to minimize or close, so only ⌘H and ⌘Q act on it. Other events change nothing here: the host ends the switcher
    /// on them.
    @discardableResult
    public mutating func handle(_ event: SwitchSession.Event) -> Request? {
        switch event {
        case let .trigger(direction), let .step(direction):
            step(direction)
        case let .row(direction):
            guard let selection else { return nil }
            select(layout.index(moving: direction, from: selection))
        case let .operation(operation):
            guard let item = selectedItem else { return nil }
            if item.window == nil, operation != .hideApp, operation != .quitApp { return nil }
            return Request(operation, on: item)
        case .modifierReleased, .escape, .interrupted:
            break
        }
        return nil
    }

    private mutating func step(_ direction: SwitchDirection) {
        guard let selection, !items.isEmpty else { return }
        let offset = direction == .forward ? 1 : -1
        select(((selection + offset) % items.count + items.count) % items.count)
    }

    /// Selects the item at `index`, as hovering over it does, and scrolls it into view. An index outside the list
    /// changes nothing.
    public mutating func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        firstVisibleRow = layout.firstVisibleRow(showing: index, from: firstVisibleRow)
    }

    /// Scrolls by `rows` (positive scrolls down), as the scroll wheel does; the selection stays where it is.
    public mutating func scroll(byRows rows: Int) {
        firstVisibleRow = layout.clampedFirstRow(firstVisibleRow + rows)
    }

    // MARK: - List changes

    /// Replaces the list with a fresh one, keeping the selection on its item, or on the item that followed it when it
    /// is gone (the one before it when none after it remains). The items of `unread` apps, which did not answer this
    /// read, are not known to be gone: they stay listed, each after the item it followed. As for `init`, `fresh` is the
    /// whole list and only the items `filter` shows are listed; a switcher that was empty opens on the previous window.
    public mutating func refreshed(_ fresh: [SwitcherItem], unread: Set<pid_t> = []) {
        let previous = items
        var fresh = fresh
        var next = 0
        for old in unread.isEmpty ? [] : previous {
            if let index = fresh.firstIndex(where: { $0.id == old.id }) {
                next = index + 1
            } else if unread.contains(old.pid) {
                fresh.insert(old, at: next)
                next += 1
            }
        }
        let all = fresh
        fresh = fresh.filter(filter.shows)
        let selected = selection
        items = fresh
        layout = SwitcherLayout(count: fresh.count, available: available, metrics: layout.metrics)
        firstVisibleRow = layout.clampedFirstRow(firstVisibleRow)
        selection = nil
        guard !fresh.isEmpty else { return }
        guard let selected else { return select(Self.openingSelection(fresh, of: all) ?? 0) }
        let followers = previous[selected...] + previous[..<selected].reversed()
        for old in followers {
            if let index = fresh.firstIndex(where: { $0.id == old.id }) { return select(index) }
        }
        select(min(selected, fresh.count - 1))
    }

    /// Applies a new filter to the listed items at once, keeping the selection on its item or its follower. Items it
    /// now shows that are not listed appear with the next refresh.
    public mutating func apply(_ filter: SwitcherFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        refreshed(items)
    }

    /// Records an operation's result: sets or clears the message and, until the next refresh confirms it, shows the
    /// items as the operation left them (a minimized window or a hidden app flagged, a window or app found gone
    /// removed). A window just minimized, or an app just hidden, leaves the list when `filter` does not show it. A close or quit that was delivered removes nothing: the app may be asking to save, so the window
    /// stays listed and selected until a refresh no longer lists it.
    public mutating func finished(_ request: Request, result: OperationResult) {
        message = Self.message(for: result, of: request.operation, appName: request.item.appName)
        let id = request.item.id
        let pid = request.item.pid
        var updated = items
        switch (request.operation, result) {
        case (_, .windowGone):
            updated.removeAll { $0.id == id }
        case (_, .appGone):
            updated.removeAll { $0.pid == pid }
        case (.minimize, .done):
            for index in updated.indices where updated[index].id == id { updated[index].markMinimized() }
        case (.hideApp, .done):
            for index in updated.indices where updated[index].pid == pid { updated[index].markAppHidden() }
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
