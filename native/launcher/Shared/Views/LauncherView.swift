import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var appState: LauncherAppState
    @FocusState private var isInputFocused: Bool
    @FocusState private var isNoteDetailsFocused: Bool
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var selectedIndex = 0
    @State private var shouldScrollSelectionIntoView = false
    @State private var keyMonitor: Any?

    private var results: [SearchResult] {
        appState.filteredResults(for: appState.query)
    }

    private var selectedResult: SearchResult? {
        guard appState.mode == .search, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    private let emojiColumns = Array(repeating: GridItem(.flexible(minimum: 54, maximum: 72), spacing: 8), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            header

            if appState.mode == .quickNote {
                quickNoteBody
            } else {
                resultsBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            // Each show() builds a new view in the requested mode, so focus whichever field it has.
            focusSearchField()
            focusNoteTitleField()
            selectedIndex = 0
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: appState.query) { _, _ in
            selectedIndex = 0
            appState.scheduleFileSearch(for: appState.query)
        }
        .onChange(of: appState.selectedFilter) { _, _ in
            selectedIndex = 0
            appState.scheduleFileSearch(for: appState.query)
            focusSearchField()
        }
        .onChange(of: appState.mode) { _, newMode in
            if newMode == .quickNote {
                focusNoteTitleField()
            } else {
                focusSearchField()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if appState.mode == .quickNote {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 32)
            } else {
                LauncherSMark(size: 28)
                    .frame(width: 32)
            }

            if appState.mode == .quickNote {
                TextField("Note title", text: $noteTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .medium))
                    .focused($isInputFocused)
                    .onSubmit {
                        isNoteDetailsFocused = true
                    }
            } else {
                TextField("Search apps, files, shortcuts, and window commands", text: $appState.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .medium))
                    .focused($isInputFocused)
                    .onSubmit {
                        submit()
                    }
                    .accessibilityLabel("Launcher search")
            }

            if appState.mode == .quickNote {
                Button("Save") {
                    saveNote()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Save note (⌘↩)")
            } else {
                Text("⌥Space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }

            Button {
                appState.closeLauncher()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close Launcher")
        }
        .padding(20)
    }

    private var resultsBody: some View {
        VStack(spacing: 0) {
            Divider()

            if appState.selectedFilter != .emoji, appState.selectedFilter != .calculator {
                searchFilterBar
            }

            if appState.selectedFilter == .emoji {
                emojiGridBody
            } else if appState.selectedFilter == .calculator {
                calculatorBody
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label(appState.query.isEmpty ? "Nothing to Show" : "No Results", systemImage: "magnifyingglass")
                } description: {
                    Text(emptyStateHint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        List(Array(results.enumerated()), id: \.element.id) { index, result in
                            SearchResultRow(result: result, isSelected: selectedIndex == index)
                                .contentShape(Rectangle())
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .listRowSeparator(.hidden)
                                .onTapGesture {
                                    selectedIndex = index
                                    open(result)
                                }
                                .onHover { isHovering in
                                    if isHovering {
                                        shouldScrollSelectionIntoView = false
                                        selectedIndex = index
                                    }
                                }
                                .id(result.id)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onChange(of: selectedIndex) { _, newIndex in
                            if shouldScrollSelectionIntoView, results.indices.contains(newIndex) {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    proxy.scrollTo(results[newIndex].id, anchor: .center)
                                }
                                shouldScrollSelectionIntoView = false
                            }
                        }
                        .onMoveCommand { direction in
                            shouldScrollSelectionIntoView = true
                            switch direction {
                            case .down:
                                selectedIndex = min(selectedIndex + 1, max(results.count - 1, 0))
                            case .up:
                                selectedIndex = max(selectedIndex - 1, 0)
                            default:
                                break
                            }
                        }
                    }

                    if let selectedResult, selectedResult.isImageFile {
                        Divider()
                        ResultPreview(result: selectedResult, appState: appState)
                    }
                }
            }

            actionBar
        }
    }

    private var emptyStateHint: String {
        if appState.selectedFilter != .all {
            return "Nothing matches in \(appState.selectedFilter.rawValue). Choose All to widen the search."
        }
        return "Try an app or file name, a window command such as \u{201C}left half\u{201D}, or type $ and press Return to write a quick note."
    }

    /// Raycast-style footer: the primary action for the selection plus the secondary keys.
    private var actionBar: some View {
        HStack(spacing: 14) {
            bottomToolDock
            Spacer()
            if let result = selectedResult {
                keyHint(primaryActionTitle(for: result), "↵")
                if result.kind == .app || result.kind == .file {
                    keyHint("Show in Finder", "⌘↵")
                }
            }
            keyHint("Close", "esc")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func keyHint(_ title: String, _ key: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(key)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityElement(children: .combine)
    }

    private func primaryActionTitle(for result: SearchResult) -> String {
        switch result.kind {
        case .app: return "Open Application"
        case .file: return "Open File"
        case .shortcut: return "Run Shortcut"
        case .emoji: return "Copy Emoji"
        case .window: return "Apply to Window"
        }
    }

    private var searchFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.searchChips) { filter in
                    Button {
                        appState.selectedFilter = filter
                        selectedIndex = 0
                        focusSearchField()
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(appState.selectedFilter == filter ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(appState.selectedFilter == filter ? Color.accentColor : Color.black.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Search \(filter.rawValue)")
                    .accessibilityAddTraits(appState.selectedFilter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var emojiGridBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Results")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: emojiColumns, spacing: 8) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button {
                                selectedIndex = index
                                appState.copy(result)
                            } label: {
                                Text(result.title)
                                    .font(.system(size: 25))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 64)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.black.opacity(selectedIndex == index ? 0.18 : 0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedIndex == index ? Color.white.opacity(0.9) : Color.clear, lineWidth: 1.4)
                                    )
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovering in
                                if isHovering {
                                    shouldScrollSelectionIntoView = false
                                    selectedIndex = index
                                }
                            }
                            .id(result.id)
                            .help(result.subtitle)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    if shouldScrollSelectionIntoView, results.indices.contains(newIndex) {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(results[newIndex].id, anchor: .center)
                        }
                        shouldScrollSelectionIntoView = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calculatorBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calculator")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text(appState.query.isEmpty ? "Enter an expression" : appState.query)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(calculatorDisplay.inputCaption)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .padding(.vertical, 10)

                VStack(spacing: 10) {
                    Text(calculatorDisplay.result)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(calculatorDisplay.resultCaption)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 126)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomToolDock: some View {
        HStack(spacing: 12) {
            bottomToolButton(filter: .all, icon: "magnifyingglass", title: "All Search")
            bottomToolButton(filter: .emoji, icon: "face.smiling", title: "Emoji Picker")
            bottomToolButton(filter: .calculator, icon: "plus.forwardslash.minus", title: "Calculator")
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.bottom, 12)
    }

    private func bottomToolButton(filter: SearchFilter, icon: String, title: String) -> some View {
        Button {
            appState.selectedFilter = filter
            selectedIndex = 0
            focusSearchField()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(appState.selectedFilter == filter ? .white : .secondary)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(appState.selectedFilter == filter ? Color.white.opacity(0.18) : Color.black.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(appState.selectedFilter == filter ? Color.white.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(appState.selectedFilter == filter ? .isSelected : [])
    }

    private var calculatorDisplay: CalculatorDisplay {
        let expression = appState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else {
            return CalculatorDisplay(inputCaption: "Expression", result: "--", resultCaption: "Result")
        }

        if let conversion = TimeConversionCalculator.evaluate(expression) {
            return CalculatorDisplay(
                inputCaption: conversion.inputCaption,
                result: conversion.result,
                resultCaption: conversion.resultCaption
            )
        }

        guard let value = SimpleCalculator.evaluate(expression) else {
            return CalculatorDisplay(inputCaption: "Expression", result: "No result", resultCaption: "Result")
        }

        return CalculatorDisplay(
            inputCaption: "Expression",
            result: value.formatted(.number.precision(.fractionLength(0...4))),
            resultCaption: "Result"
        )
    }

    private var quickNoteBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()

            ZStack(alignment: .topLeading) {
                if noteBody.isEmpty {
                    Text("Note details")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                }

                TextEditor(text: $noteBody)
                    .font(.system(size: 18))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .focused($isNoteDetailsFocused)
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                if let noteSaveError = appState.noteSaveError {
                    Text(noteSaveError)
                        .foregroundStyle(.red)
                } else {
                    Text("Saved locally. Open them from the menu bar: Quick Notes…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("⌘↵ save · esc cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .bottom], 20)
    }

    private func submit() {
        if appState.mode == .quickNote {
            saveNote()
        } else if appState.query.trimmingCharacters(in: .whitespacesAndNewlines) == "$" {
            openQuickNoteFromSearchCommand()
        } else if results.indices.contains(selectedIndex) {
            open(results[selectedIndex])
        }
    }

    private func openQuickNoteFromSearchCommand() {
        noteTitle = ""
        noteBody = ""
        appState.query = ""
        appState.mode = .quickNote
        focusNoteTitleField()
    }

    private func saveNote() {
        // Keep the draft and the composer open if the store rejected the note.
        guard appState.saveQuickNote(title: noteTitle, body: noteBody) else { return }
        noteTitle = ""
        noteBody = ""
        appState.closeLauncher()
    }

    private func open(_ result: SearchResult) {
        appState.closeLauncher()
        appState.open(result)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The monitor can outlive a hidden panel; never intercept keys for other windows.
            guard appState.isLauncherOpen, event.window?.isKeyWindow == true, event.window is NSPanel else {
                return event
            }

            // Esc closes from any mode, like Raycast and Alfred.
            if event.keyCode == 53 {
                appState.closeLauncher()
                return nil
            }

            guard appState.mode == .search else {
                return event
            }

            // ⌘↵ reveals the selected app or file in Finder.
            if event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command] {
                if let result = selectedResult, result.kind == .app || result.kind == .file {
                    appState.closeLauncher()
                    appState.reveal(result)
                }
                return nil
            }

            switch event.keyCode {
            case 125:
                moveSelection(delta: appState.selectedFilter == .emoji ? 8 : 1)
                return nil
            case 126:
                moveSelection(delta: appState.selectedFilter == .emoji ? -8 : -1)
                return nil
            case 123:
                guard appState.selectedFilter == .emoji else {
                    return event
                }
                moveSelection(delta: -1)
                return nil
            case 124:
                guard appState.selectedFilter == .emoji else {
                    return event
                }
                moveSelection(delta: 1)
                return nil
            case 36, 76:
                submit()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func moveSelection(delta: Int) {
        guard !results.isEmpty else { return }
        shouldScrollSelectionIntoView = true
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    private func focusSearchField() {
        guard appState.mode == .search else { return }
        DispatchQueue.main.async {
            isInputFocused = true
        }
    }

    private func focusNoteTitleField() {
        guard appState.mode == .quickNote else { return }
        DispatchQueue.main.async {
            isInputFocused = true
        }
    }
}

private struct CalculatorDisplay {
    let inputCaption: String
    let result: String
    let resultCaption: String
}

private enum TimeConversionCalculator {
    struct Conversion {
        let inputCaption: String
        let result: String
        let resultCaption: String
    }

    private struct DestinationTimeZone {
        let identifier: String
        let displayName: String
    }

    private static let destinationTimeZones = buildDestinationTimeZones()

    static func evaluate(_ query: String) -> Conversion? {
        guard let request = parse(query),
              let destination = destinationTimeZones[lookupKey(for: request.destination)],
              let destinationTimeZone = TimeZone(identifier: destination.identifier) else {
            return nil
        }

        let sourceTimeZone = TimeZone.current
        var calendar = Calendar.current
        calendar.timeZone = sourceTimeZone

        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = request.hour
        components.minute = request.minute
        components.second = 0

        guard let sourceDate = calendar.date(from: components) else {
            return nil
        }

        let inputFormatter = DateFormatter()
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")
        inputFormatter.timeZone = sourceTimeZone
        inputFormatter.dateFormat = "h:mm a"

        let resultFormatter = DateFormatter()
        resultFormatter.locale = Locale(identifier: "en_US_POSIX")
        resultFormatter.timeZone = destinationTimeZone
        resultFormatter.dateFormat = "h:mm a"

        // Say when the destination time falls on another calendar day.
        var destinationCalendar = Calendar(identifier: .gregorian)
        destinationCalendar.timeZone = destinationTimeZone
        // Both sides use Gregorian components; `Calendar.current` may be Buddhist, Japanese, etc.
        var sourceDayCalendar = Calendar(identifier: .gregorian)
        sourceDayCalendar.timeZone = sourceTimeZone
        var dayCalendar = Calendar(identifier: .gregorian)
        dayCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let sourceDay = dayCalendar.date(from: sourceDayCalendar.dateComponents([.year, .month, .day], from: sourceDate))
        let destinationDay = dayCalendar.date(from: destinationCalendar.dateComponents([.year, .month, .day], from: sourceDate))
        let dayOffset = sourceDay.flatMap { source in
            destinationDay.flatMap { dayCalendar.dateComponents([.day], from: source, to: $0).day }
        } ?? 0
        let daySuffix = dayOffset > 0 ? " (next day)" : dayOffset < 0 ? " (previous day)" : ""

        return Conversion(
            inputCaption: "\(inputFormatter.string(from: sourceDate)) \(friendlyName(for: sourceTimeZone))",
            result: resultFormatter.string(from: sourceDate) + daySuffix,
            resultCaption: "\(destination.displayName), \(destinationTimeZone.abbreviation(for: sourceDate) ?? destination.identifier)"
        )
    }

    private static func buildDestinationTimeZones() -> [String: DestinationTimeZone] {
        var index: [String: DestinationTimeZone] = [:]

        func add(_ name: String, identifier: String, displayName: String? = nil, replace: Bool = false) {
            let key = lookupKey(for: name)
            guard !key.isEmpty, TimeZone(identifier: identifier) != nil else {
                return
            }

            if replace || index[key] == nil {
                index[key] = DestinationTimeZone(
                    identifier: identifier,
                    displayName: displayName ?? name.displayLocationName
                )
            }
        }

        add("UTC", identifier: "UTC", displayName: "UTC", replace: true)
        add("GMT", identifier: "GMT", displayName: "GMT", replace: true)

        for identifier in TimeZone.knownTimeZoneIdentifiers {
            let parts = identifier.split(separator: "/").map(String.init)
            let cityName = parts.last?.replacingOccurrences(of: "_", with: " ") ?? identifier
            let displayName = cityName.displayLocationName
            add(cityName, identifier: identifier, displayName: displayName)
            add(identifier.replacingOccurrences(of: "_", with: " "), identifier: identifier, displayName: displayName)
        }

        addCountriesFromSystemTimeZoneDatabase(to: &index)

        [
            "us": "America/New_York",
            "usa": "America/New_York",
            "united states": "America/New_York",
            "america": "America/New_York",
            "uk": "Europe/London",
            "uae": "Asia/Dubai",
            "pakistan": "Asia/Karachi",
            "islamabad": "Asia/Karachi",
            "lahore": "Asia/Karachi",
            "karachi": "Asia/Karachi",
            "india": "Asia/Kolkata",
            "delhi": "Asia/Kolkata",
            "mumbai": "Asia/Kolkata",
            "hyderabad": "Asia/Kolkata",
            "bangalore": "Asia/Kolkata",
            "bengaluru": "Asia/Kolkata",
            "nyc": "America/New_York",
            "new york": "America/New_York",
            "boston": "America/New_York",
            "sf": "America/Los_Angeles",
            "san francisco": "America/Los_Angeles",
            "la": "America/Los_Angeles",
            "los angeles": "America/Los_Angeles"
        ].forEach { name, identifier in
            add(name, identifier: identifier, displayName: name.displayLocationName, replace: true)
        }

        return index
    }

    private static func addCountriesFromSystemTimeZoneDatabase(to index: inout [String: DestinationTimeZone]) {
        let possiblePaths = [
            "/usr/share/zoneinfo/zone1970.tab",
            "/var/db/timezone/zoneinfo/zone1970.tab",
            "/usr/share/zoneinfo/zone.tab",
            "/var/db/timezone/zoneinfo/zone.tab"
        ]

        guard let path = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return
        }

        let locale = Locale(identifier: "en_US")

        func add(_ name: String, identifier: String) {
            let key = lookupKey(for: name)
            guard !key.isEmpty, index[key] == nil else {
                return
            }

            index[key] = DestinationTimeZone(identifier: identifier, displayName: name.displayLocationName)
        }

        for line in contents.split(separator: "\n") {
            guard !line.hasPrefix("#") else {
                continue
            }

            let columns = line.split(separator: "\t")
            guard columns.count >= 3 else {
                continue
            }

            let regionCodes = columns[0].split(separator: ",").map(String.init)
            let identifier = String(columns[2])
            guard TimeZone(identifier: identifier) != nil else {
                continue
            }

            for regionCode in regionCodes {
                add(regionCode, identifier: identifier)
                if let countryName = locale.localizedString(forRegionCode: regionCode) {
                    add(countryName, identifier: identifier)
                }
            }
        }
    }

    private static func parse(_ query: String) -> (hour: Int, minute: Int, destination: String)? {
        let normalized = query
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pattern = #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s+(?:(?:here|now)\s+)?(?:in|to)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let hourRange = Range(match.range(at: 1), in: normalized),
              let meridiemRange = Range(match.range(at: 3), in: normalized),
              let destinationRange = Range(match.range(at: 4), in: normalized),
              var hour = Int(normalized[hourRange]) else {
            return nil
        }

        let minute: Int
        if let minuteRange = Range(match.range(at: 2), in: normalized) {
            minute = Int(normalized[minuteRange]) ?? 0
        } else {
            minute = 0
        }

        guard (1...12).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        let meridiem = String(normalized[meridiemRange])
        if meridiem == "pm", hour != 12 {
            hour += 12
        } else if meridiem == "am", hour == 12 {
            hour = 0
        }

        let destination = normalized[destinationRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (hour, minute, String(destination))
    }

    private static func friendlyName(for timeZone: TimeZone) -> String {
        guard let lastComponent = timeZone.identifier.split(separator: "/").last else {
            return timeZone.identifier
        }
        return String(lastComponent).replacingOccurrences(of: "_", with: " ")
    }

    private static func lookupKey(for value: String) -> String {
        value
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var displayLocationName: String {
        split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

private struct ResultPreview: View {
    let result: SearchResult
    @ObservedObject var appState: LauncherAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let url = result.url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Text(result.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            Button {
                appState.copy(result)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)

            Spacer()
        }
        .padding(14)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.kind.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .blue)
                .frame(width: 34, height: 34)
                .background(isSelected ? Color.white.opacity(0.18) : Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(result.kind.rawValue)
                .font(.caption)
                .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.title), \(result.kind.rawValue)")
        .accessibilityValue(result.subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private enum SimpleCalculator {
    static func evaluate(_ expression: String) -> Double? {
        var parser = Parser(expression)
        return parser.parse()
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(_ expression: String) {
            characters = Array(
                expression
                    .replacingOccurrences(of: "×", with: "*")
                    .replacingOccurrences(of: "÷", with: "/")
                    .filter { !$0.isWhitespace }
            )
        }

        mutating func parse() -> Double? {
            guard !characters.isEmpty, let value = parseExpression(), index == characters.count else {
                return nil
            }
            return value.isFinite ? value : nil
        }

        private mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }

            while let operatorCharacter = peek(), operatorCharacter == "+" || operatorCharacter == "-" {
                advance()
                guard let nextValue = parseTerm() else { return nil }

                if operatorCharacter == "+" {
                    value += nextValue
                } else {
                    value -= nextValue
                }
            }

            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }

            while let operatorCharacter = peek(), operatorCharacter == "*" || operatorCharacter == "/" {
                advance()
                guard let nextValue = parseFactor() else { return nil }

                if operatorCharacter == "*" {
                    value *= nextValue
                } else {
                    guard nextValue != 0 else { return nil }
                    value /= nextValue
                }
            }

            return value
        }

        private mutating func parseFactor() -> Double? {
            if match("+") {
                return parseFactor()
            }

            if match("-") {
                return parseFactor().map { -$0 }
            }

            if match("(") {
                guard let value = parseExpression(), match(")") else { return nil }
                return value
            }

            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            let start = index
            var hasDecimalPoint = false

            while let character = peek() {
                if character.isNumber {
                    advance()
                } else if character == ".", !hasDecimalPoint {
                    hasDecimalPoint = true
                    advance()
                } else {
                    break
                }
            }

            guard start != index else { return nil }
            return Double(String(characters[start..<index]))
        }

        private func peek() -> Character? {
            guard index < characters.count else { return nil }
            return characters[index]
        }

        private mutating func advance() {
            index += 1
        }

        private mutating func match(_ character: Character) -> Bool {
            guard peek() == character else { return false }
            advance()
            return true
        }
    }
}
