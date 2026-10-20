import Foundation
import SystemCore
import SystemProcesses
import XCTest

/// The System window's view model without the UI: layers, selection, sorting, filtering, restricted counts, the
/// footnote, sampling state, the detail pane, keyboard expansion, and the menu bar's top groups.
@MainActor
final class ProcessesWindowModelTests: XCTestCase {
    private let chromeGroup = OriginGroupID(.app(bundlePath: ProcessFixtures.chrome))
    private let googleVendor = OriginGroupID(.vendor(teamID: "EQHXZ8M8AV"))
    private let agentGroup = OriginGroupID(.agent(name: "claude"))
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func model(_ processes: [FixtureProcess] = ProcessFixtures.workload()) throws -> ProcessesWindowModel {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        model.apply(try ProcessFixtures.sample(processes, observedAt: t0), memory: nil, cadence: .mainWindowVisible)
        return model
    }

    private func names(_ model: ProcessesWindowModel) -> [String] { model.rows.map(\.name) }

    // MARK: Layers and selection

    func testSwitchingLayersRestoresEachLayersSelectionWhileItsGroupStillExists() throws {
        let model = try model()
        model.selection = .group(chromeGroup)

        model.layer = .vendor
        XCTAssertNil(model.selection, "the App group is not in the Vendor layer, and Vendor had no selection")
        model.selection = .group(googleVendor)

        model.layer = .app
        XCTAssertEqual(model.selection, .group(chromeGroup))

        // A new sample in which both groups still exist keeps them.
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload(), observedAt: t0 + 2), memory: nil, cadence: .mainWindowVisible)
        XCTAssertEqual(model.selection, .group(chromeGroup))
        model.layer = .vendor
        XCTAssertEqual(model.selection, .group(googleVendor))

        // Chrome quits: the Vendor selection is cleared at once, and the App layer's is not restored.
        let withoutChrome = ProcessFixtures.workload().filter { ![100, 101, 102].contains($0.pid) }
        model.apply(try ProcessFixtures.sample(withoutChrome, observedAt: t0 + 4), memory: nil, cadence: .mainWindowVisible)
        XCTAssertNil(model.selection)
        model.layer = .app
        XCTAssertNil(model.selection)
    }

    func testASelectedProcessStaysSelectedAcrossLayersAndItsGroupOpens() throws {
        let model = try model()
        model.selection = .process(ProcessFixtures.identity(203))

        model.layer = .vendor
        XCTAssertEqual(model.selection, .process(ProcessFixtures.identity(203)))
        XCTAssertTrue(model.rows.contains { $0.id == .process(ProcessFixtures.identity(203)) }, "node's Unsigned group opened")

        model.layer = .project
        XCTAssertTrue(model.rows.contains { $0.id == .process(ProcessFixtures.identity(203)) })
    }

    func testASelectedProcessThatExitsLeavesItsGroupSelected() throws {
        let model = try model()
        model.selection = .process(ProcessFixtures.identity(101))

        let withoutRenderer = ProcessFixtures.workload().filter { $0.pid != 101 }
        model.apply(try ProcessFixtures.sample(withoutRenderer, observedAt: t0 + 2), memory: nil, cadence: .mainWindowVisible)

        XCTAssertEqual(model.selection, .group(chromeGroup))
    }

    // MARK: Sorting

    func testSortingPutsTheLargestFirstAndUnmeasuredGroupsLast() throws {
        let model = try model()

        model.sortKey = .memory
        XCTAssertEqual(names(model), ["Google Chrome", "Agent: claude", "Ghostty", "macOS", "Terminal"])
        model.sortKey = .cpu
        XCTAssertEqual(names(model), ["Agent: claude", "Google Chrome", "Ghostty", "macOS", "Terminal"])
        model.sortKey = .energy
        XCTAssertEqual(names(model), ["Agent: claude", "Google Chrome", "Ghostty", "macOS", "Terminal"])

        // Within a group, processes follow the same order; a restricted process sorts after every measured one.
        model.sortKey = .memory
        model.toggle(OriginGroupID(.macOS))
        let macOS = model.rows.drop { $0.name != "macOS" }.dropFirst().prefix(3)
        XCTAssertEqual(macOS.map(\.id), [.process(ProcessFixtures.identity(300)), .process(ProcessFixtures.identity(400)),
                                        .process(ProcessFixtures.identity(401))])
    }

    func testAGroupWithNoMeasuredMemoryIsListedAfterMeasuredOnesNotAsZero() throws {
        let model = try model([
            FixtureProcess(pid: 400, path: "/usr/libexec/a", restricted: true, signature: ProcessFixtures.apple),
            FixtureProcess(pid: 500, path: "/Users/me/bin/tool", memory: 1 << 20, signature: ProcessFixtures.unsigned)
        ])

        XCTAssertEqual(names(model), ["/Users/me/bin/tool", "macOS"])
        XCTAssertEqual(model.rows.last?.memory, "–")
        XCTAssertEqual(model.rows.last?.restrictedCount, 1)
    }

    // MARK: Filtering

    func testFilteringByNameShowsMatchingGroupsAndOpensGroupsForMatchingProcesses() throws {
        let model = try model()

        model.filter = "chrome"
        XCTAssertEqual(names(model), ["Google Chrome"], "a group whose name matches is shown as it was, closed")
        model.toggle(chromeGroup)
        XCTAssertEqual(model.rows.count, 4, "and opening it shows all its processes")

        model.filter = "node"
        XCTAssertEqual(names(model), ["Agent: claude", "subset", "node"],
                       "a group shown for a matching process opens to it, through its subgroup, and shows nothing else")

        model.setExpanded(agentGroup, false)
        XCTAssertEqual(names(model), ["Agent: claude"], "a group the filter opened can be closed")

        model.filter = "no such process"
        XCTAssertEqual(model.rows, [])

        model.filter = ""
        XCTAssertEqual(model.rows.count, 5 + 3, "clearing the filter keeps Chrome open and leaves the agent closed")
    }

    // MARK: Restricted processes and the footnote

    func testRestrictedProcessesAreCountedSeparatelyAndNeverShownAsZero() throws {
        let model = try model()
        let macOS = try XCTUnwrap(model.rows.first { $0.name == "macOS" })

        XCTAssertEqual(macOS.restrictedCount, 2)
        XCTAssertEqual(macOS.detail, "3 processes · 2 restricted")
        XCTAssertTrue(macOS.accessibilityValue.contains("2 of 3 processes not measured"), macOS.accessibilityValue)
        XCTAssertTrue(macOS.accessibilityValue.hasSuffix("2 restricted by macOS"), macOS.accessibilityValue)

        model.toggle(OriginGroupID(.macOS))
        let restricted = try XCTUnwrap(model.rows.first { $0.id == .process(ProcessFixtures.identity(400)) })
        XCTAssertEqual([restricted.cpu, restricted.memory, restricted.energy], ["Restricted", "Restricted", "Restricted"])
        XCTAssertEqual(restricted.accessibilityValue, "Usage restricted by macOS")

        XCTAssertEqual(model.header(now: t0).processText, "10 processes · 2 restricted by macOS")
        model.selection = .group(OriginGroupID(.macOS))
        XCTAssertEqual(model.detail?.fields.first { $0.label == "Restricted" }?.value, "2: usage unknown, left out of totals")
    }

    func testTheApproximateMemoryFootnoteIsShownWithEverySample() throws {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        XCTAssertNil(model.footnote, "nothing is measured yet")

        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload(), observedAt: t0), memory: nil, cadence: .mainWindowVisible)

        let footnote = try XCTUnwrap(model.footnote)
        XCTAssertTrue(footnote.hasPrefix("Memory totals are approximate: memory shared between processes is counted once for each process."))
        XCTAssertTrue(footnote.contains("2 processes are restricted by macOS"), footnote)
        XCTAssertTrue(footnote.contains("not counted as zero"), footnote)
        XCTAssertTrue(model.rows.allSatisfy { $0.memory.hasPrefix("≈") || $0.memory == "–" }, "group memory is marked approximate")

        let unrestricted = try self.model(ProcessFixtures.workload().filter { !$0.restricted })
        XCTAssertEqual(unrestricted.footnote,
                       "Memory totals are approximate: memory shared between processes is counted once for each process.")
    }

    // MARK: Sampling state

    func testTheHeaderMarksTheSampleStaleOnceTheSamplerPauses() throws {
        let model = try model()

        XCTAssertEqual(model.header(now: t0 + 5).state, .live(interval: .seconds(2)))
        XCTAssertEqual(model.header(now: t0).observedText, "Observed at \(ProcessFixtures.format.time(t0))")

        // No sample for more than three 2-second intervals: the figures are no longer called current.
        let stale = model.header(now: t0 + 7)
        XCTAssertEqual(stale.state, .stale(age: .seconds(7), failure: nil))
        XCTAssertEqual(stale.stateText, "Stale: no sample for 7 s; figures are from the last sample")
        XCTAssertFalse(model.rows.isEmpty, "the last figures stay on screen")

        // With only the menu bar in use, the sampler runs every 10 seconds, so 25 seconds is still current.
        model.setCadence(.menuBarOnly)
        XCTAssertEqual(model.header(now: t0 + 25).state, .live(interval: .seconds(10)))

        model.applyFailure("Could not list processes: listFailed(1)", memory: nil, at: t0 + 26, cadence: .menuBarOnly)
        let failed = model.header(now: t0 + 27)
        XCTAssertEqual(failed.state, .failed("Could not list processes: listFailed(1)"))
        XCTAssertEqual(failed.cpuText, "CPU: unavailable, sampling failed · 8 logical cores")

        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload(), observedAt: t0 + 30), memory: nil, cadence: .mainWindowVisible)
        XCTAssertEqual(model.header(now: t0 + 31).state, .live(interval: .seconds(2)))
    }

    func testOpeningTheWindowDoesNotCallAMenuBarSampleStale() throws {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload(), observedAt: t0), memory: nil, cadence: .menuBarOnly)

        // The window opens 8 s after a 10-second menu-bar sample; the next one may still be up to 10 s away.
        model.setCadence(.mainWindowVisible)
        XCTAssertEqual(model.header(now: t0 + 8).state, .live(interval: .seconds(2)))
        XCTAssertEqual(model.header(now: t0 + 31).state, .stale(age: .seconds(31), failure: nil))

        // Once a sample at the window's cadence arrives, three missed 2-second intervals are stale again.
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload(), observedAt: t0 + 10), memory: nil, cadence: .mainWindowVisible)
        XCTAssertEqual(model.header(now: t0 + 17).state, .stale(age: .seconds(7), failure: nil))
    }

    func testAFailedSampleSaysWhichFiguresAreFromTheLastGoodSample() throws {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload(), observedAt: t0),
                    memory: ProcessFixtures.memory(level: 1, physical: 8 << 30), cadence: .mainWindowVisible)

        // The process list fails, but the memory read in the same sample succeeds and is shown.
        let message = "Could not list processes: listFailed(1)"
        model.applyFailure(message, memory: ProcessFixtures.memory(level: 4, physical: 16 << 30), at: t0 + 2,
                           cadence: .mainWindowVisible)
        let header = model.header(now: t0 + 4)
        XCTAssertEqual(header.pressureText, "Memory pressure: Critical")
        XCTAssertTrue(header.memoryText.hasSuffix("of \(ProcessFixtures.format.bytes(16 << 30)) · App – · Compressed –"),
                      header.memoryText)
        XCTAssertEqual(header.stateText, "Sampling failed: Could not list processes: listFailed(1); process figures are "
            + "from the sample observed at \(ProcessFixtures.format.time(t0)); memory figures are current")
        XCTAssertEqual(header.processText, "10 processes · 2 restricted by macOS")

        // The sampler then pauses: neither the processes nor the memory are called current, and each says when it
        // was observed.
        let paused = model.header(now: t0 + 60)
        XCTAssertEqual(paused.state, .stale(age: .seconds(58), failure: message))
        XCTAssertEqual(paused.stateText, "Stale: no sample attempted for 58 s; the last one failed: \(message); process "
            + "figures are from the sample observed at \(ProcessFixtures.format.time(t0)); memory figures are from "
            + "\(ProcessFixtures.format.time(t0 + 2))")
        XCTAssertFalse(paused.stateText.contains("current"), paused.stateText)

        // Failures that keep reading memory keep it current, while the processes stay on the last good sample.
        model.applyFailure(message, memory: ProcessFixtures.memory(level: 2, physical: 16 << 30), at: t0 + 62,
                           cadence: .mainWindowVisible)
        model.applyFailure(message, memory: ProcessFixtures.memory(level: 2, physical: 16 << 30), at: t0 + 64,
                           cadence: .mainWindowVisible)
        let repeated = model.header(now: t0 + 65)
        XCTAssertEqual(repeated.state, .failed(message))
        XCTAssertEqual(repeated.stateText, "Sampling failed: \(message); process figures are from the sample observed at "
            + "\(ProcessFixtures.format.time(t0)); memory figures are current")

        let first = ProcessesWindowModel(format: ProcessFixtures.format)
        first.applyFailure(message, memory: nil, at: t0, cadence: .mainWindowVisible)
        XCTAssertEqual(first.header(now: t0).stateText, "Sampling failed: Could not list processes: listFailed(1)")
        XCTAssertEqual(first.header(now: t0 + 7).state, .stale(age: .seconds(7), failure: message),
                       "a failure before the first good sample also goes stale once the sampler pauses")
    }

    func testBeforeTheFirstSampleTheHeaderIsWaiting() {
        let header = ProcessesWindowModel(format: ProcessFixtures.format, logicalCoreCount: 12).header(now: t0)

        XCTAssertEqual(header.state, .waiting)
        XCTAssertEqual(header.processText, "No processes sampled yet")
        XCTAssertEqual(header.cpuText, "CPU: not measured yet · 12 logical cores")
    }

    // MARK: Detail and keyboard

    func testTheDetailPaneSaysWhyAProcessIsInItsGroup() throws {
        let model = try model()

        model.selection = .process(ProcessFixtures.identity(101))
        let renderer = try XCTUnwrap(model.detail?.placement)
        XCTAssertEqual(renderer.group, "Google Chrome")
        XCTAssertEqual(renderer.confidence, .rule)
        XCTAssertEqual(renderer.evidence, ["Inside `Google Chrome.app`"])
        let fields = Dictionary(uniqueKeysWithValues: try XCTUnwrap(model.detail).fields.map { ($0.label, $0.value) })
        XCTAssertEqual(fields["Team ID"], "EQHXZ8M8AV")
        XCTAssertEqual(fields["launchd label"], "None identified")
        XCTAssertEqual(fields["Restricted"], "No")
        XCTAssertEqual(fields["Parent"], "Google Chrome, pid 100")
        XCTAssertEqual(model.detail?.path, model.path(for: .process(ProcessFixtures.identity(101))))

        model.selection = .process(ProcessFixtures.identity(203))
        XCTAssertEqual(model.detail?.placement?.group, "Agent: claude › subset")
        XCTAssertEqual(model.detail?.placement?.evidence.first, "Child of claude (pid 202) in ~/dev/subset")

        model.layer = .project
        XCTAssertEqual(model.detail?.placement?.evidence, ["Working directory ~/dev/subset", "`.git` in ~/dev/subset"])

        model.selection = .process(ProcessFixtures.identity(400))
        model.layer = .app
        let restricted = Dictionary(uniqueKeysWithValues: try XCTUnwrap(model.detail).fields.map { ($0.label, $0.value) })
        XCTAssertEqual(restricted["Restricted"], "Yes: macOS denied reading its usage")
        XCTAssertEqual(restricted["Memory"], "Restricted")
        XCTAssertEqual(restricted["Team ID"], "None (Apple platform binary)")
    }

    func testGroupPathsAreOfferedOnlyForAFileOrFolder() throws {
        let model = try model()

        XCTAssertEqual(model.path(for: .group(chromeGroup)), ProcessFixtures.chrome)
        XCTAssertNil(model.path(for: .group(OriginGroupID(.macOS))))
        XCTAssertEqual(model.path(for: .group(OriginGroupID(.agent(name: "claude"), subgroup: "/Users/me/dev/subset"))),
                       "/Users/me/dev/subset")
    }

    func testLeftAndRightArrowsCollapseAndExpand() throws {
        let model = try model()
        model.selection = .group(agentGroup)

        model.expandSelection()
        XCTAssertTrue(model.isExpanded(agentGroup))
        let subgroup = OriginGroupID(.agent(name: "claude"), subgroup: "/Users/me/dev/subset")
        model.selection = .group(subgroup)
        model.expandSelection()
        model.selection = .process(ProcessFixtures.identity(203))

        model.collapseSelection()
        XCTAssertEqual(model.selection, .group(subgroup), "Left on a process selects the group it is in")
        model.collapseSelection()
        XCTAssertFalse(model.isExpanded(subgroup))
        model.collapseSelection()
        XCTAssertEqual(model.selection, .group(agentGroup))
        model.collapseSelection()
        XCTAssertFalse(model.isExpanded(agentGroup))
        XCTAssertEqual(model.rows.count, 5)
    }

    func testTheLaunchdLabelSaysWhenTheScanCouldNotIdentifyAJob() throws {
        let failure = LaunchdScanFailure(path: "/Library/LaunchDaemons/locked.plist", code: EACCES)
        let tool = "/Users/me/bin/tool"
        let job = LaunchdJob(label: "dev.me.tool", plistPath: "/Users/me/Library/LaunchAgents/dev.me.tool.plist",
                             domain: .userAgent, program: tool, resolution: .resolved(tool))
        let processes = [
            FixtureProcess(pid: 500, path: tool, memory: 1 << 20, signature: ProcessFixtures.unsigned),
            FixtureProcess(pid: 501, path: "/Users/me/bin/other", memory: 1 << 20, signature: ProcessFixtures.unsigned)
        ]
        func label(_ pid: Int32, _ sample: ProcessesSample) throws -> String? {
            let model = ProcessesWindowModel(format: ProcessFixtures.format)
            model.apply(sample, memory: nil, cadence: .mainWindowVisible)
            model.selection = .process(ProcessFixtures.identity(pid))
            return try XCTUnwrap(model.detail).fields.first { $0.label == "launchd label" }?.value
        }

        let complete = try ProcessFixtures.sample(processes, launchdJobs: [tool: [job]])
        XCTAssertEqual(try label(500, complete), "dev.me.tool")
        XCTAssertEqual(try label(501, complete), "None identified", "every plist was read and none names it")

        let incomplete = try ProcessFixtures.sample(processes, launchdJobs: [tool: [job]], launchdScanFailures: [failure])
        let partial = try XCTUnwrap(try label(500, incomplete))
        XCTAssertTrue(partial.hasPrefix("None identified; the scan is incomplete"), partial)
        XCTAssertTrue(partial.contains("/Library/LaunchDaemons/locked.plist (\(failure.reason))"), partial)
        let unread = try XCTUnwrap(try label(501, incomplete))
        XCTAssertEqual(unread, "Unavailable: \(SignalFailure.incompleteScan([failure]).reason)")
    }

    func testTheSelectionStaysOnAShownRow() throws {
        let model = try model()
        let subgroup = OriginGroupID(.agent(name: "claude"), subgroup: "/Users/me/dev/subset")
        let node = RowID.process(ProcessFixtures.identity(203))
        func shown() -> Bool { model.selection.map { selection in model.rows.contains { $0.id == selection } } ?? true }

        // Closing a group holding the selection selects the group.
        model.setExpanded(agentGroup, true)
        model.setExpanded(subgroup, true)
        model.selection = node
        model.toggle(agentGroup)
        XCTAssertEqual(model.selection, .group(agentGroup))
        XCTAssertTrue(shown())

        // A filter that hides the selection moves it to the shown group holding it, or clears it.
        model.toggle(agentGroup)
        model.selection = node
        model.filter = "2.1.304"
        XCTAssertEqual(model.selection, .group(subgroup), "the filter shows claude but not node in their subgroup")
        XCTAssertTrue(shown())
        model.filter = "chrome"
        XCTAssertNil(model.selection, "nothing holding the selection is shown")
        model.filter = ""

        // A sample that moves the selected process into a closed group opens that group to it.
        let tool = FixtureProcess(pid: 500, path: "/Users/me/bin/tool", memory: 1 << 20, signature: ProcessFixtures.unsigned)
        var adopted = tool
        adopted.ppid = 202
        adopted.cwd = "/Users/me/dev/subset"
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload() + [tool], observedAt: t0 + 2), memory: nil,
                    cadence: .mainWindowVisible)
        model.setExpanded(OriginGroupID(.unattributed(executable: "/Users/me/bin/tool")), true)
        model.selection = .process(ProcessFixtures.identity(500))
        XCTAssertTrue(shown())
        model.setExpanded(agentGroup, false)
        model.setExpanded(subgroup, false)
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload() + [adopted], observedAt: t0 + 4), memory: nil,
                    cadence: .mainWindowVisible)
        XCTAssertEqual(model.selection, .process(ProcessFixtures.identity(500)))
        XCTAssertEqual(model.detail?.placement?.group, "Agent: claude › subset")
        XCTAssertTrue(shown(), "the process's new group and subgroup opened")
        XCTAssertTrue(model.isExpanded(agentGroup) && model.isExpanded(subgroup))
    }

    // MARK: Menu bar

    func testTheMenuBarListsTheThreeLargestAppGroupsAndOpensTheWindowOnOne() throws {
        let sample = try ProcessFixtures.sample(ProcessFixtures.workload())
        let top = TopGroups(attribution: sample.attribution, samplingFailed: false, format: ProcessFixtures.format)

        XCTAssertEqual(top.entries.map(\.id), [chromeGroup, agentGroup, OriginGroupID(.app(bundlePath: ProcessFixtures.ghostty))])
        XCTAssertTrue(top.entries[0].title.hasPrefix("Google Chrome — ≈"), top.entries[0].title)
        XCTAssertNil(top.placeholder)
        XCTAssertEqual(TopGroups(attribution: nil, samplingFailed: false).placeholder, "Top memory: not measured yet")
        XCTAssertEqual(TopGroups(attribution: sample.attribution, samplingFailed: true).entries, [])

        let model = try model()
        model.layer = .project
        model.filter = "node"
        model.reveal(top.entries[0].id)
        XCTAssertEqual(model.layer, .app)
        XCTAssertEqual(model.selection, .group(chromeGroup))
        XCTAssertEqual(model.filter, "", "a filter hiding the group is cleared")
        XCTAssertTrue(model.rows.contains { $0.id == .group(chromeGroup) })
    }

    func testRevealingAGroupGoneFromTheSampleKeepsTheSelectionAndFilter() throws {
        let model = try model()
        model.filter = "node"
        model.selection = .process(ProcessFixtures.identity(203))
        model.layer = .project

        // The menu showed this app before it quit; the window has a newer sample without it.
        model.reveal(OriginGroupID(.app(bundlePath: "/Applications/Gone.app")))
        XCTAssertEqual(model.layer, .app)
        XCTAssertEqual(model.selection, .process(ProcessFixtures.identity(203)))
        XCTAssertEqual(model.filter, "node", "a filter is cleared only to show a group that exists")
    }

    func testTheMenusTopGroupRowsStandStillWhileTheMenuIsOpen() throws {
        let first = TopGroups(attribution: try ProcessFixtures.sample(ProcessFixtures.workload()).attribution,
                              samplingFailed: false, format: ProcessFixtures.format)
        let second = TopGroups(attribution: try ProcessFixtures.sample(ProcessFixtures.workload(chromeMemory: 1 << 20)).attribution,
                               samplingFailed: false, format: ProcessFixtures.format)
        XCTAssertNotEqual(first, second)
        var menu = TopGroupsMenuState()
        XCTAssertEqual(menu.slots.count, 3)
        XCTAssertTrue(menu.slots.allSatisfy { $0 == nil })

        XCTAssertTrue(menu.receive(first))
        XCTAssertEqual(menu.slots.map { $0?.id }, first.entries.map(\.id))

        // A sample arriving while the menu is open leaves every row on the group it shows, so a click opens that one.
        XCTAssertFalse(menu.menuWillOpen())
        XCTAssertFalse(menu.receive(second))
        XCTAssertEqual(menu.slots.map { $0?.id }, first.entries.map(\.id))
        menu.menuDidClose()
        XCTAssertEqual(menu.shown, first, "the chosen item's action may run after the menu closes")

        // It is shown the next time the menu opens, or at once with the next sample while closed.
        XCTAssertTrue(menu.menuWillOpen())
        XCTAssertEqual(menu.shown, second)
        menu.menuDidClose()
        let failed = TopGroups(attribution: nil, samplingFailed: true)
        XCTAssertTrue(menu.receive(failed))
        XCTAssertEqual(menu.slots.count, 3, "the rows stay; unused ones are hidden")
        XCTAssertTrue(menu.slots.allSatisfy { $0 == nil })
        XCTAssertFalse(menu.menuWillOpen(), "a set shown while closed is not applied again")
    }
}
