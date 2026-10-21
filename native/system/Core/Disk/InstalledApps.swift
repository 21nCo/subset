import Darwin
import Foundation
import Security

/// An app installed on this Mac, as Library entries are matched against it.
public struct InstalledApp: Equatable, Sendable {
    /// The app's bundle. For a login item or helper app inside another app, the outer app's bundle, which owns it.
    public let path: String
    /// `CFBundleIdentifier`, of the bundle itself (the helper's own for a helper).
    public let bundleID: String
    /// The name shown for the app: the outer bundle's file name without `.app`.
    public let name: String
    /// Every name an entry may use for it: the bundle's file name without `.app`, `CFBundleName`, and
    /// `CFBundleDisplayName`.
    public let names: [String]
    /// The outer bundle's code signature, or `nil` when it could not be read.
    public let signature: CodeSignature?

    public init(path: String, bundleID: String, name: String, names: [String] = [], signature: CodeSignature?) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.names = names.isEmpty ? [name] : names
        self.signature = signature
    }

    /// The vendor this app's data belongs to, as the Vendor layer places a process: Apple for a platform binary, the
    /// Team ID, unsigned (no Team ID, ad hoc included), or signature unavailable, never reported as unsigned.
    public var vendor: Origin {
        guard let signature else { return .signatureUnavailable }
        if signature.isPlatformBinary { return .apple }
        if let team = signature.teamID { return .vendor(teamID: team) }
        return .unsigned
    }
}

/// The installed apps entries are matched against, with lookups by bundle ID, name, and Team ID. Tests inject the
/// list; `read()` builds it from the app folders.
public struct InstalledApps: Sendable {
    public let apps: [InstalledApp]
    private let byBundleID: [String: InstalledApp]
    private let byName: [String: [InstalledApp]]
    private let byTeam: [String: [InstalledApp]]

    public init(_ apps: [InstalledApp]) {
        // Ordered by path so that two copies of one app (two Xcode versions) resolve the same way every time.
        let sorted = apps.sorted { ($0.path, $0.bundleID) < ($1.path, $1.bundleID) }
        self.apps = sorted
        var byBundleID: [String: InstalledApp] = [:]
        var byName: [String: [InstalledApp]] = [:]
        var byTeam: [String: [InstalledApp]] = [:]
        for app in sorted {
            if byBundleID[app.bundleID.lowercased()] == nil { byBundleID[app.bundleID.lowercased()] = app }
            for name in Set(app.names.map { $0.lowercased() }) { byName[name, default: []].append(app) }
            if let team = app.signature?.teamID { byTeam[team, default: []].append(app) }
        }
        self.byBundleID = byBundleID
        self.byName = byName
        self.byTeam = byTeam
    }

    /// The app whose bundle ID is `identifier` or, component by component, its longest prefix
    /// (`com.google.Chrome.helper` is Chrome's), compared without case as bundle IDs are.
    public func app(bundleID identifier: String) -> InstalledApp? {
        var candidate = identifier.lowercased()
        while true {
            if let app = byBundleID[candidate] { return app }
            guard let dot = candidate.lastIndex(of: ".") else { return nil }
            candidate = String(candidate[..<dot])
        }
    }

    /// The one app with this name, compared without case; `nil` when no app or several different apps have it.
    public func app(named name: String) -> InstalledApp? {
        guard let found = byName[name.lowercased()], Set(found.map(\.path)).count == 1 else { return nil }
        return found.first
    }

    /// The apps signed by this team.
    public func apps(team: String) -> [InstalledApp] {
        byTeam[team] ?? []
    }

    /// The folders `read()` lists by default: the shared and the user's Applications folders and Apple's.
    public static func defaultFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", home + "/Applications", "/System/Applications"]
    }

    /// Reads every app in `folders` and in their subfolders one level down (`Utilities`, a vendor's folder), plus the
    /// login items and helper apps inside each (`Contents/Library/LoginItems`, `Contents/Helpers`), which keep data
    /// under their own bundle IDs. An app is read from its `Contents/Info.plist`; one without a bundle ID is left out.
    public static func read(folders: [String] = defaultFolders(),
                            signature: (String) -> CodeSignature? = staticSignature) -> InstalledApps {
        var apps: [InstalledApp] = []
        for folder in folders {
            for entry in listing(folder) {
                let path = folder + "/" + entry
                if entry.hasSuffix(".app") {
                    apps += bundle(at: path, signature: signature)
                } else if !entry.hasPrefix("."), isDirectory(path) {
                    for inner in listing(path) where inner.hasSuffix(".app") {
                        apps += bundle(at: path + "/" + inner, signature: signature)
                    }
                }
            }
        }
        return InstalledApps(apps)
    }

    /// The app at `path` and the login items and helper apps inside it, all owned by it.
    static func bundle(at path: String, signature: (String) -> CodeSignature?) -> [InstalledApp] {
        guard let info = infoPlist(path + "/Contents/Info.plist"), let bundleID = info.bundleID else { return [] }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let owner = InstalledApp(path: path, bundleID: bundleID, name: name, names: [name] + info.names,
                                 signature: signature(path))
        var apps = [owner]
        for folder in ["/Contents/Library/LoginItems", "/Contents/Helpers"] {
            for inner in listing(path + folder) where inner.hasSuffix(".app") {
                guard let nested = infoPlist(path + folder + "/" + inner + "/Contents/Info.plist"),
                      let nestedID = nested.bundleID else { continue }
                apps.append(InstalledApp(path: path, bundleID: nestedID, name: name, names: [name],
                                         signature: owner.signature))
            }
        }
        return apps
    }

    /// The Team ID and certificate name of the app's signature, checked against its certificate chain but not its
    /// files (`kSecCSBasicValidateOnly`), without network access; `nil` when the signature is invalid or unreadable.
    /// The signing team only groups the app's data, so its resources are not hashed.
    public static func staticSignature(_ path: String) -> CodeSignature? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code
        else { return nil }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess), nil)
        if validity == errSecCSUnsigned { return CodeSignature(signingID: nil, teamID: nil, isPlatformBinary: false) }
        guard validity == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return SecCodeSignatureReader.signature(from: information)
    }

    /// The bundle ID and names in an `Info.plist` (`PropertyListFile`).
    static func infoPlist(_ path: String) -> (bundleID: String?, names: [String])? {
        guard case let .success(plist) = PropertyListFile.read(path) else { return nil }
        let bundleID = (plist["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let names = ["CFBundleName", "CFBundleDisplayName"].compactMap { plist[$0] as? String }.filter { !$0.isEmpty }
        return (bundleID, names)
    }

    static func listing(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
