import Darwin
import Foundation
@testable import SystemCore
import XCTest

/// Attributes this Mac's processes as the app will: live samples, origin signals, launchd jobs, and project markers
/// on disk. Whether the groups are right for real apps, agents, and dev servers is checked on a working Mac in
/// SET-53; this checks that every live process is placed once per layer.
final class LiveAttributionTests: XCTestCase {
    func testEveryLiveProcessIsPlacedOncePerLayer() throws {
        let launchd = LaunchdJobIndex()
        launchd.refreshIfChanged()
        let plists = LaunchdFolders.live().plistFolders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".plist") }
        }
        if !plists.isEmpty {
            XCTAssertFalse(launchd.jobs.isEmpty && launchd.unreadablePlists.isEmpty && launchd.scanFailures.isEmpty,
                           "the index read the \(plists.count) job plists")
        }
        var sampler = Sampler(source: LibprocProcessSource(), origin: OriginSignalReader.live())
        _ = try sampler.sample()
        let processes = try sampler.sample().processes

        let result = Attribution().attribute(processes, launchdJobs: launchd.jobs)

        XCTAssertEqual(result.processes.count, Set(processes.map(\.identity)).count)
        for layer in AttributionLayer.allCases {
            let members = result.groups(layer).flatMap(\.members)
            XCTAssertEqual(members.count, result.processes.count, "\(layer)")
            XCTAssertEqual(Set(members).count, members.count, "\(layer): a process is in one group")
            XCTAssertTrue(result.groups(layer).allSatisfy { $0.id.layer == layer && $0.totals.processCount == $0.members.count })
        }
        let mine = try XCTUnwrap(result.processes.first { $0.identity.pid == getpid() })
        XCTAssertNotEqual(mine.launchSource.rule, .parentNotSampled, "the test runner's parents are sampled")
    }
}
