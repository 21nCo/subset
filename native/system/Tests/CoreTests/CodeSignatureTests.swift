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
        let reader = CachedCodeSignatureReader(reader: fixtures)

        XCTAssertEqual(reader.codeSignature(of: 10, executablePath: executable.path), signed("dev.example.tool"))
        XCTAssertEqual(reader.codeSignature(of: 11, executablePath: executable.path), signed("dev.example.tool"))
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 10), 1)
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 11), 0, "a second process running the same file is a hit")

        // A rebuilt file of the same size differs only in modification time.
        fixtures.signatures[11] = signed("dev.example.tool.v2")
        try Data("v2".utf8).write(to: executable)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: executable.path)
        XCTAssertEqual(reader.codeSignature(of: 11, executablePath: executable.path), signed("dev.example.tool.v2"))
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 11), 1)

        // A change in size alone is a miss too.
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: executable.path)[.modificationDate] as? Date)
        try Data("version 3".utf8).write(to: executable)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: executable.path)
        _ = reader.codeSignature(of: 11, executablePath: executable.path)
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 11), 2)
    }

    func testFailuresAndUnstampableFilesAreNotCached() throws {
        let executable = folder.appendingPathComponent("tool")
        try Data("v1".utf8).write(to: executable)
        let fixtures = FixtureSignalReaders()
        let reader = CachedCodeSignatureReader(reader: fixtures)

        // pid 10 has no fixture, so it reads as exited; that says nothing about the file.
        XCTAssertEqual(reader.codeSignature(of: 10, executablePath: executable.path), .unavailable(.processExited, source: .codeSigning))
        fixtures.signatures[10] = signed("dev.example.tool")
        XCTAssertEqual(reader.codeSignature(of: 10, executablePath: executable.path), signed("dev.example.tool"))

        let deleted = folder.appendingPathComponent("deleted").path
        _ = reader.codeSignature(of: 10, executablePath: deleted)
        _ = reader.codeSignature(of: 10, executablePath: deleted)
        _ = reader.codeSignature(of: 10, executablePath: nil)
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
        let signal = SecCodeSignatureReader().codeSignature(of: 99_999_999, executablePath: nil)
        XCTAssertEqual(signal, .unavailable(.processExited, source: .codeSigning))
    }

    private func signed(_ identifier: String) -> Signal<CodeSignature> {
        .value(CodeSignature(signingID: identifier, teamID: "ABCDE12345", isPlatformBinary: false), source: .codeSigning)
    }
}
