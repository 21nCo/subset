import CoreGraphics

/// Which items a switcher goes through, before the Shown-windows options and the search.
public enum SwitcherScope: Sendable, Equatable {
    /// Every window, and the windowless apps' cells.
    case allWindows
    /// Only the windows of the app with this pid, the frontmost app when the same-app shortcut was pressed; nothing
    /// when there is no frontmost app (nil). An app cell is not a window, so it never appears.
    case appWindows(pid_t?)

    public func includes(_ item: SwitcherItem) -> Bool {
        switch self {
        case .allWindows: true
        case let .appWindows(pid): item.window != nil && item.pid == pid
        }
    }
}

/// The open switcher: the windows (and, with `ShownWindows.windowlessApps`, windowless apps) it lists, the search
/// typed so far, the selection, the grid they are laid out in, the scrolled position, and the message about the last
/// operation. Pure state; the host builds one from a fresh window list when a switch starts, feeds it the session's
/// events and the mouse, performs the operations it asks for, and draws it.
///
/// The selection is the index of a listed item, or nil when the list is empty. It follows its item, not its place:
/// when the list changes, the selected item stays selected, and if it is gone the selection moves to the item that
/// followed it. A change to the query moves it to the first match instead.
///
/// Every listed item is in `scope`, passes `filter` and matches `query` (`SwitcherSearch`), whichever way the list
/// changed: a fresh list, the kept items of apps that did not answer, an operation's result, a new filter, or a new
/// query. While the host holds keys back (`hold()`), a search lists only items it listed when they began to wait; once
/// a search has ended (`endSearch(before:)`), the query is gone and only the items it listed then can be listed, in that
/// order, or those a waiting key's `SearchResult` lists. Either way a later read can only remove items.
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

    /// What a key typed before the switch ended lists, worked out when it ended (`endSearch(before:)`): the items it
    /// listed then, in that order, or, when it left the query empty, every candidate. It holds no text.
    public struct SearchResult: Sendable, Equatable {
        fileprivate let items: [SwitcherItem.ID]?
    }

    private struct Held: Sendable, Equatable {
        var items: [SwitcherItem.ID]
        var query: String
    }

    /// The listed items: those of `candidates` that match `query`, best match first.
    public private(set) var items: [SwitcherItem]
    /// The items in `scope` that `filter` shows, in recency order, before the search.
    public private(set) var candidates: [SwitcherItem]
    /// The Shown-windows options and excluded apps the listed items pass.
    public private(set) var filter: SwitcherFilter
    /// The windows this switcher goes through: all of them, or the frontmost app's.
    public let scope: SwitcherScope
    /// What has been typed since the switcher opened. It lives only here: never stored or logged, and gone with the
    /// switcher.
    public private(set) var query = ""
    /// While keys wait (`hold()`), the items listed when they began to wait, in that order, and the query then.
    private var held: Held?
    /// The items a search listed when it ended, or a waiting key's result lists (`show(_:)`), in that order: the only
    /// ones that can be listed, in that order; nil while none has ended, or once a key left the query empty.
    private var searched: [SwitcherItem.ID]?
    public private(set) var selection: Int?
    public private(set) var layout: SwitcherLayout
    public private(set) var firstVisibleRow = 0
    /// A short, user-facing note about the last operation that did not succeed; never contains a window title.
    public private(set) var message: String?
    /// The usable size of the screen the switcher is on.
    public let available: CGSize

    /// Opens on the previous window, the usual target, or on the only item there is, whichever direction the shortcut
    /// started in. `items` is the whole list, the current window first; only the items in `scope` that `filter` shows
    /// are listed. With `.appWindows`, the previous window is the app's second most recent one.
    public init(
        items: [SwitcherItem],
        available: CGSize,
        metrics: SwitcherMetrics = .standard,
        filter: SwitcherFilter = .showingEverything,
        scope: SwitcherScope = .allWindows
    ) {
        let scoped = items.filter(scope.includes)
        let listed = scoped.filter(filter.shows)
        self.items = listed
        candidates = listed
        self.filter = filter
        self.scope = scope
        self.available = available
        layout = SwitcherLayout(count: listed.count, available: available, metrics: metrics)
        selection = Self.openingSelection(listed, of: scoped)
    }

    /// The previous window: index 1 when the first listed item is the first of `all`, the current window, and index 0
    /// when the filter left the current window out; or the only item there is.
    private static func openingSelection(_ listed: [SwitcherItem], of all: [SwitcherItem]) -> Int? {
        guard let first = listed.first else { return nil }
        return first.id == all.first?.id ? min(1, listed.count - 1) : 0
    }

    /// What the switcher says in place of the grid when it lists nothing: "No matching windows" when a search left
    /// nothing, otherwise "No windows". Nil while it lists something.
    public var emptyText: String? {
        guard items.isEmpty else { return nil }
        return query.isEmpty ? "No windows" : "No matching windows"
    }

    public var selectedItem: SwitcherItem? {
        selection.map { items[$0] }
    }

    public var visibleIndices: Range<Int> {
        layout.visibleIndices(firstVisibleRow: firstVisibleRow)
    }

    // MARK: - Session events

    /// Applies a session event: a further trigger or step moves the selection by one, wrapping around; ↑ and ↓ move it
    /// by a row; a typed character or Delete changes the query and selects the first match; an operation key returns
    /// the operation to perform on the selected window. An app cell has no window to minimize or close, so only ⌘H and
    /// ⌘Q act on it. Other events change nothing here: the host ends the switcher on them.
    @discardableResult
    public mutating func handle(_ event: SwitchSession.Event) -> Request? {
        switch event {
        case let .trigger(direction, _), let .step(direction):
            step(direction)
        case let .type(character):
            guard searched == nil else { return nil }
            search(query + String(character))
        case .deleteBackward:
            guard searched == nil, !query.isEmpty else { return nil }
            search(String(query.dropLast()))
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

    /// Lists the candidates that match `query`, and selects the first match.
    private mutating func search(_ query: String) {
        self.query = query
        list(matches())
        firstVisibleRow = 0
        selection = nil
        select(0)
    }

    /// The candidates that match the query, best match first. While keys wait, a search lists only items that were
    /// listed when they began to, in the same order while the query is the same; an ended search lists the candidates
    /// it listed, in its order.
    private func matches() -> [SwitcherItem] {
        if let searched { return Self.ordered(candidates, as: searched) }
        let found = SwitcherSearch.matches(query, in: candidates)
        guard let held, !query.isEmpty else { return found }
        let listed = Set(held.items)
        let kept = found.filter { listed.contains($0.id) }
        return query == held.query ? Self.ordered(kept, as: held.items) : kept
    }

    /// Those of `items` whose IDs are in `ids`, in the order of `ids`.
    private static func ordered(_ items: [SwitcherItem], as ids: [SwitcherItem.ID]) -> [SwitcherItem] {
        ids.compactMap { id in items.first { $0.id == id } }
    }

    /// The host has begun to hold keys back until a pending operation's result has been read: until `stopHolding()`, a
    /// read cannot add an item to a search's list or reorder it, so a waiting key never acts on a window the switcher
    /// did not show. A search typed by the waiting keys goes only through the items listed now. Without a query the
    /// list changes as usual. Holding again changes nothing.
    public mutating func hold() {
        guard held == nil else { return }
        held = Held(items: items.map(\.id), query: query)
    }

    /// Nothing waits any more: the search lists every candidate that matches it, any a read added included, with the
    /// selection on its item.
    public mutating func stopHolding() {
        guard held != nil else { return }
        held = nil
        refreshed(candidates)
    }

    /// Ends the search when the switch ends while keys still wait for a pending operation, so no text outlives the
    /// panel and the commit that waits chooses among what the search listed. Works out now what each of `typed`, the
    /// characters and Deletes that wait, in order, will list, as if each were applied after the one before (the items
    /// held, ranked as now), then drops the query and what was held. From now on only the items listed now can be
    /// listed, in the order they are listed, with the selection on its item, until `show(_:)` lists a key's result.
    /// Returns a result for each of `typed`, nil for one that changes nothing; without a query and with no waiting keys
    /// nothing changes.
    public mutating func endSearch(before typed: [SwitchSession.Event]) -> [SearchResult?] {
        var trial = self
        let results = typed.map { key -> SearchResult? in
            let before = trial.query
            trial.handle(key)
            guard trial.query != before else { return nil }
            return SearchResult(items: trial.query.isEmpty ? nil : trial.items.map(\.id))
        }
        if !query.isEmpty { searched = items.map(\.id) }
        query = ""
        held = nil
        return results
    }

    /// Lists what a waiting key searched for (`endSearch(before:)`), as typing it would have: only the items in
    /// `result` that are still candidates, in its order, or every candidate for an empty query, with the first
    /// selected.
    public mutating func show(_ result: SearchResult) {
        searched = result.items
        list(matches())
        firstVisibleRow = 0
        selection = nil
        select(0)
    }

    /// Lists `items` and lays them out, keeping the scroll position where it can. The selection is the caller's.
    private mutating func list(_ items: [SwitcherItem]) {
        self.items = items
        layout = SwitcherLayout(count: items.count, available: available, metrics: layout.metrics)
        firstVisibleRow = layout.clampedFirstRow(firstVisibleRow)
    }

    /// Scrolls by `rows` (positive scrolls down), as the scroll wheel does; the selection stays where it is.
    public mutating func scroll(byRows rows: Int) {
        firstVisibleRow = layout.clampedFirstRow(firstVisibleRow + rows)
    }

    // MARK: - List changes

    /// Replaces the list with a fresh one, keeping the selection on its item, or on the item that followed it when it
    /// is gone (the one before it when none after it remains). The items of `unread` apps, which did not answer this
    /// read, are not known to be gone: they stay listed, each after the item it followed. As for `init`, `fresh` is the
    /// whole list and only the items in `scope` that `filter` shows and that match the query are listed; a switcher
    /// that was empty opens on the previous window, or on the first match while searching.
    public mutating func refreshed(_ fresh: [SwitcherItem], unread: Set<pid_t> = []) {
        let previous = items
        var fresh = fresh
        var next = 0
        for old in unread.isEmpty ? [] : candidates {
            if let index = fresh.firstIndex(where: { $0.id == old.id }) {
                next = index + 1
            } else if unread.contains(old.pid) {
                fresh.insert(old, at: next)
                next += 1
            }
        }
        let all = fresh.filter(scope.includes)
        candidates = all.filter(filter.shows)
        let selected = selection
        list(matches())
        selection = nil
        guard !items.isEmpty else { return }
        guard let selected else {
            return select(query.isEmpty && searched == nil ? Self.openingSelection(items, of: all) ?? 0 : 0)
        }
        let followers = previous[selected...] + previous[..<selected].reversed()
        for old in followers {
            if let index = items.firstIndex(where: { $0.id == old.id }) { return select(index) }
        }
        select(min(selected, items.count - 1))
    }

    /// Applies a new filter to the listed items at once, keeping the selection on its item or its follower. Items it
    /// now shows that are not listed appear with the next refresh.
    public mutating func apply(_ filter: SwitcherFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        refreshed(candidates)
    }

    /// Records an operation's result: sets or clears the message and, until the next refresh confirms it, shows the
    /// items as the operation left them (a minimized window or a hidden app flagged, a window or app found gone
    /// removed). A window just minimized, or an app just hidden, leaves the list when `filter` does not show it. A close or quit that was delivered removes nothing: the app may be asking to save, so the window
    /// stays listed and selected until a refresh no longer lists it.
    public mutating func finished(_ request: Request, result: OperationResult) {
        message = Self.message(for: result, of: request.operation, appName: request.item.appName)
        let id = request.item.id
        let pid = request.item.pid
        var updated = candidates
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
            "\(HopIdentity.appName) needs Accessibility access"
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
