import Darwin
import Foundation
import Security
@testable import SystemCore
import XCTest

final class CodeSignatureTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodeSignatureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testTheCacheHitsOnAnUnchangedFileAndMissesAfterItChanges() throws {
        let executable = folder.appendingPathComponent("tool")
        try Data("v1".utf8).write(to: executable)
        let fixtures = FixtureSignalReaders()
        fixtures.signatures = [10: signed("dev.example.tool"), 11: signed("dev.example.tool")]
        let reader = CachedCodeSignatureReader(reader: fixtures, isCurrent: { _ in true })

        XCTAssertEqual(reader.codeSignature(of: started(10), executablePath: executable.path), signed("dev.example.tool"))
        XCTAssertEqual(reader.codeSignature(of: started(11), executablePath: executable.path), signed("dev.example.tool"))
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 10), 1)
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 11), 0, "a second process running the same file is a hit")

        // A rebuilt file of the same size, run by a process started afterwards.
        fixtures.signatures[12] = signed("dev.example.tool.v2")
        try Data("v2".utf8).write(to: executable)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: executable.path)
        XCTAssertEqual(reader.codeSignature(of: started(12), executablePath: executable.path), signed("dev.example.tool.v2"))
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 12), 1)

        // A change in size with the modification time put back is a miss too.
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: executable.path)[.modificationDate] as? Date)
        try Data("version 3".utf8).write(to: executable)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: executable.path)
        _ = reader.codeSignature(of: started(12), executablePath: executable.path)
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 12), 2)
    }

    func testAFileReplacedWithItsOldModificationTimeAndSizeIsAMiss() throws {
        let executable = folder.appendingPathComponent("tool")
        try Data("v1".utf8).write(to: executable)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: executable.path)
        let fixtures = FixtureSignalReaders()
        fixtures.signatures = [10: signed("dev.example.tool"), 11: signed("dev.example.tool.v2")]
        let reader = CachedCodeSignatureReader(reader: fixtures, isCurrent: { _ in true })
        _ = reader.codeSignature(of: started(10), executablePath: executable.path)

        // An installer that copies the new version over with the archive's modification time.
        let replacement = folder.appendingPathComponent("tool.new")
        try Data("v2".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: replacement.path)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertEqual(rename(replacement.path, executable.path), 0)

        XCTAssertEqual(reader.codeSignature(of: started(11), executablePath: executable.path), signed("dev.example.tool.v2"))
    }

    func testOnlyAReadWhoseProcessIsStillTheSameIdentityFillsTheCache() throws {
        let executable = folder.appendingPathComponent("tool")
        try Data("v1".utf8).write(to: executable)
        let fixtures = FixtureSignalReaders()
        // pid 10 changed hands during its read: the signature may be another program's.
        fixtures.signatures = [10: signed("dev.example.other"), 11: signed("dev.example.tool")]
        let reader = CachedCodeSignatureReader(reader: fixtures, isCurrent: { $0.pid != 10 })

        _ = reader.codeSignature(of: started(10), executablePath: executable.path)
        XCTAssertEqual(reader.codeSignature(of: started(11), executablePath: executable.path), signed("dev.example.tool"))
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 11), 1, "the rejected read left no entry")
    }

    func testAProcessStartedBeforeTheFileChangedNeitherFillsNorUsesTheEntry() throws {
        let executable = folder.appendingPathComponent("tool")
        let older = ProcessIdentity(pid: 10, startTime: microsecondsNow() - 60_000_000)
        // Updated after pid 10 started, so pid 10 may still run the version this file replaced.
        try Data("v2".utf8).write(to: executable)
        let fixtures = FixtureSignalReaders()
        fixtures.signatures = [10: signed("dev.example.tool.v1"), 11: signed("dev.example.tool.v2")]
        let reader = CachedCodeSignatureReader(reader: fixtures, isCurrent: { _ in true })

        XCTAssertEqual(reader.codeSignature(of: older, executablePath: executable.path), signed("dev.example.tool.v1"))
        XCTAssertEqual(reader.codeSignature(of: started(11), executablePath: executable.path), signed("dev.example.tool.v2"))
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 11), 1, "the older process's read left no entry")

        // The entry the newer process filled does not describe the older one either.
        XCTAssertEqual(reader.codeSignature(of: older, executablePath: executable.path), signed("dev.example.tool.v1"))
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 10), 2)
        _ = reader.codeSignature(of: started(12), executablePath: executable.path)
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 12), 0, "a process launched from the current file hits")
    }

    func testFailuresAndUnstampableFilesAreNotCached() throws {
        let executable = folder.appendingPathComponent("tool")
        try Data("v1".utf8).write(to: executable)
        let fixtures = FixtureSignalReaders()
        let reader = CachedCodeSignatureReader(reader: fixtures, isCurrent: { _ in true })

        // pid 10 has no fixture, so it reads as exited; that says nothing about the file.
        XCTAssertEqual(reader.codeSignature(of: started(10), executablePath: executable.path), .unavailable(.processExited, source: .codeSigning))
        fixtures.signatures[10] = signed("dev.example.tool")
        XCTAssertEqual(reader.codeSignature(of: started(10), executablePath: executable.path), signed("dev.example.tool"))

        let deleted = folder.appendingPathComponent("deleted").path
        _ = reader.codeSignature(of: started(10), executablePath: deleted)
        _ = reader.codeSignature(of: started(10), executablePath: deleted)
        _ = reader.codeSignature(of: started(10), executablePath: nil)
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 10), 5)
    }

    func testSigningInformationMapsToTeamIdentifierAndPlatformBinary() {
        let thirdParty = SecCodeSignatureReader.signature(from: [
            kSecCodeInfoIdentifier as String: "com.example.App",
            kSecCodeInfoTeamIdentifier as String: "ABCDE12345"
        ])
        XCTAssertEqual(thirdParty, CodeSignature(signingID: "com.example.App", teamID: "ABCDE12345", isPlatformBinary: false))

        let platform = SecCodeSignatureReader.signature(from: [
            kSecCodeInfoIdentifier as String: "com.apple.xpc.launchd",
            kSecCodeInfoPlatformIdentifier as String: NSNumber(value: 26)
        ])
        XCTAssertEqual(platform, CodeSignature(signingID: "com.apple.xpc.launchd", teamID: nil, isPlatformBinary: true))

        let unsigned = SecCodeSignatureReader.signature(from: [:])
        XCTAssertFalse(unsigned.isSigned)
        XCTAssertFalse(unsigned.isPlatformBinary)
    }

    func testSecurityErrorsMapToReasons() {
        XCTAssertEqual(SecCodeSignatureReader.failure(100_000 + ESRCH), .processExited)
        XCTAssertEqual(SecCodeSignatureReader.failure(errSecCSNoSuchCode), .processExited)
        XCTAssertEqual(SecCodeSignatureReader.failure(100_000 + EPERM), .denied)
        XCTAssertEqual(SecCodeSignatureReader.failure(errSecCSUnsigned), .securityError(errSecCSUnsigned))
    }

    func testAnExitedProcessHasNoSignature() throws {
        // A PID above the kernel's maximum never exists.
        let signal = SecCodeSignatureReader().codeSignature(of: ProcessIdentity(pid: 99_999_999, startTime: 0), executablePath: nil)
        XCTAssertEqual(signal, .unavailable(.processExited, source: .codeSigning))
    }

    /// A process that started a second from now, after any file the test has written so far.
    private func started(_ pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: microsecondsNow() + 1_000_000)
    }

    private func microsecondsNow() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private func signed(_ identifier: String) -> Signal<CodeSignature> {
        .value(CodeSignature(signingID: identifier, teamID: "ABCDE12345", isPlatformBinary: false), source: .codeSigning)
    }
}
