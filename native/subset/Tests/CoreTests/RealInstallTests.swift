import Foundation
@testable import SubsetCore
import XCTest

/// The installer with the real hdiutil, ditto, Security framework and Gatekeeper. The ad-hoc signed app is made here and
/// needs no network. The Breaks 0.1.0 install downloads the immutable live release asset that the fixture feed lists, so
/// it runs only when SUBSET_LIVE_INSTALL=1 (the macOS CI job sets it).
final class RealInstallTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("subset-real-\(UUID().uuidString)")
        for folder in ["Applications", "user", "receipts", "tmp", "Trash", "image"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installer(downloader: any ImageDownloading) -> AppInstaller {
        AppInstaller(
            setup: InstallSetup(
                folders: [
                    ApplicationsFolder(label: "/Applications", path: "/Applications", directory: root.appendingPathComponent("Applications")),
                    ApplicationsFolder(label: "~/Applications", path: "/Users/alex/Applications", directory: root.appendingPathComponent("user"))
                ],
                receipts: root.appendingPathComponent("receipts"), locks: root.appendingPathComponent("locks"),
                temporary: root.appendingPathComponent("tmp")
            ),
            downloader: downloader, images: HdiutilDiskImages(), verifier: SecurityAppVerifier(),
            trash: FolderTrash(folder: root.appendingPathComponent("Trash")), running: FakeRunning()
        )
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: tool, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text]) }
        return text
    }

    /// Breaks.app with a real Mach-O executable (a copy of /usr/bin/true), signed ad hoc unless `sign` is false.
    private func makeProbeApp(in folder: URL, sign: Bool) throws -> URL {
        let bundle = folder.appendingPathComponent("Breaks.app")
        try makeBundle(bundle, bundleID: "dev.subset.breaks", version: "0.1.0", build: "12", minimumMacOS: "14.0")
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        plist["CFBundleExecutable"] = "Breaks"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Breaks")
        if sign {
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
            try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        } else {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            chmod(executable.path, 0o755)
        }
        return bundle
    }

    func testAnAdHocSignedAppIsRefusedAtTheTeamRequirement() async throws {
        let source = root.appendingPathComponent("image")
        try makeProbeApp(in: source, sign: true)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let dmg = root.appendingPathComponent("Breaks.dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path, "-volname", "Breaks", "-fs", "HFS+", "-format", "UDZO", dmg.path])
        let bytes = try Data(contentsOf: dmg)
        var app = AppInstallerTests.breaks
        app.live?.sha256 = AppInstallerTests.hex(bytes)
        let release = try XCTUnwrap(ChosenRelease(app, channel: .live))

        do {
            _ = try await installer(downloader: FakeDownloader(images: [release.url: bytes])).install(app, release)
            XCTFail("an ad-hoc signed app was installed")
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure.step, .team, failure.message)
            XCTAssertEqual(failure.message, "it is not signed by the Subset team SAZVPX4CAA (TeamIdentifier: not reported)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Applications").path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tmp").path), [], "the private folder is removed")
        XCTAssertFalse(try run("/usr/bin/hdiutil", ["info"]).contains(root.appendingPathComponent("tmp").resolvingSymlinksInPath().path), "the image is detached")
    }

    func testAnUnsignedAppIsRefusedAtTheSignatureCheck() async throws {
        let bundle = try makeProbeApp(in: root.appendingPathComponent("image"), sign: false)
        do {
            try await SecurityAppVerifier().verify(bundle, expected: ExpectedApp(bundleID: "dev.subset.breaks", version: "0.1.0", build: nil))
            XCTFail("an unsigned app passed")
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure.step, .signature, failure.message)
        }
    }

    func testBreaks010InstallsFromItsLiveReleaseAndMovesToTheTrash() async throws {
        guard ProcessInfo.processInfo.environment["SUBSET_LIVE_INSTALL"] == "1" else {
            throw XCTSkip("downloads the Breaks 0.1.0 release asset; set SUBSET_LIVE_INSTALL=1 (the macOS CI job does)")
        }
        let feed = try Data(contentsOf: CatalogFeedTests.feedFolder.appendingPathComponent("fixtures/catalog-valid-live-only.json"))
        let app = try XCTUnwrap(Catalog.parse(feed).get().apps.first { $0.id == "breaks" })
        let release = try XCTUnwrap(ChosenRelease(app, channel: .live))
        XCTAssertEqual(release.version, "0.1.0")
        let installer = installer(downloader: URLSessionImageDownloader())

        let outcome = try await installer.install(app, release)
        let installed = root.appendingPathComponent("Applications/Breaks.app")
        XCTAssertEqual(outcome.path, installed.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Applications").path), ["Breaks.app"])
        try await SecurityAppVerifier().verify(installed, expected: ExpectedApp(bundleID: "dev.subset.breaks", version: "0.1.0", build: nil))
        let receipt = try Receipt.parse(Data(contentsOf: root.appendingPathComponent("receipts/dev.subset.breaks.json"))).get()
        XCTAssertEqual(receipt.path, "/Applications/Breaks.app")
        XCTAssertEqual(receipt.sha256, release.sha256)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tmp").path), [])
        XCTAssertFalse(try run("/usr/bin/hdiutil", ["info"]).contains("/subset-install-"), "the downloaded image is detached")

        _ = try await installer.moveToTrash(app, quitAllowed: false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Applications").path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("receipts/dev.subset.breaks.json").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Trash").path)
        XCTAssertEqual(trashed.count, 1)
        try await SecurityAppVerifier().verify(
            root.appendingPathComponent("Trash").appendingPathComponent(trashed[0]),
            expected: ExpectedApp(bundleID: "dev.subset.breaks", version: "0.1.0", build: nil)
        )
    }
}
