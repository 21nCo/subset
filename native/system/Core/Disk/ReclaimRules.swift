import Foundation

/// How careful a cleanup must be.
public enum ReclaimRisk: String, CaseIterable, Sendable {
    /// Rebuilt or downloaded again by its tool when needed; nothing of the user's is lost.
    case safe
    /// May hold something the user wants to keep; each item is chosen on its own.
    case review
    /// Shown for information only; System offers no cleanup.
    case info
}

/// What a cleanup of a match would do. Rules only describe it; nothing here deletes or runs anything (SET-48 does,
/// after confirmation).
public enum ReclaimCleanup: Equatable, Sendable {
    /// Move the match's items to the Trash, as one action.
    case trash
    /// Move items to the Trash one at a time, each chosen by the user.
    case trashEachItem
    /// Move one app's cache folders to the Trash, one app at a time.
    case trashPerApp
    /// Run this exact argument vector of an allowlisted tool.
    case command([String])
    /// No cleanup is offered.
    case none
}

/// How much of what a match measures its cleanup frees, so that a measured size is never shown as a yield it is not.
public enum ReclaimYield: String, CaseIterable, Sendable {
    /// The cleanup removes every item the match measures, so it frees at least their private sum.
    case allMeasured
    /// The cleanup keeps part of what the match measures (a tool's prune of what nothing uses), so what it frees is
    /// unknown: the size is the folder's usage.
    case partOfMeasured
    /// The cleanup frees at most the space the tool reports (Docker's reclaimable image space).
    case reportedUpperBound
    /// No cleanup is offered; the size is what emptying it by hand frees.
    case noCleanup
}

/// The rules of the catalog, by stable identifier.
public enum ReclaimRuleID: String, CaseIterable, Sendable {
    case xcodeDerivedData
    case xcodeDeviceSupport
    case unavailableSimulators
    case simulatorCaches
    case xcodeArchives
    case staleNodeModules
    case npmCache
    case pnpmStore
    case yarnCache
    case homebrewCache
    case dockerImages
    case cargoRegistryCache
    case gradleCaches
    case pipCache
    case appCaches
    case deviceBackups
    case oldInstallers
    case appLeftovers
    case trash
}

/// One rule of the catalog: what it matches, what that data is, how it comes back, and how it would be cleaned up.
public struct ReclaimRule: Equatable, Sendable, Identifiable {
    public let id: ReclaimRuleID
    public let name: String
    /// Where the rule looks, for people: `~` is the home folder.
    public let location: String
    public let risk: ReclaimRisk
    public let cleanup: ReclaimCleanup
    /// How much of what the match measures the cleanup frees.
    public let yield: ReclaimYield
    /// What the data is.
    public let explanation: String
    /// How it is rebuilt after a cleanup, or why it is not.
    public let rebuild: String
    /// The developer tool the data belongs to, for the By origin view; `nil` for an app's or the user's data.
    public let developerTool: String?
    /// The folders the rule looks in, relative to the home folder; empty for a rule that searches the whole home
    /// folder or reads another source.
    public let homePaths: [String]
}

/// The closed, versioned catalog of reclaim rules. The acceptance set is exactly these; other candidates are SET-61
/// follow-ups. A change to a rule's meaning raises `catalogVersion`, which the agent helper's JSON reports (SET-52).
public enum ReclaimRules {
    public static let catalogVersion = 1

    /// A `node_modules` folder is stale when nothing else in its project has been touched for longer than this.
    public static let staleNodeModulesAge: TimeInterval = 30 * 86_400
    /// A `.dmg` or `.pkg` in Downloads is old when it has not been touched for longer than this.
    public static let oldInstallerAge: TimeInterval = 90 * 86_400

    public static let all: [ReclaimRule] = [
        ReclaimRule(
            id: .xcodeDerivedData, name: "Xcode DerivedData", location: "~/Library/Developer/Xcode/DerivedData",
            risk: .safe, cleanup: .trash, yield: .allMeasured,
            explanation: "Build products, intermediate files, and indexes Xcode keeps for each project it has built.",
            rebuild: "Xcode rebuilds a project's folder the next time it builds or indexes that project.",
            developerTool: "Xcode", homePaths: ["Library/Developer/Xcode/DerivedData"]),
        ReclaimRule(
            id: .xcodeDeviceSupport, name: "Xcode device support", location: "~/Library/Developer/Xcode/* DeviceSupport",
            risk: .safe, cleanup: .trash, yield: .allMeasured,
            explanation: "Symbol files Xcode copied from each OS version of a connected iPhone, iPad, Apple Watch, Apple TV, or Vision Pro, for debugging on it.",
            rebuild: "Xcode copies them again the next time a device with that OS version is connected for development.",
            developerTool: "Xcode", homePaths: ["Library/Developer/Xcode"]),
        ReclaimRule(
            id: .unavailableSimulators, name: "Unavailable simulators", location: "~/Library/Developer/CoreSimulator/Devices",
            risk: .safe, cleanup: .command(["xcrun", "simctl", "delete", "unavailable"]), yield: .allMeasured,
            explanation: "Simulator devices whose OS runtime is no longer installed, so they cannot be started.",
            rebuild: "Nothing to rebuild: the devices cannot run. Installing their runtime again in Xcode creates new devices.",
            developerTool: "Xcode", homePaths: ["Library/Developer/CoreSimulator/Devices"]),
        ReclaimRule(
            id: .simulatorCaches, name: "Simulator caches", location: "~/Library/Developer/CoreSimulator/Caches",
            risk: .safe, cleanup: .trash, yield: .allMeasured,
            explanation: "Caches the simulator keeps, such as shared-library caches built for each runtime.",
            rebuild: "The simulator rebuilds them the next time a device starts.",
            developerTool: "Xcode", homePaths: ["Library/Developer/CoreSimulator/Caches"]),
        ReclaimRule(
            id: .xcodeArchives, name: "Xcode archives", location: "~/Library/Developer/Xcode/Archives",
            risk: .review, cleanup: .trashEachItem, yield: .allMeasured,
            explanation: "App builds archived for distribution, with their debug symbols.",
            rebuild: "Not rebuilt: an archive's symbols are needed to read crash reports from the build it shipped. Keep those of releases still in use.",
            developerTool: "Xcode", homePaths: ["Library/Developer/Xcode/Archives"]),
        ReclaimRule(
            id: .staleNodeModules, name: "Stale node_modules",
            location: "node_modules in project folders under ~ untouched for 30 days",
            risk: .safe, cleanup: .trash, yield: .allMeasured,
            explanation: "Packages installed for a JavaScript project whose files have not changed for 30 days.",
            rebuild: "Running npm install, pnpm install, or yarn in the project installs them again.",
            developerTool: "Node.js", homePaths: []),
        ReclaimRule(
            id: .npmCache, name: "npm cache", location: "~/.npm/_cacache",
            risk: .safe, cleanup: .command(["npm", "cache", "clean", "--force"]), yield: .allMeasured,
            explanation: "Packages npm has downloaded, kept so that later installs need not download them again.",
            rebuild: "npm downloads packages again as installs need them.",
            developerTool: "npm", homePaths: [".npm/_cacache"]),
        ReclaimRule(
            id: .pnpmStore, name: "pnpm store",
            location: "~/Library/pnpm/store, ~/.local/share/pnpm/store, or ~/.pnpm-store",
            risk: .safe, cleanup: .command(["pnpm", "store", "prune"]), yield: .partOfMeasured,
            explanation: "The store holding every package version pnpm has installed, which projects link to.",
            rebuild: "pnpm store prune removes only packages no project references; pnpm downloads any it needs again.",
            developerTool: "pnpm", homePaths: ["Library/pnpm/store", ".local/share/pnpm/store", ".pnpm-store"]),
        ReclaimRule(
            id: .yarnCache, name: "Yarn cache", location: "~/Library/Caches/Yarn",
            risk: .safe, cleanup: .command(["yarn", "cache", "clean"]), yield: .allMeasured,
            explanation: "Packages Yarn has downloaded, kept so that later installs need not download them again.",
            rebuild: "Yarn downloads packages again as installs need them.",
            developerTool: "Yarn", homePaths: ["Library/Caches/Yarn"]),
        ReclaimRule(
            id: .homebrewCache, name: "Homebrew cache", location: "~/Library/Caches/Homebrew",
            risk: .safe, cleanup: .command(["brew", "cleanup"]), yield: .partOfMeasured,
            explanation: "Downloaded bottles and source archives Homebrew keeps after installing or upgrading.",
            rebuild: "brew cleanup removes outdated downloads and old versions; Homebrew downloads anything it needs again.",
            developerTool: "Homebrew", homePaths: ["Library/Caches/Homebrew"]),
        ReclaimRule(
            id: .dockerImages, name: "Docker images", location: "Reported by docker system df",
            risk: .safe, cleanup: .command(["docker", "image", "prune", "-f"]), yield: .reportedUpperBound,
            explanation: "Image layers inside the Docker VM. docker image prune -f removes only dangling images, untagged layers no container uses.",
            rebuild: "A dangling image has no tag, so nothing refers to it; images still in use are kept.",
            developerTool: "Docker", homePaths: []),
        ReclaimRule(
            id: .cargoRegistryCache, name: "Cargo registry cache", location: "~/.cargo/registry/cache",
            risk: .safe, cleanup: .trash, yield: .allMeasured,
            explanation: "Crate archives Cargo has downloaded from crates.io.",
            rebuild: "Cargo downloads crates again the next time a build needs them.",
            developerTool: "Cargo", homePaths: [".cargo/registry/cache"]),
        ReclaimRule(
            id: .gradleCaches, name: "Gradle caches", location: "~/.gradle/caches",
            risk: .safe, cleanup: .trash, yield: .allMeasured,
            explanation: "Dependencies, build outputs, and transformed artifacts Gradle caches for all projects.",
            rebuild: "Gradle downloads and rebuilds them on the next build, which takes longer once.",
            developerTool: "Gradle", homePaths: [".gradle/caches"]),
        ReclaimRule(
            id: .pipCache, name: "pip cache", location: "~/Library/Caches/pip",
            risk: .safe, cleanup: .trash, yield: .allMeasured,
            explanation: "Packages and built wheels pip has downloaded.",
            rebuild: "pip downloads or builds them again on the next install.",
            developerTool: "pip", homePaths: ["Library/Caches/pip"]),
        ReclaimRule(
            id: .appCaches, name: "App caches", location: "~/Library/Caches/<bundle id>",
            risk: .safe, cleanup: .trashPerApp, yield: .allMeasured,
            explanation: "Files an installed app keeps in its cache folder to work faster, such as downloaded images and web data.",
            rebuild: "The app downloads or creates them again as it needs them; it may be slower for a while.",
            developerTool: nil, homePaths: ["Library/Caches"]),
        ReclaimRule(
            id: .deviceBackups, name: "Device backups", location: "~/Library/Application Support/MobileSync/Backup",
            risk: .review, cleanup: .trashEachItem, yield: .allMeasured,
            explanation: "Local backups of iPhones and iPads made by Finder or Apple Devices.",
            rebuild: "Not rebuilt: a backup removed here is gone unless the device or iCloud has another. Keep the latest backup of each device you use.",
            developerTool: nil, homePaths: ["Library/Application Support/MobileSync/Backup"]),
        ReclaimRule(
            id: .oldInstallers, name: "Old installers", location: ".dmg and .pkg in ~/Downloads untouched for 90 days",
            risk: .review, cleanup: .trashEachItem, yield: .allMeasured,
            explanation: "Disk images and installer packages downloaded more than 90 days ago, usually already installed.",
            rebuild: "Not rebuilt: download it again from its publisher if you need it.",
            developerTool: nil, homePaths: ["Downloads"]),
        ReclaimRule(
            id: .appLeftovers, name: "App leftovers",
            location: "~/Library folders named for a bundle ID no installed app has",
            risk: .review, cleanup: .trashEachItem, yield: .allMeasured,
            explanation: "Data, caches, containers, settings, logs, and web storage named for an app that is not installed, usually one that was removed.",
            rebuild: "Not rebuilt: if the app is installed again it starts without its old settings and data.",
            developerTool: nil, homePaths: LibraryFolder.allCases.map(\.homePath)),
        ReclaimRule(
            id: .trash, name: "Trash", location: "~/.Trash",
            risk: .info, cleanup: .none, yield: .noCleanup,
            explanation: "Items already moved to the Trash, which still use space until the Trash is emptied.",
            rebuild: "System never empties the Trash; empty it in Finder when you are sure.",
            developerTool: nil, homePaths: [".Trash"])
    ]

    public static func rule(_ id: ReclaimRuleID) -> ReclaimRule {
        all.first { $0.id == id }!
    }
}
