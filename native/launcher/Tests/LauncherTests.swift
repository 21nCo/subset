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
        let kinds = Set(state.filteredResults(for: "").map(\.kind))

        XCTAssertTrue(kinds.isSubset(of: [.app, .file, .shortcut, .window, .emoji]))
        XCTAssertFalse(SearchFilter.searchChips.map(\.rawValue).contains("Nucleum"))
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
}
