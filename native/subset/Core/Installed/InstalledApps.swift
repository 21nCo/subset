import Foundation

/// A folder installed apps are looked for in.
public struct ApplicationsFolder: Equatable, Sendable {
    /// How the folder is shown: /Applications or ~/Applications.
    public var label: String
    /// The folder as receipts name it: /Applications or /Users/<user>/Applications.
    public var path: String
    /// The folder searched; the same as `path` except in tests, where a temporary folder stands in for it.
    public var directory: URL

    public init(label: String, path: String, directory: URL? = nil) {
        self.label = label
        self.path = path
        self.directory = directory ?? URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// One installed copy of a feed app.
public struct InstalledCopy: Equatable, Sendable {
    /// The `.app` found.
    public var path: String
    /// The folder it is in, as shown: /Applications or ~/Applications.
    public var folder: String
    /// CFBundleShortVersionString, or nil when it is missing.
    public var version: String?
    /// CFBundleVersion, or nil when it is missing.
    public var build: String?
    /// The channel of a valid receipt that describes this copy, otherwise nil.
    public var channel: ReleaseChannel?

    public init(path: String, folder: String, version: String?, build: String?, channel: ReleaseChannel?) {
        self.path = path
        self.folder = folder
        self.version = version
        self.build = build
        self.channel = channel
    }

    /// The copy as `subset list` shows it: 0.1.0, or 0.1.1-beta.4 for a beta by its receipt.
    public var versionLabel: String {
        guard let version else { return "unknown version" }
        if channel == .beta, let build { return "\(version)-beta.\(build)" }
        return version
    }
}

/// Finds which feed apps are installed; `InstalledAppFinder` looks on disk.
public protocol InstalledAppDetecting: Sendable {
    /// The installed copies of each app, by app ID, in folder order.
    func detect(_ apps: [CatalogApp]) -> [String: [InstalledCopy]]
}

/// Which feed apps are installed (decision D2 of SET-224, as `subset list` detects them): `<appName>.app` at the top
/// level of /Applications and ~/Applications, accepted only when its Info.plist's CFBundleIdentifier is the feed's
/// bundle ID. An app elsewhere (another folder, a subfolder, under another name, a symbolic link) is not found. A valid
/// install receipt that names the copy's path, version and (for a beta) build adds its channel.
public struct InstalledAppFinder: InstalledAppDetecting {
    static let maxInfoPlistBytes = 1024 * 1024

    public var folders: [ApplicationsFolder]
    /// ~/Library/Application Support/Subset/receipts.
    public var receipts: URL

    public init(folders: [ApplicationsFolder], receipts: URL) {
        self.folders = folders
        self.receipts = receipts
    }

    /// /Applications and ~/Applications of the user whose home is `home`, and that user's receipts.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstalledAppFinder {
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true).path
        return InstalledAppFinder(
            folders: [
                ApplicationsFolder(label: "/Applications", path: "/Applications"),
                ApplicationsFolder(label: "~/Applications", path: userApplications)
            ],
            receipts: home.appendingPathComponent("Library/Application Support/Subset/receipts", isDirectory: true)
        )
    }

    /// The installed copies of each app, by app ID, in folder order.
    public func detect(_ apps: [CatalogApp]) -> [String: [InstalledCopy]] {
        Dictionary(apps.map { ($0.id, copies(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The installed copies of `app`, in folder order.
    public func copies(of app: CatalogApp) -> [InstalledCopy] {
        let receipt = receipt(for: app.bundleID)
        return folders.compactMap { folder in
            let bundle = folder.directory.appendingPathComponent("\(app.appName).app").path
            guard let info = Self.infoPlist(bundle), info["CFBundleIdentifier"] as? String == app.bundleID else { return nil }
            var copy = InstalledCopy(
                path: bundle, folder: folder.label, version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String, channel: nil
            )
            copy.channel = Self.channel(of: receipt, describing: copy, at: "\(folder.path)/\(app.appName).app")
            return copy
        }
    }

    /// The valid receipt of the app with `bundleID`, or nil when there is none or it is unreadable or invalid. The
    /// bundle ID comes from a validated feed, so it has no / or .. part.
    public func receipt(for bundleID: String) -> Receipt? {
        let file = receipts.appendingPathComponent("\(bundleID).json").path
        guard let data = BoundedFile.read(file, limit: Receipt.maxBytes) else { return nil }
        return try? Receipt.parse(data).get()
    }

    // The receipt's channel when it describes this copy: the same .app path, version and, for a beta, build.
    private static func channel(of receipt: Receipt?, describing copy: InstalledCopy, at path: String) -> ReleaseChannel? {
        guard let receipt, receipt.path == path, receipt.version == copy.version else { return nil }
        if receipt.channel == .beta, receipt.build.map(String.init) != copy.build { return nil }
        return receipt.channel
    }

    /// The Info.plist of an app bundle, or nil when the bundle, its Contents folder or its Info.plist is not a plain
    /// folder, folder and file (a symbolic link at any of them could name a plist outside the bundle), or it is not a
    /// property list dictionary.
    static func infoPlist(_ bundle: String) -> [String: Any]? {
        let contents = "\(bundle)/Contents"
        guard BoundedFile.isDirectory(bundle), BoundedFile.isDirectory(contents),
              let data = BoundedFile.read("\(contents)/Info.plist", limit: maxInfoPlistBytes), data.count <= maxInfoPlistBytes
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
