import Darwin
import Foundation
import Observation
import SystemCore
import SystemProcesses

/// The Disk section's state, testable without the UI: the scope, the scan and its progress, the volume header, the
/// Folders tab's current folder, sort, and breadcrumbs, the By origin and Suggestions tabs' groups, expansion, and
/// selection, and the unreadable-folder banner. The section only reads: nothing here deletes, moves, or runs a cleanup.
///
/// A cancelled scan keeps what it read on screen, with folders not read in full marked; origins and suggestions are
/// worked out only for a scan that finished and was not cancelled. A list longer than `rowLimit` ends in a row that
/// shows the next page, so every item can be reached, and the selection is always a listed row: a list shows as many
/// pages as reach the selected item.
@MainActor
@Observable
public final class DiskWindowModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case scanning
        /// The scan finished; origins and suggestions are being worked out.
        case analyzing
        case completed
        case cancelled
        case failed(String)
    }

    public var scope: DiskScope = .home
    /// The folder the user chose most recently, offered in the scope picker.
    public private(set) var chosenFolder: DiskScope?
    public private(set) var volumes: [DiskScope] = []
    public var tab: DiskTab = .folders {
        didSet {
            guard tab != oldValue else { return }
            selections[oldValue] = selection
            selection = selections[tab]
            rebuild()
        }
    }
    public var sortKey: DiskSortKey = .allocated {
        didSet { if sortKey != oldValue { rebuild() } }
    }
    public var selection: DiskRowID?

    public private(set) var phase: Phase = .idle
    /// Cancel was pressed and the scan is stopping.
    public private(set) var isCancelling = false
    public private(set) var progress: DiskScanProgress?
    public private(set) var volumeHeader: DiskVolumeHeader?
    public private(set) var result: DiskScanResult?
    public private(set) var analysis: DiskAnalysis?
    /// The scope of the scan shown.
    public private(set) var scannedScope: DiskScope?
    /// The Folders tab's folder, an index in the scan's tree.
    public private(set) var folder = 0
    /// The current tab's sections.
    public private(set) var sections: [DiskRowSection] = []
    /// The Folders tab's path, the scanned root first and the current folder last.
    public private(set) var breadcrumbs: [DiskBreadcrumb] = []

    public let format: UsageFormat
    /// The home folder's real path, as the scanner reports paths.
    public let home: String
    /// The rows one folder, group, or match lists at first, and how many more each Show more adds.
    public let rowLimit: Int

    @ObservationIgnored private let service: DiskScanService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var selections: [DiskTab: DiskRowID] = [:]
    @ObservationIgnored private var expanded: Set<DiskRowID> = []
    /// How many rows each list shows, by the list's key, when Show more raised it above `rowLimit`.
    @ObservationIgnored private var shown: [String: Int] = [:]

    public init(service: DiskScanService = .live, format: UsageFormat? = nil, home: String = DiskWindowModel.realHome,
                rowLimit: Int = 500) {
        self.service = service
        self.home = home
        self.format = format ?? UsageFormat(home: home)
        self.rowLimit = max(1, rowLimit)
        rebuild()
    }

    /// The home folder's real path.
    public nonisolated static var realHome: String {
        let home = NSHomeDirectory()
        guard let real = realpath(home, nil) else { return home }
        defer { free(real) }
        return String(cString: real)
    }

    // MARK: Scope and scanning

    /// Home, the chosen folder, then the mounted volumes.
    public var scopes: [DiskScope] {
        [.home] + (chosenFolder.map { [$0] } ?? []) + volumes
    }

    /// Lists the volumes mounted now. A volume selected as the scope stays selected, under its new name and mount path
    /// when `renamed` (its old and new mount paths) says it was renamed; one no longer mounted leaves Home selected.
    public func setVolumes(_ volumes: [DiskScope], renamed: (from: String, to: String)? = nil) {
        self.volumes = volumes
        guard case let .volume(_, path) = scope else { return }
        let mountPath = renamed.map { $0.from == path ? $0.to : path } ?? path
        scope = volumes.first { $0.path(home: home) == mountPath } ?? .home
    }

    /// Selects a folder from the open panel as the scope.
    public func chooseFolder(_ path: String) {
        chosenFolder = .folder(path: path)
        scope = .folder(path: path)
    }

    public var isScanning: Bool { phase == .scanning || phase == .analyzing }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Starts a scan of the current scope, replacing the results shown.
    public func scan() {
        task?.cancel()
        generation += 1
        let generation = self.generation
        let scope = self.scope
        let root = scope.path(home: home)
        phase = .scanning
        isCancelling = false
        progress = nil
        volumeHeader = nil
        result = nil
        analysis = nil
        scannedScope = scope
        folder = 0
        selection = nil
        selections = [:]
        expanded = []
        shown = [:]
        rebuild()
        let service = service
        // The header is read on its own, so cancelling the scan does not stop it.
        Task { [weak self, format] in
            let summary = await service.volume(root)
            guard let self, self.generation == generation, !self.isFailed else { return }
            volumeHeader = DiskVolumeHeader(summary, format: format)
        }
        task = Task { [weak self] in
            let scanned = await service.scan(root) { progress in
                Task { @MainActor in self?.progressed(progress, generation: generation) }
            }
            guard let self, self.generation == generation else { return }
            await finish(scanned, scope: scope, generation: generation)
        }
    }

    /// Stops the scan, keeping what it read; during analysis, or once the scan has finished reading, keeps the whole
    /// tree without origins or suggestions.
    public func cancel() {
        switch phase {
        case .scanning:
            isCancelling = true
            task?.cancel()
        case .analyzing:
            task?.cancel()
            phase = .cancelled
            rebuild()
        default:
            break
        }
    }

    private func progressed(_ progress: DiskScanProgress, generation: Int) {
        guard generation == self.generation, phase == .scanning,
              progress.items > (self.progress?.items ?? -1) else { return }
        self.progress = progress
    }

    private func finish(_ scanned: Result<DiskScanResult, DiskScanError>, scope: DiskScope, generation: Int) async {
        // Cancel may come after the scanner finished reading but before this runs: the tree is whole, and it is not
        // analyzed, since the analysis would run in the cancelled task.
        let cancelled = isCancelling || Task.isCancelled
        isCancelling = false
        let result: DiskScanResult
        switch scanned {
        case let .failure(error):
            phase = .failed(Self.message(error, format: format))
            // There is no volume to describe for a scan that did not run.
            volumeHeader = nil
            rebuild()
            return
        case let .success(value):
            result = value
        }
        self.result = result
        guard result.outcome == .completed, !cancelled else {
            phase = .cancelled
            rebuild()
            return
        }
        phase = .analyzing
        rebuild()
        let analysis = await service.analyze(result, scope == .home)
        // A cancel during analysis, or a newer scan, drops it.
        guard generation == self.generation, phase == .analyzing, let analysis else { return }
        self.analysis = analysis
        phase = .completed
        rebuild()
    }

    static func message(_ error: DiskScanError, format: UsageFormat) -> String {
        switch error {
        case let .cannotResolve(path, code):
            "\(format.path(path)) could not be opened: \(String(cString: strerror(code)))."
        case let .notADirectory(path):
            "\(format.path(path)) is not a folder."
        case let .notLocal(path, fileSystem):
            "\(format.path(path)) is on a network or other non-local volume (\(fileSystem)), which System does not scan."
        }
    }

    /// One line under the controls saying what the scan is doing or did.
    public var statusText: String {
        let place = scannedScope.map { format.path($0.path(home: home)) } ?? format.path(scope.path(home: home))
        let read = result.map { "\(format.count($0.entriesRead)) items" } ?? ""
        switch phase {
        case .idle:
            return "Choose what to scan and press Scan. Nothing is deleted from this window."
        case .scanning:
            if isCancelling { return "Stopping the scan of \(place)…" }
            guard let progress else { return "Scanning \(place)…" }
            return "Scanning \(place): \(format.count(progress.items)) items, \(format.diskBytes(progress.allocatedBytes)) so far."
        case .analyzing:
            return "Scanned \(read) in \(place). Working out origins and suggestions…"
        case .completed:
            return "Scanned \(read) in \(place)."
        case .cancelled where isTreeWhole:
            return "Scanned \(read) in \(place). Cancelled before origins and suggestions were worked out; the whole "
                + "folder tree is shown."
        case .cancelled:
            return "Scan cancelled: showing the \(read) read in \(place) before it stopped. Folders not read in full are "
                + "marked “\(DiskBadge.partial.title)”."
        case let .failed(message):
            return "The scan did not run. \(message)"
        }
    }

    /// The scan shown read everything it was asked to, even if Cancel then stopped the analysis.
    private var isTreeWhole: Bool { result?.outcome == .completed }

    /// Shown only when the scan met folders or items it could not read.
    public var unreadableBanner: DiskUnreadableBanner? {
        guard let paths = result?.unreadablePaths, !paths.isEmpty else { return nil }
        return DiskUnreadableBanner(unreadablePaths: paths, format: format)
    }

    // MARK: Folders tab

    /// Opens a folder of the Folders tab, or shows the next page of the list a Show more row ends; anything else is
    /// ignored.
    public func open(_ id: DiskRowID) {
        if case .more = id { return showMore(id) }
        guard case let .item(index) = id, let tree = result?.tree, index < tree.count, Self.isNavigable(tree[index])
        else { return }
        folder = index
        selection = nil
        rebuild()
    }

    /// Return or the right arrow: opens the selected folder in the Folders tab, expands the selected group or match
    /// in the others.
    public func openSelection() {
        guard let selection else { return }
        if tab == .folders || selection.isMore {
            open(selection)
        } else if isExpandable(selection), !expanded.contains(selection) {
            setExpanded(selection, true)
        }
    }

    /// The left arrow: goes up a folder in the Folders tab, selecting the folder left; collapses the selected group or
    /// match, or selects the one holding the selected item, in the others.
    public func closeSelection() {
        if tab == .folders {
            goUp()
            return
        }
        guard let selection else { return }
        if expanded.contains(selection) {
            setExpanded(selection, false)
        } else if let parent = Self.parent(of: selection) {
            self.selection = parent
        }
    }

    public func goUp() {
        guard tab == .folders, let tree = result?.tree, let parent = tree[folder].parent else { return }
        selection = .item(folder)
        folder = parent
        rebuild()
    }

    /// Goes to a folder on the breadcrumb path, selecting the folder below it that was open.
    public func navigate(to breadcrumb: Int) {
        guard let position = breadcrumbs.firstIndex(where: { $0.id == breadcrumb }) else { return }
        let below = breadcrumbs.indices.contains(position + 1) ? breadcrumbs[position + 1].id : nil
        folder = breadcrumb
        selection = below.map(DiskRowID.item)
        rebuild()
    }

    /// A double-click or the primary action: opens a folder or Show more row in the Folders tab, and expands or
    /// collapses a group or match, or shows more, in the others.
    public func activate(_ id: DiskRowID) {
        if tab == .folders || id.isMore {
            open(id)
        } else {
            toggle(id)
        }
    }

    /// Shows the next `rowLimit` rows of the list a Show more row ends, and selects the first of them.
    public func showMore(_ id: DiskRowID) {
        guard case let .more(list) = id, let position = sections.flatMap(\.rows).firstIndex(where: { $0.id == id })
        else { return }
        shown[list] = limit(list) + rowLimit
        rebuild()
        let rows = sections.flatMap(\.rows)
        selection = rows.indices.contains(position) ? rows[position].id : nil
    }

    private func limit(_ list: String) -> Int { shown[list] ?? rowLimit }

    /// How many of a list's rows to show: its pages, raised to the page holding the selection when that sorts later,
    /// as after going up to a parent or changing the sort.
    private func count(of ids: [DiskRowID], list: String) -> Int {
        var count = limit(list)
        if let selection, let position = ids.firstIndex(of: selection), position >= count {
            count = (position / rowLimit + 1) * rowLimit
            shown[list] = count
        }
        return count
    }

    static func isNavigable(_ item: DiskItem) -> Bool {
        item.kind == .directory && item.sizes != nil
    }

    // MARK: Groups and matches

    public func isExpanded(_ id: DiskRowID) -> Bool { expanded.contains(id) }

    public func setExpanded(_ id: DiskRowID, _ open: Bool) {
        guard isExpandable(id) else { return }
        if open {
            expanded.insert(id)
        } else {
            expanded.remove(id)
            if let selection, Self.parent(of: selection) == id { self.selection = id }
        }
        rebuild()
    }

    public func toggle(_ id: DiskRowID) {
        setExpanded(id, !expanded.contains(id))
    }

    private func isExpandable(_ id: DiskRowID) -> Bool {
        sections.lazy.flatMap(\.rows).first { $0.id == id }?.isExpandable ?? false
    }

    static func parent(of id: DiskRowID) -> DiskRowID? {
        switch id {
        case let .originItem(section, key, _): .originGroup(section, key)
        case let .matchItem(match, _): .match(match)
        default: nil
        }
    }

    /// The file a row stands for, for Reveal in Finder and Copy path.
    public func path(for id: DiskRowID) -> String? {
        sections.lazy.flatMap(\.rows).first { $0.id == id }?.path
    }

    // MARK: Rows

    private func rebuild() {
        let tree = result?.tree
        breadcrumbs = tree.map(breadcrumbs(in:)) ?? []
        switch tab {
        case .folders: sections = tree.map(folderSections(in:)) ?? [placeholder()]
        case .origins: sections = originSections()
        case .suggestions: sections = suggestionSections()
        }
        if let selection, !sections.contains(where: { $0.rows.contains { $0.id == selection } }) {
            self.selection = Self.parent(of: selection)
        }
    }

    /// The single section shown while there is nothing to list, saying why.
    private func placeholder() -> DiskRowSection {
        let note: String
        switch (phase, tab) {
        case (.idle, _): note = "No scan yet."
        case (.failed, _): note = "The scan did not run."
        case (.scanning, _): note = "Results appear when the scan finishes or is cancelled."
        case (.analyzing, _): note = "Working out origins and suggestions…"
        case (.cancelled, _) where isTreeWhole:
            note = "The scan finished reading, but was cancelled before origins and suggestions were worked out. Scan again "
                + "to see them."
        case (.cancelled, _):
            note = "The scan was cancelled before it finished, so origins and suggestions were not worked out. Scan again "
                + "to see them."
        case (.completed, .origins): note = "Nothing in this scan is in your Library folders or a developer tool's folders."
        case (.completed, _): note = "No suggestions for this scan."
        }
        return DiskRowSection(id: "placeholder", title: nil, note: note, rows: [])
    }

    private func breadcrumbs(in tree: DiskTree) -> [DiskBreadcrumb] {
        var path: [Int] = []
        var current: Int? = folder
        while let index = current {
            path.append(index)
            current = tree[index].parent
        }
        return path.reversed().map { index in
            let name = index == 0 ? format.path(tree.rootPath) : Self.name(tree[index].name)
            return DiskBreadcrumb(id: index, name: name, accessibilityLabel: "Go to \(format.path(tree.path(of: index)))")
        }
    }

    private func folderSections(in tree: DiskTree) -> [DiskRowSection] {
        let parent = tree[folder]
        let items = ordered(tree.children(of: folder))
        let largest = items.compactMap(\.sizes?.allocated).max() ?? 0
        let scale = max(parent.sizes?.allocated ?? 0, largest)
        let list = "folder-\(folder)"
        var rows = items.prefix(count(of: items.map { .item($0.index) }, list: list)).map { folderRow($0, in: tree, scale: scale) }
        if items.count > rows.count {
            rows.append(moreRow(items.count - rows.count, list: list))
        }
        return [DiskRowSection(id: "folders", title: nil, note: Self.contentsNote(parent, listed: !items.isEmpty), rows: rows)]
    }

    /// Why a folder lists less than it holds, or that it is empty; an empty list is called empty only for a folder
    /// that was read in full.
    static func contentsNote(_ folder: DiskItem, listed: Bool) -> String? {
        let flags = folder.flags
        if folder.sizes == nil {
            return "This folder could not be read, so its contents are unknown."
        } else if flags.contains(.partial) {
            return "The scan was cancelled before this folder was read in full, so it may hold more than is listed."
        } else if listed {
            return nil
        } else if flags.contains(.dataless) {
            return "This folder is stored in iCloud and not downloaded to this Mac, so its contents were not read. System "
                + "never downloads it."
        } else if flags.contains(.countedElsewhere) {
            return "This folder was reached another way during the scan, so its contents are listed and counted there, "
                + "not here."
        } else if flags.contains(.incomplete) {
            return "This folder's contents were not read (it may have been replaced while the scan ran), so they are "
                + "unknown."
        }
        return "This folder is empty."
    }

    private func ordered(_ items: [DiskItem]) -> [DiskItem] {
        func byName(_ a: DiskItem, _ b: DiskItem) -> Bool {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.index < b.index : order == .orderedAscending
        }
        let size: (DiskItem) -> UInt64? = sortKey == .private ? { $0.sizes?.private } : { $0.sizes?.allocated }
        return items.sorted { a, b in
            if sortKey == .name { return byName(a, b) }
            // Unknown sizes last.
            switch (size(a), size(b)) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return byName(a, b)
            }
        }
    }

    private func folderRow(_ item: DiskItem, in tree: DiskTree, scale: UInt64) -> DiskRow {
        let figures = DiskFigures(item.sizes, flags: item.flags, format: format)
        let name = Self.name(item.name)
        let navigable = Self.isNavigable(item)
        let detail = item.kind == .directory && item.sizes != nil
            ? "\(item.kind.title), \(format.count(item.children.count)) item\(item.children.count == 1 ? "" : "s")"
            : item.kind.title
        return DiskRow(
            id: .item(item.index), depth: 0, name: name, detail: detail, size: figures.size,
            privateSize: figures.privateSize, fraction: fraction(item.sizes?.allocated, of: scale), badges: figures.badges,
            path: tree.path(of: item.index), explanation: nil, rebuild: nil, yield: nil, isExpandable: false,
            isExpanded: false, isNavigable: navigable,
            accessibilityLabel: "\(name), \(detail)",
            accessibilityValue: figures.accessibilityValue)
    }

    private func originSections() -> [DiskRowSection] {
        guard let report = analysis?.origins, let tree = result?.tree else { return [placeholder()] }
        var sections: [DiskRowSection] = []
        for section in DiskOriginSection.allCases {
            let groups: [DiskOriginGroup] = switch section {
            case .apps: report.apps
            case .vendors: report.vendors
            case .developerTools: report.developerTools
            case .leftovers: [report.leftovers, report.unattributed].compactMap { $0 }
            }
            let scale = groups.map(\.allocated).max() ?? 0
            var rows: [DiskRow] = []
            for group in groups {
                let id = DiskRowID.originGroup(section, group.id)
                let figures = DiskFigures(allocated: group.allocated, private: group.private, lowerBound: group.isLowerBound,
                                          upperBound: group.allocatedUpperBound, format: format)
                let count = "\(format.count(group.items.count)) item\(group.items.count == 1 ? "" : "s")"
                let open = expanded.contains(id)
                var appPath: String?
                if case let .origin(.app(bundlePath)) = group.id { appPath = bundlePath }
                rows.append(DiskRow(
                    id: id, depth: 0, name: group.name, detail: count, size: figures.size, privateSize: figures.privateSize,
                    fraction: fraction(group.allocated, of: scale), badges: figures.badges, path: appPath,
                    explanation: nil, rebuild: nil, yield: nil, isExpandable: !group.items.isEmpty, isExpanded: open,
                    isNavigable: false, accessibilityLabel: "\(group.name), \(section.title), \(count)",
                    accessibilityValue: figures.accessibilityValue))
                if open {
                    rows += itemRows(group.items.map { (index: $0, path: tree.path(of: $0)) }, in: tree,
                                     id: { .originItem(section, group.id, item: $0) }, list: "\(id)")
                }
            }
            var note: String? = groups.isEmpty ? "None in this scan." : nil
            if section == .leftovers, !report.unlistedFolders.isEmpty {
                note = "Some Library folders were not listed in full, so every sum here is at least what is shown. "
                    + report.unlistedFolders.joined(separator: " ")
            }
            sections.append(DiskRowSection(id: section.rawValue, title: section.title, note: note, rows: rows))
        }
        return sections
    }

    private func suggestionSections() -> [DiskRowSection] {
        guard let matches = analysis?.matches, let tree = result?.tree else { return [placeholder()] }
        return ReclaimRisk.allCases.map { risk in
            let found = matches.enumerated().filter { $0.element.risk == risk }
                .sorted { Self.sortBytes($0.element.bytes) > Self.sortBytes($1.element.bytes) }
            let scale = found.map { Self.sortBytes($0.element.bytes) }.max() ?? 0
            var rows: [DiskRow] = []
            for (position, match) in found {
                let id = DiskRowID.match(position)
                rows.append(matchRow(match, id: id, scale: scale))
                if expanded.contains(id) {
                    rows += itemRows(match.items.map { (index: $0.index, path: $0.path) }, in: tree,
                                     id: { .matchItem(match: position, item: $0) }, list: "\(id)")
                }
            }
            let count = found.count == 1 ? "1 suggestion" : "\(found.count) suggestions"
            return DiskRowSection(id: risk.rawValue, title: "\(risk.title) (\(count))",
                                  note: found.isEmpty ? "None in this scan." : risk.note, rows: rows)
        }
    }

    private func matchRow(_ match: ReclaimMatch, id: DiskRowID, scale: Int64) -> DiskRow {
        let rule = match.rule
        let name = [rule.name, match.app?.name ?? match.identifier].compactMap { $0 }.joined(separator: ": ")
        var explanation = rule.explanation
        let figures: DiskFigures
        switch match.bytes {
        case let .scanned(privateBytes, allocated, complete, upperBound):
            figures = DiskFigures(allocated: allocated, private: privateBytes, lowerBound: !complete,
                                  upperBound: upperBound, format: format)
        case let .dockerReclaimable(upTo, _):
            figures = DiskFigures(upTo: upTo, format: format)
        case let .unavailable(reason):
            figures = DiskFigures(allocated: nil, private: nil, lowerBound: false, upperBound: false, format: format)
            explanation = "Not measured: \(reason) \(explanation)"
        }
        let count = match.items.isEmpty ? nil : "\(format.count(match.items.count)) item\(match.items.count == 1 ? "" : "s")"
        return DiskRow(
            id: id, depth: 0, name: name, detail: [rule.location, count].compactMap { $0 }.joined(separator: " · "),
            size: figures.size, privateSize: figures.privateSize,
            fraction: fraction(Self.sortBytes(match.bytes) < 0 ? nil : UInt64(Self.sortBytes(match.bytes)), of: UInt64(max(scale, 0))),
            badges: figures.badges, path: nil, explanation: explanation, rebuild: rule.rebuild, yield: rule.yield.note,
            isExpandable: !match.items.isEmpty, isExpanded: expanded.contains(id), isNavigable: false,
            accessibilityLabel: "\(name), \(match.risk.title)" + (count.map { ", \($0)" } ?? ""),
            accessibilityValue: figures.accessibilityValue)
    }

    /// The size a match is ordered by: what it uses, Docker's upper bound, or -1 when unknown.
    static func sortBytes(_ bytes: ReclaimBytes) -> Int64 {
        switch bytes {
        case let .scanned(_, allocated, _, _): Int64(clamping: allocated)
        case let .dockerReclaimable(upTo, _): Int64(clamping: upTo)
        case .unavailable: -1
        }
    }

    /// The items inside an open group or match, largest first, as many as the list shows.
    private func itemRows(_ items: [(index: Int, path: String)], in tree: DiskTree, id: (Int) -> DiskRowID,
                          list: String) -> [DiskRow] {
        let sorted = items.map { (item: tree[$0.index], path: $0.path) }
            .sorted { ($0.item.sizes?.allocated ?? 0, $1.path) > ($1.item.sizes?.allocated ?? 0, $0.path) }
        let scale = sorted.compactMap(\.item.sizes?.allocated).max() ?? 0
        var rows = sorted.prefix(count(of: sorted.map { id($0.item.index) }, list: list)).map { item, path in
            let figures = DiskFigures(item.sizes, flags: item.flags, format: format)
            let name = Self.name(item.name)
            let shown = format.path(path)
            return DiskRow(
                id: id(item.index), depth: 1, name: name, detail: shown, size: figures.size, privateSize: figures.privateSize,
                fraction: fraction(item.sizes?.allocated, of: scale), badges: figures.badges, path: path,
                explanation: nil, rebuild: nil, yield: nil, isExpandable: false, isExpanded: false, isNavigable: false,
                accessibilityLabel: "\(name), \(item.kind.title) at \(shown)", accessibilityValue: figures.accessibilityValue)
        }
        if sorted.count > rows.count { rows.append(moreRow(sorted.count - rows.count, list: list, depth: 1)) }
        return rows
    }

    /// The row ending a list that leaves `count` items out; opening it shows the next page.
    private func moreRow(_ count: Int, list: String, depth: Int = 0) -> DiskRow {
        let next = min(count, rowLimit)
        let name = "Show \(format.count(next)) more"
        let detail = "\(format.count(count)) more item\(count == 1 ? "" : "s") not listed yet; the totals include "
            + (count == 1 ? "it." : "them.")
        return DiskRow(id: .more(parent: list), depth: depth, name: name, detail: detail, size: "", privateSize: nil,
                       fraction: nil, badges: [], path: nil, explanation: nil, rebuild: nil, yield: nil,
                       isExpandable: false, isExpanded: false, isNavigable: false,
                       accessibilityLabel: "Show \(format.count(next)) more item\(next == 1 ? "" : "s")",
                       accessibilityValue: detail)
    }

    private func fraction(_ value: UInt64?, of scale: UInt64) -> Double? {
        guard let value else { return nil }
        guard scale > 0 else { return 0 }
        return min(1, Double(value) / Double(scale))
    }

    /// An item whose name did not come back is still named.
    static func name(_ name: String) -> String {
        name.isEmpty ? "Unnamed item" : name
    }
}
