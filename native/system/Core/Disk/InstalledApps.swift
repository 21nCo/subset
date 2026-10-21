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
    /// Where an app may be that could not be read: an app folder not listed, an app whose bundle ID could not be read.
    public let unread: [String]
    /// Every app in the app folders was read with its bundle ID, so a bundle ID no app has is no installed app's.
    public var isComplete: Bool { unread.isEmpty }
    /// The list is complete and every app's signature and entitlements were read, so a Team ID or app group no app
    /// has is no installed app's.
    public let signingComplete: Bool
    /// Why `signingComplete` is false: `unread`, then each app whose signature or entitlements could not be read.
    public var unreadSigning: [String] {
        unread + Set(apps.filter { $0.signature == nil || $0.appGroups == nil }.map(\.path)).sorted().map {
            "\($0) has no readable signature."
        }
    }
    private let byBundleID: [String: InstalledApp]
    private let byName: [String: [InstalledApp]]
    private let byTeam: [String: [InstalledApp]]
    private let byGroup: [String: [InstalledApp]]

    public init(_ apps: [InstalledApp], unread: [String] = []) {
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
        self.unread = unread
        signingComplete = unread.isEmpty && sorted.allSatisfy { $0.signature != nil && $0.appGroups != nil }
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
    /// under their own bundle IDs. An app is read from its `Contents/Info.plist`, or an iPhone or iPad app from its
    /// wrapped bundle's (`Wrapper/<name>.app/Info.plist`). A folder that cannot be listed (one that does not exist is
    /// empty) and an app whose bundle ID cannot be read are `unread`; an entry named like an app that is neither a
    /// folder nor a link to one, or a folder with neither layout, is not an app and is skipped.
    public static func read(folders: [String] = defaultFolders(),
                            signing: (String) -> AppSigning = staticSigning) -> InstalledApps {
        var apps: [InstalledApp] = []
        var unread: [String] = []
        for folder in folders {
            for entry in listing(folder, unread: &unread) {
                let path = folder + "/" + entry
                if entry.hasSuffix(".app") {
                    apps += bundle(at: path, signing: signing, unread: &unread)
                } else if !entry.hasPrefix("."), isDirectory(path) {
                    for inner in listing(path, unread: &unread) where inner.hasSuffix(".app") {
                        apps += bundle(at: path + "/" + inner, signing: signing, unread: &unread)
                    }
                }
            }
        }
        return InstalledApps(apps, unread: unread)
    }

    /// The app at `path` and the login items and helper apps inside it, all owned by it and placed under its vendor;
    /// each declares its own app groups. A wrapped iPhone or iPad app is signed as its inner bundle.
    static func bundle(at path: String, signing: (String) -> AppSigning, unread: inout [String]) -> [InstalledApp] {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let (signedPath, info) = appInfo(at: path, unread: &unread) else { return [] }
        let signed = signing(signedPath)
        var apps = [InstalledApp(path: path, bundleID: info.bundleID, name: name, names: [name] + info.names,
                                 signature: signed.signature, appGroups: signed.appGroups)]
        for folder in ["/Contents/Library/LoginItems", "/Contents/Helpers"] {
            for inner in listing(path + folder, unread: &unread) where inner.hasSuffix(".app") {
                let nestedPath = path + folder + "/" + inner
                guard let (nestedSigned, nested) = appInfo(at: nestedPath, unread: &unread) else { continue }
                apps.append(InstalledApp(path: path, bundleID: nested.bundleID, name: name, names: [name],
                                         signature: signed.signature, appGroups: signing(nestedSigned).appGroups))
            }
        }
        return apps
    }

    /// The bundle ID and names of the app at `path` and the bundle it is signed as, from its `Contents/Info.plist` or
    /// its wrapped bundle's. An entry named like an app that is not one, a file (an alias), a link to nothing, or a
    /// folder with neither `Contents` nor a wrapped app, is skipped; one whose bundle ID cannot be read (a `Contents`
    /// without an `Info.plist` too), or that cannot be checked, is `unread`.
    static func appInfo(at path: String, unread: inout [String]) -> (String, (bundleID: String, names: [String]))? {
        var status = stat()
        guard stat(path, &status) == 0 else {
            let error = errno
            if error != ENOENT, error != ENOTDIR { unread.append("\(path) could not be read: \(String(cString: strerror(error))).") }
            return nil
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return nil }
        var signedPath = path
        var plist = PropertyListFile.read(path + "/Contents/Info.plist")
        if case .failure(.missing) = plist {
            if let wrapped = listing(path + "/Wrapper", unread: &unread).first(where: { $0.hasSuffix(".app") }) {
                signedPath = path + "/Wrapper/" + wrapped
                plist = PropertyListFile.read(signedPath + "/Info.plist")
            } else if !exists(path + "/Contents") {
                return nil
            }
        }
        guard case let .success(found) = plist, let info = infoPlist(found) else {
            unread.append("\(path) has no readable bundle identifier.")
            return nil
        }
        return (signedPath, info)
    }

    /// The Team ID and certificate name of the app's signature, checked against its certificate chain but not its
    /// files (`kSecCSBasicValidateOnly`), without network access, and the app groups it declares; the signature is
    /// `nil` when invalid or unreadable, and the groups then too. The signing team only groups the app's data, so its
    /// resources are not hashed. A bundle that is not downloaded is not.
    public static func staticSigning(_ path: String) -> AppSigning {
        PropertyListFile.withoutDownloading { signing(path) }
    }

    private static func signing(_ path: String) -> AppSigning {
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

    /// The bundle ID and names in an `Info.plist` (`PropertyListFile`); `nil` without a bundle ID.
    static func infoPlist(_ plist: [String: Any]) -> (bundleID: String, names: [String])? {
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let names = ["CFBundleName", "CFBundleDisplayName"].compactMap { plist[$0] as? String }.filter { !$0.isEmpty }
        return (bundleID, names)
    }

    static func listing(_ path: String, unread: inout [String]) -> [String] {
        switch SimulatorRuntimes.listing(path) {
        case let .success(names): return names
        case let .failure(failure):
            unread.append("\(path) could not be listed: \(failure.message).")
            return []
        }
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
