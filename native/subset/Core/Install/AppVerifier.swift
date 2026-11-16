import Foundation
import Security

/// What the feed says the staged app is.
public struct ExpectedApp: Equatable, Sendable {
    public var bundleID: String
    public var version: String
    /// The beta build, checked against CFBundleVersion; nil for a live release.
    public var build: Int?

    public init(bundleID: String, version: String, build: Int?) {
        self.bundleID = bundleID
        self.version = version
        self.build = build
    }
}

/// Proves a staged app is the Subset app the feed lists; `SecurityAppVerifier` asks the Security framework and
/// Gatekeeper, tests pass a stand-in.
public protocol AppVerifying: Sendable {
    /// Returns when every check passes; throws an InstallFailure naming the first that does not (signature, team,
    /// notarization, bundle ID, version, macOS version), or CancellationError.
    func verify(_ bundle: URL, expected: ExpectedApp) async throws
}

/// The checks of verify.mjs (SET-230), in its order, with the Security framework in place of codesign:
///   signature      the static code is valid with strict validation, every architecture and nested code checked
///                  (codesign --verify --deep --strict)
///   team           it satisfies the Developer ID requirement for team SAZVPX4CAA
///   notarization   Gatekeeper (spctl --assess --type execute) accepts it with source=Notarized Developer ID
///   bundle ID      Info.plist's CFBundleIdentifier is the feed's bundle ID
///   version        CFBundleShortVersionString is the channel's version, and for a beta CFBundleVersion its build
///   macOS version  LSMinimumSystemVersion is not above the running macOS
public struct SecurityAppVerifier: AppVerifying {
    public static let teamID = "SAZVPX4CAA"
    /// A Developer ID Application certificate issued by Apple to the Subset team.
    static let requirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
        + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamID)\""
    static let spctl = "/usr/sbin/spctl"

    /// The running macOS version as x.y.z.
    var runningMacOS: String

    public init(runningMacOS: String? = nil) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        self.runningMacOS = runningMacOS ?? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public func verify(_ bundle: URL, expected: ExpectedApp) async throws {
        var created: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &created)
        guard status == errSecSuccess, let code = created else {
            throw InstallFailure(.signature, "the code signature cannot be read (\(Self.describe(status, nil)))")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let valid = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard valid == errSecSuccess else {
            throw InstallFailure(.signature, "the code signature is not valid (\(Self.describe(valid, error)))")
        }
        try Task.checkCancellation()

        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement as CFString, [], &parsed) == errSecSuccess, let requirement = parsed else {
            throw InstallFailure(.team, "the Subset team requirement cannot be made")
        }
        if SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) != errSecSuccess {
            throw InstallFailure(.team, "it is not signed by the Subset team \(Self.teamID) (TeamIdentifier: \(Self.team(of: code) ?? "not reported"))")
        }

        let assessment = try await ToolRunner.run(Self.spctl, ["--assess", "--type", "execute", "-vv", bundle.path])
        let output = String(decoding: assessment.stdout, as: UTF8.self) + "\n" + assessment.stderr
        let source = output.split(separator: "\n").first { $0.hasPrefix("source=") }.map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard assessment.status == 0, source == "Notarized Developer ID" else {
            let found = source.map { "source=\($0)" } ?? assessment.lastLine
            throw InstallFailure(.notarization, "Gatekeeper does not accept it as a notarized Developer ID app (spctl: \(found))")
        }

        guard let info = InstalledAppFinder.infoPlist(bundle.path) else {
            throw InstallFailure(.bundleID, "its Contents/Info.plist cannot be read")
        }
        try Self.checkInfo(info, expected: expected, runningMacOS: runningMacOS)
    }

    /// The bundle ID, version and minimum macOS checks of an Info.plist.
    static func checkInfo(_ info: [String: Any], expected: ExpectedApp, runningMacOS: String) throws {
        let quoted = { (key: String) in (info[key] as? String).map { "\"\(InstalledCopy.displayable($0))\"" } ?? "null" }
        guard info["CFBundleIdentifier"] as? String == expected.bundleID else {
            throw InstallFailure(.bundleID, "its bundle ID is \(quoted("CFBundleIdentifier")), not \(expected.bundleID)")
        }
        guard info["CFBundleShortVersionString"] as? String == expected.version else {
            throw InstallFailure(.version, "its version is \(quoted("CFBundleShortVersionString")), not \(expected.version)")
        }
        if let build = expected.build, info["CFBundleVersion"] as? String != String(build) {
            throw InstallFailure(.version, "its build is \(quoted("CFBundleVersion")), not \(build)")
        }
        guard let raw = info["LSMinimumSystemVersion"] else { return }
        guard let minimum = (raw as? String).flatMap(macOSVersion) else {
            throw InstallFailure(.macOSVersion, "its minimum macOS version \(quoted("LSMinimumSystemVersion")) is not a version")
        }
        if UpdateRule.compareVersions(minimum, runningMacOS) > 0 {
            throw InstallFailure(.macOSVersion, "it needs macOS \(minimum) or later, and this Mac runs \(runningMacOS)")
        }
    }

    // A macOS version (14, 14.0, 14.2.1) as x.y.z, or nil when it is not one.
    static func macOSVersion(_ text: String) -> String? {
        guard text.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil else { return nil }
        var parts = text.split(separator: ".").map(String.init)
        while parts.count < 3 { parts.append("0") }
        return parts.joined(separator: ".")
    }

    private static func team(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func describe(_ status: OSStatus, _ error: Unmanaged<CFError>?) -> String {
        if let error = error?.takeRetainedValue() { return CFErrorCopyDescription(error) as String? ?? "OSStatus \(status)" }
        return SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
