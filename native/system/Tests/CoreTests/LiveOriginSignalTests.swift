import Darwin
import Foundation
@testable import SystemCore
import XCTest

/// Reads this test process's own origin signals on this Mac. Runs in CI on macOS.
final class LiveOriginSignalTests: XCTestCase {
    func testItsOwnWorkingDirectoryIsRead() throws {
        let signal = LiveProcessContextReader().workingDirectory(of: getpid())

        XCTAssertEqual(signal.source, .vnodePathInfo)
        let path = try XCTUnwrap(signal.value, "\(String(describing: signal.failure))")
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
    }

    func testItsOwnTerminalStateMatchesDevTTY() throws {
        let signal = LiveProcessContextReader().terminal(of: getpid())

        XCTAssertEqual(signal.source, .bsdInfo)
        let terminal = try XCTUnwrap(signal.value, "\(String(describing: signal.failure))")
        // /dev/tty opens only with a controlling terminal: a test run from Terminal has one, CI's does not.
        let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
        if fd >= 0 {
            defer { close(fd) }
            let name = try XCTUnwrap(ttyname(fd).map { String(cString: $0) })
            XCTAssertEqual(terminal, .device(String(name.dropFirst("/dev/".count))))
        } else {
            XCTAssertEqual(terminal, .none)
        }
    }

    func testTerminalDevicesDecodeToNamesOrNumbers() {
        XCTAssertEqual(LiveProcessContextReader.terminal(device: dev_t(bitPattern: UInt32.max)), .none)
        XCTAssertEqual(LiveProcessContextReader.terminal(device: 0x1000003, name: { _ in "ttys003" }), .device("ttys003"))
        XCTAssertEqual(LiveProcessContextReader.terminal(device: 0x1000003, name: { _ in "??" }), .device("1,3"))
    }

    func testItsOwnCodeSignatureIsRead() throws {
        let path = Bundle.main.executablePath
        let identity = try XCTUnwrap(LibprocProcessSource.currentIdentity(of: getpid()))
        let signal = CachedCodeSignatureReader().codeSignature(of: identity, executablePath: path)

        XCTAssertEqual(signal.source, .codeSigning)
        let signature = try XCTUnwrap(signal.value, "\(String(describing: signal.failure))")
        // The test host (xctest or swiftpm-testing-helper) ships with Xcode, signed by Apple.
        XCTAssertTrue(signature.isSigned)
        XCTAssertFalse(try XCTUnwrap(signature.signingID).isEmpty)
    }

    func testLaunchdIsAnAppleSignedPlatformBinaryAndKeepsItsPublicSignals() throws {
        // pid 1 belongs to root: without root, macOS denies its responsibility and working-directory reads.
        let signature = try XCTUnwrap(SecCodeSignatureReader().codeSignature(of: ProcessIdentity(pid: 1, startTime: 0), executablePath: nil).value)
        XCTAssertEqual(signature.signingID, "com.apple.xpc.launchd")
        XCTAssertTrue(signature.isPlatformBinary)
        XCTAssertNil(signature.teamID)
        XCTAssertEqual(LiveProcessContextReader().terminal(of: 1).value, ControllingTerminal.none)
        if getuid() != 0 {
            XCTAssertEqual(LiveProcessContextReader().workingDirectory(of: 1), .unavailable(.denied, source: .vnodePathInfo))
            XCTAssertEqual(LiveProcessContextReader().terminal(of: 1).source, .processTable)
        }
    }

    func testThePrivateInterfacesAnswerOrRecordWhyNot() {
        let responsible = LiveResponsibleProcessReader().responsibleProcess(of: getpid())
        XCTAssertEqual(responsible.source, .responsibility)
        if let pid = responsible.value {
            XCTAssertGreaterThan(pid, 0)
        } else {
            XCTAssertFalse(try XCTUnwrap(responsible.failure).reason.isEmpty)
        }

        let coalition = LiveCoalitionReader().coalition(of: getpid())
        XCTAssertEqual(coalition.source, .coalitionInfo)
        if let id = coalition.value {
            XCTAssertGreaterThan(id, 0)
        } else {
            XCTAssertFalse(try XCTUnwrap(coalition.failure).reason.isEmpty)
        }
        print("Private interfaces on this Mac: responsible \(responsible), coalition \(coalition)")
    }

    func testTheSamplerFillsItsOwnOriginSignals() throws {
        var sampler = Sampler(source: LibprocProcessSource(), origin: .live())
        // The first samples may spend their budget on older processes; this one started recently, so allow a few.
        var mine: ProcessFacts?
        for _ in 0..<30 where mine?.origin == nil {
            mine = try sampler.sample().processes.first { $0.pid == getpid() }
        }
        let origin = try XCTUnwrap(try XCTUnwrap(mine).origin)

        XCTAssertNotNil(origin.workingDirectory.value)
        XCTAssertNotNil(origin.terminal.value)
        XCTAssertNotNil(origin.codeSignature.value)
        XCTAssertNotNil(origin.launchdJobs.value)
    }
}
