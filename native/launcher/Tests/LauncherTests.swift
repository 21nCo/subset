import XCTest
@testable import Launcher

@MainActor
final class LauncherTests: XCTestCase {
    func testWindowCommandsMatchNaturalPhrases() {
        let state = LauncherAppState()
        state.selectedFilter = .all

        let titles = state.filteredResults(for: "left half").map(\.title)

        XCTAssertTrue(titles.contains("Left Half"), "\(titles)")
        XCTAssertFalse(titles.contains("Right Half"))
    }

    func testSearchOffersNoSampleProductResources() {
        let state = LauncherAppState()
        state.refreshSearchData()
        let results = state.filteredResults(for: "")
        let kinds = Set(results.map(\.kind))

        XCTAssertTrue(kinds.isSubset(of: [.app, .file, .shortcut, .window, .emoji]))
        XCTAssertFalse(results.contains { $0.title.localizedCaseInsensitiveContains("Nucleum") })
        XCTAssertFalse(SearchFilter.searchChips.map(\.rawValue).contains("Nucleum"))
    }

    func testWindowCommandQueryDoesNotHideFileFilters() {
        let state = LauncherAppState()
        state.selectedFilter = .files
        // With the Files filter, window commands are not offered and file search is not suppressed.
        XCTAssertTrue(state.filteredResults(for: "left").allSatisfy { $0.kind == .file })
    }

    func testBlankQuickNotesAreDetected() {
        XCTAssertTrue(PersistenceController.isBlankNote(title: " ", body: "\n"))
        XCTAssertFalse(PersistenceController.isBlankNote(title: "", body: "Call the venue"))
    }

    func testQuickNotesSaveFetchAndDelete() {
        let persistence = PersistenceController(inMemory: true)
        persistence.saveQuickNote(title: "  ", body: "  ")
        XCTAssertTrue(persistence.fetchRecentNotes().isEmpty, "Blank notes are not saved")

        persistence.saveQuickNote(title: "", body: "Call the venue")
        let notes = persistence.fetchRecentNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Untitled note")
        XCTAssertEqual(notes.first?.body, "Call the venue")

        persistence.delete(notes[0])
        XCTAssertTrue(persistence.fetchRecentNotes().isEmpty)
    }

    func testSystemEventsFallbackNeedsAUniqueNonEmptyTitle() {
        let unique = WindowManagementService.uniqueFallbackTitle
        XCTAssertEqual(unique("Report", ["Report", "Notes", nil]), "Report")
        XCTAssertNil(unique("Report", ["Report", "Report"]), "duplicate titles are ambiguous")
        XCTAssertNil(unique("", ["", "Notes"]), "empty titles cannot identify a window")
        XCTAssertNil(unique(nil, ["Notes"]), "unreadable titles cannot identify a window")
        XCTAssertNil(unique("Report", ["Notes"]), "the selected title must belong to an app window")
    }
}
