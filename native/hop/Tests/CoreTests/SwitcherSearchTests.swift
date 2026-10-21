import CoreGraphics
import HopCore
import XCTest

/// A window of `app` (pid by app name, so one app's windows share it) titled `title`, with ref `ref`.
private func window(_ ref: UInt64, _ title: String, app: String, pid: pid_t? = nil) -> SwitcherItem {
    let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    return .window(WindowEntry(
        app: SourceApp(pid: pid ?? pid_t(1000 + ref), bundleIdentifier: "com.example.\(ref)", name: app),
        window: SourceWindow(ref: WindowRef(rawValue: ref), title: title, subrole: "AXStandardWindow", frame: frame),
        frame: frame,
        display: 1
    ))
}

private let wide = CGSize(width: 1440, height: 900)

final class SwitcherSearchTests: XCTestCase {
    private func titles(_ items: [SwitcherItem]) -> [String] { items.map(\.displayTitle) }

    // MARK: - Rules

    func testAppNamePrefix() {
        XCTAssertEqual(SwitcherSearch.rule(matching: "saf", window(1, "Apple", app: "Safari")), .appNamePrefix)
    }

    func testWordPrefixInTheTitleOrTheAppName() {
        XCTAssertEqual(SwitcherSearch.rule(matching: "rep", window(1, "Q3 report.pdf", app: "Preview")), .wordPrefix)
        XCTAssertEqual(SwitcherSearch.rule(matching: "rep", window(2, "Q3-report", app: "Preview")), .wordPrefix,
                       "punctuation starts a word")
        XCTAssertEqual(SwitcherSearch.rule(matching: "code", window(3, "main.swift", app: "Visual Studio Code")), .wordPrefix,
                       "a later word of the app's name")
    }

    func testSubstringInTheTitleOrTheAppName() {
        XCTAssertEqual(SwitcherSearch.rule(matching: "port", window(1, "Q3 report", app: "Preview")), .substring)
        XCTAssertEqual(SwitcherSearch.rule(matching: "afar", window(2, "Start Page", app: "Safari")), .substring)
    }

    func testNoRuleNoMatch() {
        XCTAssertNil(SwitcherSearch.rule(matching: "xyz", window(1, "Q3 report", app: "Preview")))
        XCTAssertNil(SwitcherSearch.rule(matching: "rpt", window(1, "Q3 report", app: "Preview")), "no fuzzy matching")
        XCTAssertNil(SwitcherSearch.rule(matching: "repo rt", window(1, "Q3 report", app: "Preview")), "no typo tolerance")
    }

    func testCaseAndDiacriticsAreIgnoredByEveryRule() {
        XCTAssertEqual(SwitcherSearch.rule(matching: "e", window(1, "x", app: "Éditeur")), .appNamePrefix)
        XCTAssertEqual(SwitcherSearch.rule(matching: "cafe", window(2, "Le Café", app: "Notes")), .wordPrefix)
        XCTAssertEqual(SwitcherSearch.rule(matching: "afe", window(3, "Café", app: "Notes")), .substring)
        XCTAssertEqual(SwitcherSearch.rule(matching: "É", window(4, "resume", app: "Pages")), .substring,
                       "an accented query matches the plain letter")
        XCTAssertEqual(SwitcherSearch.rule(matching: "MAIL", window(5, "Inbox", app: "Mail")), .appNamePrefix)
    }

    func testAnAppCellMatchesByItsAppName() {
        let notes = SwitcherItem.app(AppEntry(SourceApp(pid: 7, bundleIdentifier: "com.apple.Notes", name: "Notes")))
        XCTAssertEqual(SwitcherSearch.rule(matching: "no", notes), .appNamePrefix)
        XCTAssertEqual(SwitcherSearch.rule(matching: "tes", notes), .substring)
    }

    func testAnEmptyTitleMatchesOnlyByTheAppName() {
        XCTAssertEqual(SwitcherSearch.rule(matching: "fin", window(1, "", app: "Finder")), .appNamePrefix)
        XCTAssertNil(SwitcherSearch.rule(matching: "doc", window(1, "", app: "Finder")))
    }

    // MARK: - Ranking

    func testBetterRulesComeFirstAndTiesKeepRecencyOrder() {
        let items = [
            window(1, "Notes on safety", app: "TextEdit"), // word prefix
            window(2, "unsafe.txt", app: "TextEdit"),       // substring
            window(3, "Start Page", app: "Safari"),          // app name prefix
            window(4, "Inbox", app: "Mail"),                // no match
            window(5, "Bookmarks", app: "Safari"),           // app name prefix, older than 3
            window(6, "Safe mode", app: "Terminal"),         // word prefix, older than 1
        ]
        XCTAssertEqual(titles(SwitcherSearch.matches("saf", in: items)), [
            "Start Page", "Bookmarks", "Notes on safety", "Safe mode", "unsafe.txt",
        ])
    }

    func testAnEmptyQueryListsEverythingInOrder() {
        let items = [window(1, "B", app: "B"), window(2, "A", app: "A")]
        XCTAssertEqual(SwitcherSearch.matches("", in: items), items)
    }

    func testSearchCharacters() {
        for character: Character in ["a", "Z", "é", "1", " ", "-", "`", "ß", "α"] {
            XCTAssertTrue(SwitcherSearch.isSearchCharacter(character), "\(character)")
        }
        // Tab, Return, Esc, Delete, an arrow key's private-use character, and a format character.
        for character: Character in ["\t", "\r", "\u{1B}", "\u{7F}", "\u{F700}", "\u{200B}"] {
            XCTAssertFalse(SwitcherSearch.isSearchCharacter(character), "\(character.unicodeScalars.first!.value)")
        }
    }
}

/// Typing into an open switcher, and the same-app scope.
final class SwitcherViewModelSearchTests: XCTestCase {
    private let items = [
        window(0, "Front", app: "Xcode"),
        window(1, "Q3 report", app: "Preview"),
        window(2, "Inbox", app: "Mail"),
        window(3, "Report draft", app: "Pages"),
        window(4, "Release notes", app: "Notes"),
    ]

    private func typing(_ text: String, into model: inout SwitcherViewModel) {
        for character in text { model.handle(.type(character)) }
    }

    func testTypingNarrowsTheListAndSelectsTheFirstMatch() {
        var model = SwitcherViewModel(items: items, available: wide)
        XCTAssertEqual(model.selection, 1)
        typing("re", into: &model)
        XCTAssertEqual(model.query, "re")
        XCTAssertEqual(model.items.map(\.displayTitle), ["Q3 report", "Report draft", "Release notes"])
        XCTAssertEqual(model.selection, 0, "the first match, not the previous window")
        model.handle(.step(.forward))
        XCTAssertEqual(model.selection, 1)
        typing("p", into: &model)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Q3 report", "Report draft"])
        XCTAssertEqual(model.selection, 0, "each change to the query selects the first match again")
        XCTAssertEqual(model.layout.count, 2)
    }

    func testDeleteRemovesTheLastCharacterAndWidensTheList() {
        var model = SwitcherViewModel(items: items, available: wide)
        typing("rep", into: &model)
        XCTAssertEqual(model.items.count, 2)
        model.handle(.deleteBackward)
        XCTAssertEqual(model.query, "re")
        XCTAssertEqual(model.items.count, 3)
        model.handle(.deleteBackward)
        model.handle(.deleteBackward)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.items, items, "an empty query lists everything in recency order")
        XCTAssertEqual(model.selection, 0)
        model.handle(.step(.forward))
        model.handle(.deleteBackward)
        XCTAssertEqual(model.selection, 1, "Delete with nothing typed changes nothing")
    }

    func testNoMatchesListsNothingAndSaysSo() {
        var model = SwitcherViewModel(items: items, available: wide)
        XCTAssertNil(model.emptyText)
        typing("zz", into: &model)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.selectedItem, "a commit has nothing to focus")
        XCTAssertEqual(model.emptyText, "No matching windows")
        XCTAssertNil(model.handle(.operation(.close)))
        XCTAssertEqual(SwitcherViewModel(items: [], available: wide).emptyText, "No windows")
    }

    func testARefreshWhileSearchingKeepsTheQueryAndTheSelection() {
        var model = SwitcherViewModel(items: items, available: wide)
        typing("re", into: &model)
        model.handle(.step(.forward)) // Report draft
        model.refreshed([items[3], items[0], items[2], items[4]]) // Q3 report closed; Report draft now most recent
        XCTAssertEqual(model.items.map(\.displayTitle), ["Report draft", "Release notes"])
        XCTAssertEqual(model.selectedItem?.displayTitle, "Report draft")
    }

    func testAFilterChangeWhileSearchingKeepsWindowsThatDoNotMatch() {
        var model = SwitcherViewModel(items: items, available: wide, filter: .showingEverything)
        typing("re", into: &model)
        var filter = SwitcherFilter.showingEverything
        filter.excludedApps = ["com.example.4"]
        model.apply(filter)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Q3 report", "Report draft"])
        model.handle(.deleteBackward)
        model.handle(.deleteBackward)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Front", "Q3 report", "Inbox", "Report draft"],
                       "windows the search hid when the filter changed come back")
    }

    func testAnOperationWhileSearchingKeepsWindowsThatDoNotMatch() {
        var model = SwitcherViewModel(items: items, available: wide)
        typing("re", into: &model)
        let request = model.handle(.operation(.minimize))!
        XCTAssertEqual(request.item.displayTitle, "Q3 report")
        model.finished(request, result: .windowGone)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Report draft", "Release notes"])
        model.handle(.deleteBackward)
        model.handle(.deleteBackward)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Front", "Inbox", "Report draft", "Release notes"])
    }

    func testAnEndedSearchDropsTheQueryAndListsOnlyWhatItListed() {
        var model = SwitcherViewModel(items: items, available: wide)
        typing("re", into: &model)
        model.handle(.step(.forward)) // Report draft
        model.endSearch()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.items.map(\.displayTitle), ["Q3 report", "Report draft", "Release notes"])
        XCTAssertEqual(model.selectedItem?.displayTitle, "Report draft")
        model.refreshed([items[0], items[1], window(5, "Recent", app: "Numbers"), items[2], items[4]])
        XCTAssertEqual(model.items.map(\.displayTitle), ["Q3 report", "Release notes"],
                       "a new window that would have matched is not listed")
        XCTAssertEqual(model.selectedItem?.displayTitle, "Release notes", "the closed window's follower")
        model.refreshed([items[0], window(5, "Recent", app: "Numbers")])
        XCTAssertNil(model.selectedItem, "nothing it listed is left to commit")
    }

    func testEndingASearchWithoutAQueryChangesNothing() {
        var model = SwitcherViewModel(items: items, available: wide)
        let before = model
        model.endSearch()
        XCTAssertEqual(model, before)
    }

    /// Recency C, A, B; "saf" ranks the Safari windows first: A, B, C.
    private let safari = [
        window(10, "Safe guide", app: "TextEdit"),
        window(11, "Docs", app: "Safari"),
        window(12, "News", app: "Safari"),
    ]

    func testAnEndedSearchKeepsTheOrderItListed() {
        var model = SwitcherViewModel(items: safari, available: wide)
        typing("saf", into: &model)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Docs", "News", "Safe guide"])
        model.handle(.step(.forward)) // News
        model.endSearch()
        model.refreshed([safari[2], safari[0], safari[1]])
        XCTAssertEqual(model.items.map(\.displayTitle), ["Docs", "News", "Safe guide"], "a read does not reorder it")
        model.refreshed([safari[0], safari[1]])
        XCTAssertEqual(model.selectedItem?.displayTitle, "Safe guide", "the follower in the order it listed")
        model.handle(.type("d"))
        model.handle(.deleteBackward)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Docs", "Safe guide"], "an ended search takes no more keys")
        XCTAssertEqual(model.selectedItem?.displayTitle, "Safe guide")
    }

    func testWhileHeldAReadNeitherAddsToNorReordersASearchsList() {
        let newer = window(13, "Safe house", app: "Safari")
        var model = SwitcherViewModel(items: safari, available: wide)
        typing("saf", into: &model)
        model.hold()
        model.refreshed([newer, safari[1], safari[0], safari[2]])
        XCTAssertEqual(model.items.map(\.displayTitle), ["Docs", "News", "Safe guide"])
        typing("e", into: &model)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Safe guide"], "a waiting key searches only what was listed")
        model.handle(.deleteBackward)
        XCTAssertEqual(model.items.map(\.displayTitle), ["Docs", "News", "Safe guide"])
        model.stopHolding()
        XCTAssertEqual(model.items.map(\.displayTitle), ["Safe house", "Docs", "News", "Safe guide"],
                       "once nothing waits, a match the read added is listed")
    }

    func testAHeldSearchThatListedNothingListsNothingAfterARead() {
        var model = SwitcherViewModel(items: items, available: wide)
        typing("zz", into: &model)
        model.hold()
        model.refreshed(items + [window(5, "zz notes", app: "Notes")])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.handle(.operation(.close)), "a waiting ⌘W has nothing to act on")
        model.stopHolding()
        XCTAssertEqual(model.items.map(\.displayTitle), ["zz notes"])
        XCTAssertEqual(model.selection, 0)
    }

    func testHoldingWithoutAQueryListsAsUsual() {
        var model = SwitcherViewModel(items: items, available: wide)
        model.hold()
        model.refreshed([window(5, "New", app: "Numbers")] + items)
        XCTAssertEqual(model.items.count, 6)
        XCTAssertEqual(model.selectedItem?.displayTitle, "Q3 report")
    }

    // MARK: - Same-app scope

    private func appWindows(_ count: Int, pid: pid_t) -> [SwitcherItem] {
        (0..<count).map { window(UInt64(10 + $0), "Doc \($0)", app: "Pages", pid: pid) }
    }

    func testTheSameAppScopeWithNoWindows() {
        let others = [window(0, "Inbox", app: "Mail"), window(1, "Start", app: "Safari")]
        let model = SwitcherViewModel(items: others, available: wide, scope: .appWindows(42))
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.emptyText, "No windows")
        XCTAssertTrue(SwitcherViewModel(items: others, available: wide, scope: .appWindows(nil)).items.isEmpty,
                      "no frontmost app lists nothing")
    }

    func testTheSameAppScopeWithOneWindowSelectsIt() {
        let pages = appWindows(1, pid: 42)
        let model = SwitcherViewModel(items: [window(0, "Inbox", app: "Mail")] + pages, available: wide, scope: .appWindows(42))
        XCTAssertEqual(model.items, pages)
        XCTAssertEqual(model.selection, 0)
    }

    func testTheSameAppScopeWithThreeWindowsSelectsTheAppsSecondMostRecent() {
        let pages = appWindows(3, pid: 42)
        let mixed = [pages[0], window(0, "Inbox", app: "Mail"), pages[1], window(1, "Start", app: "Safari"), pages[2]]
        var model = SwitcherViewModel(items: mixed, available: wide, scope: .appWindows(42))
        XCTAssertEqual(model.items, pages, "only the app's windows, in recency order")
        XCTAssertEqual(model.selectedItem, pages[1])
        model.handle(.step(.forward))
        model.handle(.step(.forward))
        XCTAssertEqual(model.selectedItem, pages[0], "stepping wraps within the app")
        model.refreshed(mixed + [window(9, "New", app: "Mail")])
        XCTAssertEqual(model.items, pages, "a refresh keeps the scope")
    }

    func testTheSameAppScopeHasNoAppCells() {
        let pages = appWindows(2, pid: 42)
        let cell = SwitcherItem.app(AppEntry(SourceApp(pid: 42, bundleIdentifier: "com.apple.iWork.Pages", name: "Pages")))
        let model = SwitcherViewModel(items: pages + [cell], available: wide, scope: .appWindows(42))
        XCTAssertEqual(model.items, pages)
    }

    func testSearchingWithinTheSameAppScope() {
        let pages = appWindows(3, pid: 42)
        var model = SwitcherViewModel(items: pages + [window(0, "Doc in Mail", app: "Mail")], available: wide,
                                      scope: .appWindows(42))
        typing("doc 2", into: &model)
        XCTAssertEqual(model.items, [pages[2]])
    }
}
