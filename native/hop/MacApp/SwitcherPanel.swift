import AppKit
import HopCore
import SwiftUI

/// What the switcher panel shows.
enum SwitcherContent {
    /// The open switcher; `icons` holds each listed app's icon by pid, and `thumbnails` the windows' images that have
    /// arrived, by window. A cell without one shows its app's icon.
    case switcher(SwitcherViewModel, icons: [pid_t: NSImage], thumbnails: [HopCore.WindowRef: CGImage] = [:])
    /// Only a message, after the switcher closed: why the committed switch did not happen.
    case message(String)
}

/// The switcher's window: borderless, non-activating, above other windows and menus (`.popUpMenu`), on every Space and
/// beside full-screen windows. It never becomes key or main and never activates Hop, so the frontmost app keeps its
/// focus while the switcher is open; keys reach the switcher through the event tap, and mouse events through
/// `SwitcherContentView`.
@MainActor
final class SwitcherPanel: NSPanel {
    let switcherView = SwitcherContentView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = HopIdentity.appName
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        contentView = switcherView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `content` centered on `screen`'s usable area, at once.
    func show(_ content: SwitcherContent, on screen: NSScreen) {
        switcherView.prepareToShow()
        update(content, on: screen)
        orderFrontRegardless()
    }

    /// Redraws `content` and resizes the panel to it, keeping it centered on `screen`.
    func update(_ content: SwitcherContent, on screen: NSScreen) {
        let size = switcherView.update(content)
        let area = screen.visibleFrame
        let origin = NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded())
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Hides the panel and drops what it showed, including the search, so nothing typed outlives the switcher.
    func hide() {
        orderOut(nil)
        switcherView.clear()
    }
}

/// The panel's content: draws the SwiftUI view on a rounded material background, turns mouse movement, clicks and
/// scrolling over the grid into hover, choice and scroll callbacks (from `SwitcherLayout`, so they work although the
/// panel is never key and Hop is not active), and presents the grid to Accessibility as a list.
@MainActor
final class SwitcherContentView: NSView {
    /// The pointer moved over the cell at this index.
    var onHover: (Int) -> Void = { _ in }
    /// This item's cell was clicked: pressed and released while it was under the pointer.
    var onChoose: (SwitcherItem.ID) -> Void = { _ in }
    /// The scroll wheel or trackpad scrolled by this many rows (positive is down).
    var onScroll: (Int) -> Void = { _ in }

    static let footerHeight: CGFloat = 36
    /// The height of the search line above the grid, shown while there is a query.
    static let queryHeight: CGFloat = 36
    static let minimumWidth: CGFloat = 300
    static let emptyHeight: CGFloat = 96

    private let background = NSVisualEffectView()
    private let hosting = NSHostingView(rootView: SwitcherView(content: .message("")))
    private let accessibilityList = SwitcherAccessibilityList()
    private let accessibilityText = SwitcherAccessibilityText()
    private let accessibilityQuery = SwitcherAccessibilityText()
    private var model: SwitcherViewModel?
    private var message: String?
    /// The grid's top left corner in this view, which is wider than the grid when the message needs the room.
    private var gridOrigin = CGPoint.zero
    private var cells: [SwitcherItem.ID: SwitcherAccessibilityCell] = [:]
    /// Where the pointer was when the panel appeared: a panel appearing under a resting pointer must not take the
    /// selection from the keyboard, so hovering counts only once the pointer has moved.
    private var pointerAtShow: NSPoint?
    /// The item whose cell the mouse went down on. A click commits it only if the cell under the pointer on release
    /// still shows it, so a list that changed in between (after an operation, or a refresh) never commits another one.
    private var pressedItem: SwitcherItem.ID?
    private var scrollAccumulator: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        hosting.sizingOptions = []
        for view in [background, hosting] {
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        accessibilityList.setAccessibilityParent(self)
        accessibilityList.view = self
        accessibilityText.setAccessibilityParent(self)
        accessibilityText.view = self
        accessibilityQuery.setAccessibilityParent(self)
        accessibilityQuery.view = self
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Draws `content` and returns the size the panel needs for it.
    @discardableResult
    func update(_ content: SwitcherContent) -> NSSize {
        let previous = model?.selectedItem?.id
        let previousMessage = message
        let size: NSSize
        switch content {
        case let .switcher(model, _, _):
            self.model = model
            message = model.message
            let grid = model.items.isEmpty
                ? NSSize(width: Self.minimumWidth, height: Self.emptyHeight)
                : model.layout.size
            let header = model.query.isEmpty ? 0 : Self.queryHeight
            let width = message == nil && header == 0 ? grid.width : max(grid.width, Self.minimumWidth)
            size = NSSize(width: width, height: header + grid.height + (message == nil ? 0 : Self.footerHeight))
            gridOrigin = CGPoint(x: ((width - grid.width) / 2).rounded(), y: header)
        case let .message(text):
            model = nil
            message = text
            size = NSSize(width: Self.minimumWidth, height: Self.emptyHeight)
            gridOrigin = .zero
        }
        hosting.rootView = SwitcherView(content: content, gridOrigin: gridOrigin)
        if background.maskImage?.size != size { background.maskImage = Self.mask(size: size, radius: 16) }
        setFrameSize(size)
        updateAccessibility()
        announceChanges(previousSelection: previous, previousMessage: previousMessage)
        return size
    }

    /// Drops the switcher it showed, with its search, when the panel hides.
    func clear() {
        model = nil
        message = nil
        pressedItem = nil
        hosting.rootView = SwitcherView(content: .message(""))
        updateAccessibility()
    }

    /// Forgets the previous showing, so the first selection and message are announced and the pointer must move before
    /// hovering selects.
    func prepareToShow() {
        model = nil
        message = nil
        pointerAtShow = NSEvent.mouseLocation
        pressedItem = nil
        scrollAccumulator = 0
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Every mouse event in the panel comes here, not to the SwiftUI view, which draws only.
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseMoved(with _: NSEvent) {
        let pointer = NSEvent.mouseLocation
        if let start = pointerAtShow {
            guard hypot(pointer.x - start.x, pointer.y - start.y) >= 1 else { return }
            pointerAtShow = nil
        }
        if let index = index(atWindowPoint: window?.convertPoint(fromScreen: pointer)) { onHover(index) }
    }

    override func mouseDown(with event: NSEvent) {
        pressedItem = item(atWindowPoint: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedItem = nil }
        guard let pressed = pressedItem, item(atWindowPoint: event.locationInWindow) == pressed else { return }
        onChoose(pressed)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model, model.layout.rows > model.layout.visibleRows else { return }
        if !event.hasPreciseScrollingDeltas {
            if event.scrollingDeltaY != 0 { onScroll(event.scrollingDeltaY > 0 ? -1 : 1) }
            return
        }
        let pitch = model.layout.metrics.cellSize.height + model.layout.metrics.spacing
        scrollAccumulator -= event.scrollingDeltaY
        let rows = Int(scrollAccumulator / pitch)
        guard rows != 0 else { return }
        scrollAccumulator -= CGFloat(rows) * pitch
        onScroll(rows)
    }

    private func item(atWindowPoint point: NSPoint) -> SwitcherItem.ID? {
        guard let model, let index = index(atWindowPoint: point) else { return nil }
        return model.items[index].id
    }

    private func index(atWindowPoint point: NSPoint?) -> Int? {
        guard let point, let model else { return nil }
        let local = convert(point, from: nil)
        return model.layout.index(
            at: CGPoint(x: local.x - gridOrigin.x, y: local.y - gridOrigin.y),
            firstVisibleRow: model.firstVisibleRow
        )
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "\(HopIdentity.appName) window switcher" }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if model?.query.isEmpty == false { children.append(accessibilityQuery) }
        if let model, !model.items.isEmpty { children.append(accessibilityList) }
        if model?.items.isEmpty == true || message != nil { children.append(accessibilityText) }
        return children
    }

    /// The grid as Accessibility sees it: an `AXList` of the listed windows (and windowless apps), each labelled with
    /// its title, app name and badges, with the selected one marked.
    var accessibilityListElement: NSAccessibilityElement { accessibilityList }

    /// The search line as Accessibility sees it, such as "Search: rep"; empty without a query.
    var accessibilityQueryText: String { accessibilityQuery.text }

    private func updateAccessibility() {
        accessibilityText.text = [model?.emptyText, message].compactMap { $0 }.joined(separator: ". ")
        accessibilityText.frameInView = bounds
        accessibilityQuery.text = model.map { $0.query.isEmpty ? "" : "Search: \($0.query)" } ?? ""
        accessibilityQuery.frameInView = NSRect(x: 0, y: 0, width: bounds.width, height: gridOrigin.y)
        guard let model else {
            cells.removeAll()
            accessibilityList.cells = []
            return
        }
        var updated: [SwitcherItem.ID: SwitcherAccessibilityCell] = [:]
        var ordered: [SwitcherAccessibilityCell] = []
        for (index, item) in model.items.enumerated() {
            let cell = cells[item.id] ?? SwitcherAccessibilityCell(list: accessibilityList, view: self)
            cell.label = item.accessibilityLabel
            cell.selected = index == model.selection
            cell.frameInView = model.layout.frame(of: index, firstVisibleRow: model.firstVisibleRow)
                .map { $0.offsetBy(dx: gridOrigin.x, dy: gridOrigin.y) }
            updated[item.id] = cell
            ordered.append(cell)
        }
        cells = updated
        accessibilityList.cells = ordered
        accessibilityList.frameInView = NSRect(origin: gridOrigin, size: model.items.isEmpty ? .zero : model.layout.size)
    }

    private func announceChanges(previousSelection: SwitcherItem.ID?, previousMessage: String?) {
        if let message, message != previousMessage { announce(message) }
        guard let model, let selected = model.selectedItem, selected.id != previousSelection else { return }
        NSAccessibility.post(element: accessibilityList, notification: .selectedChildrenChanged)
        announce(selected.accessibilityLabel)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// The screen frame of a rectangle in this view, for Accessibility.
    fileprivate func screenFrame(of rect: NSRect?) -> NSRect {
        guard let rect, let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private static func mask(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The switcher's grid for Accessibility: an `AXList` whose children are the listed windows.
final class SwitcherAccessibilityList: NSAccessibilityElement {
    var cells: [SwitcherAccessibilityCell] = []
    var frameInView = NSRect.zero
    weak var view: SwitcherContentView?

    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Windows" }
    override func accessibilityChildren() -> [Any]? { cells }
    override func accessibilityVisibleChildren() -> [Any]? { cells.filter { $0.frameInView != nil } }
    override func accessibilitySelectedChildren() -> [Any]? { cells.filter(\.selected) }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }

    override func accessibilityFrame() -> NSRect {
        let (view, rect) = (view, frameInView)
        return MainActor.assumeIsolated { view?.screenFrame(of: rect) ?? .zero }
    }
}

/// One listed window in the switcher's `AXList`.
final class SwitcherAccessibilityCell: NSAccessibilityElement {
    var label = ""
    var selected = false
    /// The cell's frame in the content view, or nil while it is scrolled out of view.
    var frameInView: NSRect?
    weak var view: SwitcherContentView?

    init(list: SwitcherAccessibilityList, view: SwitcherContentView) {
        self.view = view
        super.init()
        setAccessibilityParent(list)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { label }
    override func isAccessibilitySelected() -> Bool { selected }

    override func accessibilityFrame() -> NSRect {
        let (view, rect) = (view, frameInView)
        return MainActor.assumeIsolated { view?.screenFrame(of: rect) ?? .zero }
    }
}

/// "No windows" or "No matching windows" and the message, as one static text; or the search line.
final class SwitcherAccessibilityText: NSAccessibilityElement {
    var text = ""
    var frameInView = NSRect.zero
    weak var view: SwitcherContentView?

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
    override func accessibilityLabel() -> String? { text }

    override func accessibilityFrame() -> NSRect {
        let (view, rect) = (view, frameInView)
        return MainActor.assumeIsolated { view?.screenFrame(of: rect) ?? .zero }
    }
}

// MARK: - SwiftUI

/// Draws the switcher: the search typed so far, if any, above the visible rows of the grid (or "No windows" or "No
/// matching windows") and the message beneath. It draws only; the content view handles the mouse and Accessibility, so
/// the whole view is hidden from Accessibility.
struct SwitcherView: View {
    let content: SwitcherContent
    var gridOrigin: CGPoint = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch content {
            case let .switcher(model, icons, thumbnails):
                if !model.query.isEmpty {
                    QueryText(model.query)
                        .frame(maxWidth: .infinity, minHeight: SwitcherContentView.queryHeight, maxHeight: SwitcherContentView.queryHeight)
                }
                if let empty = model.emptyText {
                    Text(empty)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: SwitcherContentView.emptyHeight)
                } else {
                    SwitcherGrid(model: model, icons: icons, thumbnails: thumbnails)
                        .padding(.leading, gridOrigin.x)
                }
                if let message = model.message {
                    MessageText(message)
                        .frame(maxWidth: .infinity, minHeight: SwitcherContentView.footerHeight)
                }
            case let .message(message):
                MessageText(message)
                    .frame(maxWidth: .infinity, minHeight: SwitcherContentView.emptyHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The search typed so far, on one line, truncated at its start so the latest characters stay in view.
private struct QueryText: View {
    let query: String

    init(_ query: String) {
        self.query = query
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(query)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct MessageText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 16)
    }
}

/// The visible rows, laid out exactly as `SwitcherLayout` places them, so hit-testing and Accessibility frames match
/// what is drawn.
private struct SwitcherGrid: View {
    let model: SwitcherViewModel
    let icons: [pid_t: NSImage]
    let thumbnails: [HopCore.WindowRef: CGImage]

    var body: some View {
        let layout = model.layout
        let metrics = layout.metrics
        let visible = model.visibleIndices
        let rows = Array(stride(from: visible.lowerBound, to: visible.upperBound, by: layout.columns))
        VStack(alignment: .leading, spacing: metrics.spacing) {
            ForEach(rows, id: \.self) { start in
                HStack(spacing: metrics.spacing) {
                    ForEach(start..<min(start + layout.columns, visible.upperBound), id: \.self) { index in
                        SwitcherCell(
                            item: model.items[index],
                            icon: icons[model.items[index].pid],
                            thumbnail: model.items[index].window.flatMap { thumbnails[$0.ref] },
                            isSelected: index == model.selection
                        )
                        .frame(width: metrics.cellSize.width, height: metrics.cellSize.height)
                    }
                }
            }
        }
        .padding(metrics.padding)
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }
}

/// One window: its app's icon at 64 pt with the minimized and hidden badges, and its title (or app name) on one line,
/// truncated in the middle. With a thumbnail, the window's image fills the preview area in place of the large icon,
/// with the app's icon small at its corner; the image is decorative and changes nothing Accessibility reads. A
/// windowless app's cell shows its icon and name with a dashed-window badge. The selection is a rounded highlight that
/// thickens with Increase Contrast and does not animate with Reduce Motion.
private struct SwitcherCell: View {
    let item: SwitcherItem
    let icon: NSImage?
    let thumbnail: CGImage?
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail {
                    ZStack(alignment: .bottomLeading) {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .frame(width: ThumbnailSizing.cellArea.width, height: ThumbnailSizing.cellArea.height)
                        appIcon.frame(width: 24, height: 24).offset(x: -4, y: 4)
                    }
                    .frame(width: ThumbnailSizing.cellArea.width, height: ThumbnailSizing.cellArea.height)
                } else {
                    appIcon
                        .frame(width: 64, height: 64)
                        .opacity(item.isMinimized || item.isAppHidden ? 0.6 : 1)
                }
                HStack(spacing: 2) {
                    if item.window == nil { Badge(symbol: "rectangle.dashed") }
                    if item.isMinimized { Badge(symbol: "minus") }
                    if item.isAppHidden { Badge(symbol: "eye.slash") }
                }
                .offset(x: 4, y: 4)
            }
            Text(item.displayTitle)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(increased ? 0.45 : 0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(increased ? Color.primary : Color.accentColor, lineWidth: increased ? 3 : 2)
                    )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
    }
}

extension SwitcherCell {
    private var appIcon: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "macwindow").resizable().foregroundStyle(.secondary)
            }
        }
    }
}

private struct Badge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.black.opacity(0.75)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
    }
}
