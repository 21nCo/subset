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
    /// The app groups the bundle's own signature declares (`com.apple.security.application-groups`), whose containers
    /// in `~/Library/Group Containers` are its data whatever they are called; `nil` when its entitlements could not be
    /// read.
    public let appGroups: [String]?

    public init(path: String, bundleID: String, name: String, names: [String] = [], signature: CodeSignature?,
                appGroups: [String]? = []) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.names = names.isEmpty ? [name] : names
        self.signature = signature
        self.appGroups = appGroups
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

/// What a bundle's signature says: who signed it and the app groups it declares.
public struct AppSigning: Equatable, Sendable {
    /// `nil` when the signature could not be read.
    public let signature: CodeSignature?
    /// `nil` when the entitlements could not be read.
    public let appGroups: [String]?

    public init(signature: CodeSignature?, appGroups: [String]?) {
        self.signature = signature
        self.appGroups = appGroups
    }
}

/// The installed apps entries are matched against, with lookups by bundle ID, name, Team ID, and app group. Tests
/// inject the list; `read()` builds it from the app folders.
public struct InstalledApps: Sendable {
    public let apps: [InstalledApp]
    /// Every app's signature and entitlements were read, so a Team ID or app group no app has is no installed app's.
    public let signingComplete: Bool
    private let byBundleID: [String: InstalledApp]
    private let byName: [String: [InstalledApp]]
    private let byTeam: [String: [InstalledApp]]
    private let byGroup: [String: [InstalledApp]]

    public init(_ apps: [InstalledApp]) {
        // Ordered by path so that two copies of one app (two Xcode versions) resolve the same way every time.
        let sorted = apps.sorted { ($0.path, $0.bundleID) < ($1.path, $1.bundleID) }
        self.apps = sorted
        var byBundleID: [String: InstalledApp] = [:]
        var byName: [String: [InstalledApp]] = [:]
        var byTeam: [String: [InstalledApp]] = [:]
        var byGroup: [String: [InstalledApp]] = [:]
        for app in sorted {
            if byBundleID[app.bundleID.lowercased()] == nil { byBundleID[app.bundleID.lowercased()] = app }
            for name in Set(app.names.map { $0.lowercased() }) { byName[name, default: []].append(app) }
            if let team = app.signature?.teamID { byTeam[team, default: []].append(app) }
            for group in Set((app.appGroups ?? []).map { $0.lowercased() }) { byGroup[group, default: []].append(app) }
        }
        self.byBundleID = byBundleID
        self.byName = byName
        self.byTeam = byTeam
        self.byGroup = byGroup
        signingComplete = sorted.allSatisfy { $0.signature != nil && $0.appGroups != nil }
    }

    /// The app whose bundle ID is `identifier` or, component by component, its longest prefix of two components or
    /// more (`com.google.Chrome.helper` is Chrome's), compared without case as bundle IDs are.
    public func app(bundleID identifier: String) -> InstalledApp? {
        var candidate = identifier.lowercased()
        while true {
            if let app = byBundleID[candidate] { return app }
            guard let dot = candidate.lastIndex(of: "."), candidate[..<dot].contains(".") else { return nil }
            candidate = String(candidate[..<dot])
        }
    }

    /// The apps whose signatures declare the app group `group`, compared without case.
    public func apps(group: String) -> [InstalledApp] {
        byGroup[group.lowercased()] ?? []
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
                            signing: (String) -> AppSigning = staticSigning) -> InstalledApps {
        var apps: [InstalledApp] = []
        for folder in folders {
            for entry in listing(folder) {
                let path = folder + "/" + entry
                if entry.hasSuffix(".app") {
                    apps += bundle(at: path, signing: signing)
                } else if !entry.hasPrefix("."), isDirectory(path) {
                    for inner in listing(path) where inner.hasSuffix(".app") {
                        apps += bundle(at: path + "/" + inner, signing: signing)
                    }
                }
            }
        }
        return InstalledApps(apps)
    }

    /// The app at `path` and the login items and helper apps inside it, all owned by it and placed under its vendor;
    /// each declares its own app groups.
    static func bundle(at path: String, signing: (String) -> AppSigning) -> [InstalledApp] {
        guard let info = infoPlist(path + "/Contents/Info.plist"), let bundleID = info.bundleID else { return [] }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let signed = signing(path)
        var apps = [InstalledApp(path: path, bundleID: bundleID, name: name, names: [name] + info.names,
                                 signature: signed.signature, appGroups: signed.appGroups)]
        for folder in ["/Contents/Library/LoginItems", "/Contents/Helpers"] {
            for inner in listing(path + folder) where inner.hasSuffix(".app") {
                let nestedPath = path + folder + "/" + inner
                guard let nested = infoPlist(nestedPath + "/Contents/Info.plist"), let nestedID = nested.bundleID
                else { continue }
                apps.append(InstalledApp(path: path, bundleID: nestedID, name: name, names: [name],
                                         signature: signed.signature, appGroups: signing(nestedPath).appGroups))
            }
        }
        return apps
    }

    /// The Team ID and certificate name of the app's signature, checked against its certificate chain but not its
    /// files (`kSecCSBasicValidateOnly`), without network access, and the app groups it declares; the signature is
    /// `nil` when invalid or unreadable, and the groups then too. The signing team only groups the app's data, so its
    /// resources are not hashed.
    public static func staticSigning(_ path: String) -> AppSigning {
        let unread = AppSigning(signature: nil, appGroups: nil)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code
        else { return unread }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess), nil)
        if validity == errSecCSUnsigned {
            return AppSigning(signature: CodeSignature(signingID: nil, teamID: nil, isPlatformBinary: false), appGroups: [])
        }
        guard validity == errSecSuccess else { return unread }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let information = information as? [String: Any] else { return unread }
        return AppSigning(signature: SecCodeSignatureReader.signature(from: information),
                          appGroups: appGroups(entitlements: information[kSecCodeInfoEntitlementsDict as String]))
    }

    /// The groups in an entitlements dictionary: `com.apple.security.application-groups` and its restricted variant,
    /// which Apple's apps use (Shortcuts declares `group.is.workflow.my.app`). No dictionary declares none; one that
    /// is not a dictionary, or groups that are not strings, cannot be read.
    static func appGroups(entitlements: Any?) -> [String]? {
        guard let entitlements else { return [] }
        guard let dictionary = entitlements as? [String: Any] else { return nil }
        var groups: [String] = []
        for key in ["com.apple.security.application-groups", "com.apple.private.security.restricted-application-groups"] {
            guard let value = dictionary[key] else { continue }
            guard let list = value as? [String] else { return nil }
            groups += list
        }
        return groups
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
