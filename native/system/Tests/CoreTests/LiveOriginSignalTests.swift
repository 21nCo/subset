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
        guard fd >= 0 else { return XCTAssertEqual(terminal, .none) }
        close(fd)
        // ttyname and fstat of /dev/tty name /dev/tty itself, and swift test's standard streams are pipes, so find
        // the device by opening each pseudo-terminal: tcgetsid answers only for the caller's controlling terminal.
        let session = getsid(0)
        let devices = try FileManager.default.contentsOfDirectory(atPath: "/dev").filter { $0.hasPrefix("ttys") }
        let name = try XCTUnwrap(devices.sorted().first { name in
            let device = open("/dev/" + name, O_RDONLY | O_NOCTTY | O_NONBLOCK)
            guard device >= 0 else { return false }
            defer { close(device) }
            return tcgetsid(device) == session
        }, "no /dev/ttys device is the controlling terminal")
        XCTAssertEqual(terminal, .device(name))
    }

    func testTerminalDevicesDecodeToNamesOrNumbers() {
        XCTAssertEqual(LiveProcessContextReader.terminal(device: dev_t(bitPattern: UInt32.max)), .none)
        XCTAssertEqual(LiveProcessContextReader.terminal(device: 0x1000003, name: { _ in "ttys003" }), .device("ttys003"))
        XCTAssertEqual(LiveProcessContextReader.terminal(device: 0x1000003, name: { _ in "??" }), .device("1,3"))
    }

    func testExecKeepsTheIdentityAndTheCheckSeesTheNewExecutable() throws {
        // A shell that runs `exec /bin/sleep` once it reads a line, as `exec node server.js` wrappers do.
        // /bin/bash directly: /bin/sh is a shim that itself execs the selected shell, which would add a second exec.
        let shell = Process()
        let input = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", "read line; exec /bin/sleep 30"]
        shell.standardInput = input
        try shell.run()
        defer { shell.terminate() }
        let pid = shell.processIdentifier
        let identity = try XCTUnwrap(LibprocProcessSource.currentIdentity(of: pid))
        let before = try XCTUnwrap(Self.executablePath(of: pid, resolvingTo: "/bin/bash"), "the shell never ran")
        XCTAssertEqual(LibprocProcessSource.check(identity, executablePath: before), .unchanged)

        input.fileHandleForWriting.write(Data("go\n".utf8))
        let after = try XCTUnwrap(Self.executablePath(of: pid, resolvingTo: "/bin/sleep"), "the shell never ran exec")

        XCTAssertEqual(LibprocProcessSource.currentIdentity(of: pid), identity, "exec keeps the PID and start time")
        XCTAssertEqual(LibprocProcessSource.check(identity, executablePath: before), .executableChanged)
        XCTAssertEqual(LibprocProcessSource.check(identity, executablePath: after), .unchanged)
    }

    /// Waits, up to a deadline, until `pid` runs `expected` (compared after resolving symlinks) and returns the path libproc reports.
    private static func executablePath(of pid: pid_t, resolvingTo expected: String, timeout: TimeInterval = 10) -> String? {
        let target = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let path = LibprocProcessSource.executablePath(pid), URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target {
                return path
            }
            usleep(10_000)
        } while Date() < deadline
        return nil
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

    func testAProcessWhoseExecutableWasReplacedIsNotGivenTheReplacementsSignature() throws {
        try Self.withReplacedExecutable(stripReplacement: false) { identity, path in
            let replaced = Signal<CodeSignature>.unavailable(
                .unexpectedResult("the executable on disk is not the one the process runs"), source: .codeSigning
            )
            XCTAssertEqual(SecCodeSignatureReader().codeSignature(of: identity, executablePath: path), replaced)
            XCTAssertEqual(CachedCodeSignatureReader().codeSignature(of: identity, executablePath: path), replaced)
        }
    }

    func testASignedProcessWhoseExecutableWasReplacedByAnUnsignedFileIsNotReadAsUnsigned() throws {
        try Self.withReplacedExecutable(stripReplacement: true) { identity, path in
            // The file is unsigned, so Security stops before comparing it with the running code; the kernel still
            // reports the running code as signed.
            let replaced = Signal<CodeSignature>.unavailable(
                .unexpectedResult("the process runs signed code but the executable on disk is unsigned"), source: .codeSigning
            )
            XCTAssertEqual(SecCodeSignatureReader().codeSignature(of: identity, executablePath: path), replaced)
            XCTAssertEqual(CachedCodeSignatureReader().codeSignature(of: identity, executablePath: path), replaced)
        }
    }

    /// Runs a signed program, renames a replacement over its file while it runs, as an app update does, and calls
    /// `body` with the process still running the original. The replacement is unsigned when `stripReplacement` is set.
    private static func withReplacedExecutable(
        stripReplacement: Bool, _ body: (ProcessIdentity, String) throws -> Void
    ) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReplacedExecutable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The linker signs each program ad hoc, with its file name as the signing identifier.
        let original = try compile("int main(void) { pause(); return 0; }", to: folder.appendingPathComponent("original").path)
        let replacement = try compile("int main(void) { pause(); return 1; }", to: folder.appendingPathComponent("replacement").path)
        if stripReplacement { try run("/usr/bin/codesign", ["--remove-signature", replacement]) }
        let running = Process()
        running.executableURL = URL(fileURLWithPath: original)
        try running.run()
        defer { running.terminate() }
        let pid = running.processIdentifier
        let path = try XCTUnwrap(executablePath(of: pid, resolvingTo: original), "the program never ran")
        let identity = try XCTUnwrap(LibprocProcessSource.currentIdentity(of: pid))
        XCTAssertEqual(SecCodeSignatureReader().codeSignature(of: identity, executablePath: path).value?.signingID, "original")

        XCTAssertEqual(rename(replacement, original), 0, String(cString: strerror(errno)))
        try body(identity, path)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments) failed")
    }

    /// Builds a C program with the selected developer tools and returns its path.
    private static func compile(_ source: String, to path: String) throws -> String {
        let compiler = Process()
        let input = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-x", "c", "-include", "unistd.h", "-", "-o", path]
        compiler.standardInput = input
        try compiler.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try input.fileHandleForWriting.close()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, "cc failed for \(path)")
        return path
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
        // No plist names the test runner; a Mac with a plist it cannot read cannot rule one out.
        if case .incompleteScan? = origin.launchdJobs.failure {} else {
            XCTAssertEqual(origin.launchdJobs.value, LaunchdJobs(jobs: []))
        }
    }
}
