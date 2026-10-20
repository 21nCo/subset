import CoreGraphics

/// The switcher grid's fixed sizes, in points.
public struct SwitcherMetrics: Sendable, Equatable {
    /// One cell: the 64 pt app icon, its badges, and one line of title, with room for the selection highlight.
    public var cellSize: CGSize
    public var spacing: CGFloat
    /// Between the panel's edge and the grid.
    public var padding: CGFloat
    /// At most this many rows show at once; the rest scroll.
    public var maxVisibleRows: Int
    /// The share of the screen's usable width and height the panel may take.
    public var screenFraction: CGFloat

    public init(cellSize: CGSize, spacing: CGFloat, padding: CGFloat, maxVisibleRows: Int, screenFraction: CGFloat) {
        self.cellSize = cellSize
        self.spacing = spacing
        self.padding = padding
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.screenFraction = screenFraction
    }

    public static let standard = SwitcherMetrics(
        cellSize: CGSize(width: 152, height: 112),
        spacing: 8,
        padding: 16,
        maxVisibleRows: 5,
        screenFraction: 0.9
    )
}

/// Where each window's cell goes: as many columns as fit the screen's width, filled row by row in list order, with at
/// most `metrics.maxVisibleRows` rows (fewer if the screen is short) visible at once. The last row may be shorter
/// (ragged) and is aligned to the leading edge. Positions are in the panel's coordinates, origin at its top left.
public struct SwitcherLayout: Sendable, Equatable {
    public let count: Int
    public let columns: Int
    public let rows: Int
    public let visibleRows: Int
    public let metrics: SwitcherMetrics

    /// Lays out `count` cells for a screen whose usable area (without the menu bar and Dock) is `available`.
    public init(count: Int, available: CGSize, metrics: SwitcherMetrics = .standard) {
        self.count = max(0, count)
        self.metrics = metrics
        let pitch = CGSize(width: metrics.cellSize.width + metrics.spacing, height: metrics.cellSize.height + metrics.spacing)
        let width = available.width * metrics.screenFraction - 2 * metrics.padding + metrics.spacing
        let height = available.height * metrics.screenFraction - 2 * metrics.padding + metrics.spacing
        let fittingColumns = Int(max(1, (width / pitch.width).rounded(.down)))
        let fittingRows = Int(max(1, (height / pitch.height).rounded(.down)))
        columns = max(1, min(self.count, fittingColumns))
        rows = (self.count + columns - 1) / columns
        visibleRows = min(rows, metrics.maxVisibleRows, fittingRows)
    }

    /// The grid's size with its padding: the visible rows only.
    public var size: CGSize {
        let visibleColumns = CGFloat(columns)
        let shownRows = CGFloat(max(visibleRows, 1))
        return CGSize(
            width: visibleColumns * metrics.cellSize.width + (visibleColumns - 1) * metrics.spacing + 2 * metrics.padding,
            height: shownRows * metrics.cellSize.height + (shownRows - 1) * metrics.spacing + 2 * metrics.padding
        )
    }

    public func row(of index: Int) -> Int { index / columns }
    public func column(of index: Int) -> Int { index % columns }

    /// The index ↑ or ↓ moves to from `index`: the same column in the next row, or the last cell when the next row is
    /// the ragged last row and stops short of that column. Past the first or last row it wraps to the other end, as
    /// steps do. With a single row it stays put.
    public func index(moving direction: RowDirection, from index: Int) -> Int {
        guard rows > 1, (0..<count).contains(index) else { return index }
        let row = row(of: index)
        let target: Int = switch direction {
        case .down: row == rows - 1 ? column(of: index) : index + columns
        case .up: row == 0 ? (rows - 1) * columns + column(of: index) : index - columns
        }
        return min(target, count - 1)
    }

    /// The first visible row after the least scrolling from `current` that shows the row of `index`.
    public func firstVisibleRow(showing index: Int, from current: Int) -> Int {
        let row = row(of: index)
        var first = current
        if row < first { first = row }
        if row >= first + visibleRows { first = row - visibleRows + 1 }
        return clampedFirstRow(first)
    }

    /// `first` kept within the rows that can be scrolled to.
    public func clampedFirstRow(_ first: Int) -> Int {
        min(max(0, first), max(0, rows - visibleRows))
    }

    /// The indices of the cells in the visible rows.
    public func visibleIndices(firstVisibleRow first: Int) -> Range<Int> {
        let start = min(count, first * columns)
        return start..<min(count, (first + visibleRows) * columns)
    }

    /// The cell's frame, or nil when its row is scrolled out of view.
    public func frame(of index: Int, firstVisibleRow first: Int) -> CGRect? {
        guard visibleIndices(firstVisibleRow: first).contains(index) else { return nil }
        return CGRect(
            x: metrics.padding + CGFloat(column(of: index)) * (metrics.cellSize.width + metrics.spacing),
            y: metrics.padding + CGFloat(row(of: index) - first) * (metrics.cellSize.height + metrics.spacing),
            width: metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    }

    /// The visible cell under `point`, or nil over padding, spacing, or an empty place in the last row.
    public func index(at point: CGPoint, firstVisibleRow first: Int) -> Int? {
        let x = point.x - metrics.padding
        let y = point.y - metrics.padding
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / (metrics.cellSize.width + metrics.spacing))
        let row = Int(y / (metrics.cellSize.height + metrics.spacing))
        guard column < columns, row < visibleRows else { return nil }
        let index = (first + row) * columns + column
        guard let frame = frame(of: index, firstVisibleRow: first), frame.contains(point) else { return nil }
        return index
    }
}
