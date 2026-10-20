import Foundation
import SystemCore
import XCTest

/// Volume summaries from recorded resource values and `tmutil` output, plus one live read of this Mac's volume.
final class VolumeSummaryTests: XCTestCase {
    private let recorded = VolumeCapacityValues(mountPoint: "/", name: "Macintosh HD", capacity: 494_384_795_648,
                                                availableForImportantUsage: 122_749_105_289, available: 115_729_567_744)

    func testPurgeableIsTheDifferenceBetweenTheTwoAvailableFigures() {
        let summary = VolumeSummary(values: recorded, snapshots: .count(0))
        XCTAssertEqual(summary.capacity, 494_384_795_648)
        XCTAssertEqual(summary.availableForImportantUsage, 122_749_105_289)
        XCTAssertEqual(summary.available, 115_729_567_744)
        XCTAssertEqual(summary.purgeable, 7_019_537_545)
        XCTAssertNil(summary.snapshotBytes)
    }

    func testPurgeableIsUnavailableWhenAFigureIsMissingOrSmaller() {
        var missing = recorded
        missing.availableForImportantUsage = nil
        XCTAssertNil(VolumeSummary(values: missing, snapshots: .count(0)).purgeable)
        var smaller = recorded
        smaller.availableForImportantUsage = 100
        XCTAssertNil(VolumeSummary(values: smaller, snapshots: .count(0)).purgeable)
        var equal = recorded
        equal.availableForImportantUsage = equal.available
        XCTAssertEqual(VolumeSummary(values: equal, snapshots: .count(0)).purgeable, 0)
    }

    func testCountsTimeMachineSnapshots() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-19-083012.local
        com.apple.TimeMachine.2026-10-20-093544.local

        """
        XCTAssertEqual(LocalSnapshots(tmutilOutput: output), .count(2))
        // tmutil carries a second heading for a volume group.
        let group = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-10-19-083012.local
        com.apple.TimeMachine.2026-10-20-093544.local

        """
        XCTAssertEqual(LocalSnapshots(tmutilOutput: group), .count(2))
        // A list without a heading counts too.
        XCTAssertEqual(LocalSnapshots(tmutilOutput: "com.apple.TimeMachine.2021-01-01-000000.local\n"), .count(1))
    }

    func testNoSnapshotsIsZeroNotUnavailable() {
        XCTAssertEqual(LocalSnapshots(tmutilOutput: "Snapshots for disk /:\n"), .count(0))
        XCTAssertEqual(LocalSnapshots(tmutilOutput: "Snapshots for volume group containing disk /:\n"), .count(0))
        XCTAssertEqual(LocalSnapshots(tmutilOutput: ""), .count(0))
    }

    func testUnrecognizedOutputIsUnavailable() {
        for output in ["Snapshots for disk /:\nSomething went wrong\n",
                       "Snapshots for volume group containing disk /:\nSomething went wrong\n",
                       "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-093544.local\nSnapshots unavailable\n"] {
            guard case .unavailable = LocalSnapshots(tmutilOutput: output) else {
                return XCTFail("an unrecognized line was counted: \(output)")
            }
        }
    }

    func testRunsTmutilOnTheMountPointAndReportsItsFailures() async {
        let runner = RecordingRunner(result: .success(CommandOutput(
            status: 0, stdout: Data("Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-101010.local\n".utf8),
            stderr: Data())))
        let summary = await VolumeSummary.read(volumeOf: URL(fileURLWithPath: NSTemporaryDirectory()), runner: runner)
        XCTAssertEqual(summary.snapshots, .count(1))
        let call = runner.calls.first
        XCTAssertEqual(call?.executable, "/usr/bin/tmutil")
        XCTAssertEqual(call?.arguments, ["listlocalsnapshots", summary.values.mountPoint ?? "?"])

        let failed = RecordingRunner(result: .success(CommandOutput(status: 1, stdout: Data(),
                                                                    stderr: Data("Operation not permitted\n".utf8))))
        let failedSummary = await VolumeSummary.read(volumeOf: URL(fileURLWithPath: "/"), runner: failed)
        XCTAssertEqual(failedSummary.snapshots, .unavailable("tmutil exited with status 1: Operation not permitted"))
        let timedOut = await VolumeSummary.read(volumeOf: URL(fileURLWithPath: "/"),
                                                runner: RecordingRunner(result: .failure(.timedOut)))
        XCTAssertEqual(timedOut.snapshots, .unavailable("tmutil did not answer within 5 seconds."))
    }

    func testReadsThisMacsVolume() async {
        let summary = await VolumeSummary.read(volumeOf: URL(fileURLWithPath: NSTemporaryDirectory()))
        let capacity = summary.capacity ?? 0
        XCTAssertGreaterThan(capacity, 0)
        XCTAssertLessThanOrEqual(summary.available ?? .max, capacity)
        XCTAssertNotNil(summary.values.mountPoint)
        XCTAssertNil(summary.snapshotBytes)
        // tmutil is on every Mac, so a format the parser does not understand fails here rather than reading as unknown.
        guard case .count = summary.snapshots else {
            return XCTFail("tmutil listlocalsnapshots was not parsed: \(summary.snapshots)")
        }
        // The startup disk, which the issue names: tmutil listlocalsnapshots /.
        let startup = await VolumeSummary.read(volumeOf: URL(fileURLWithPath: "/"))
        XCTAssertEqual(startup.values.mountPoint, "/")
        guard case .count = startup.snapshots else {
            return XCTFail("tmutil listlocalsnapshots / was not parsed: \(startup.snapshots)")
        }
    }
}

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private let result: Result<CommandOutput, CommandFailure>
    private var recorded: [Call] = []

    init(result: Result<CommandOutput, CommandFailure>) {
        self.result = result
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) async
        -> Result<CommandOutput, CommandFailure> {
        lock.withLock { recorded.append(Call(executable: executable, arguments: arguments)) }
        return result
    }
}
