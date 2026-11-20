import Foundation

/// A command an installed app bundles, as the Command Line section shows it.
public struct HelperExample: Equatable, Identifiable, Sendable {
    public var id: String { command }
    /// The app's name in the feed.
    public var appName: String
    /// The feed helper's command: `subset <command>` runs it.
    public var command: String
    /// A command line to copy, such as `subset system status`.
    public var example: String
    /// Where the instructions for agents are, in the command's README.
    public var guide: URL
    /// Whether the copy `subset` runs (the first in /Applications, then ~/Applications) has the command; an older copy
    /// needs an update first.
    public var bundled: Bool
}

/// The examples for the bundled commands of installed apps, from the feed's `helpers`.
public enum HelperExamples {
    /// The one-line setup the section offers to copy. The app never runs it.
    public static let setupCommand = "npm i -g subset.dev"
    static let repository = "https://github.com/21nCo/subset/blob/dev/"
    /// Every bundled command's section in `packages/subset-dev/README.md`, for a command without a guide of its own.
    static let fallbackGuide = "packages/subset-dev/README.md#commands-bundled-in-mac-apps"
    /// The first `subset` that runs the commands Mac apps bundle (SET-232); an older one runs none of the examples.
    public static let minimumLauncherVersion = "0.2.0"

    /// The read-only example and the agent instructions of each command the apps bundle today (docs/macos-release.md).
    /// `subset timer` lists the timers, since `status` needs a timer.
    static let known: [String: (arguments: String, guide: String)] = [
        "timer": ("list", "packages/timer-cli/README.md#agent-skill"),
        "minutes": ("status", "packages/minutes-cli/README.md#json-output-for-agents-and-apps"),
        "system": ("status", "native/system/README.md#agent-helper"),
        "point-in-time": ("status", "native/point-in-time/README.md#command-line-status-for-agents"),
    ]

    /// One example per helper of each feed app with an installed copy, in feed order. A helper the table above does not
    /// know shows `subset <command> --help` and the bundled commands' section of the `subset.dev` README. `isFile` tells
    /// whether the first copy, which `subset` runs, has the helper at its feed path.
    public static func examples(
        apps: [CatalogApp], installed: [String: [InstalledCopy]],
        isFile: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [HelperExample] {
        apps.compactMap { app in installed[app.id]?.first.map { (app, $0) } }.flatMap { app, copy in
            app.helpers.map { helper in
                let known = known[helper.command]
                return HelperExample(
                    appName: app.name, command: helper.command,
                    example: "subset \(helper.command) \(known?.arguments ?? "--help")",
                    guide: URL(string: repository + (known?.guide ?? fallbackGuide))!,
                    bundled: isFile(copy.path + "/" + helper.path)
                )
            }
        }
    }

    /// Whether `subset` at `version` runs bundled commands: `minimumLauncherVersion` or later, a pre-release of it
    /// being earlier.
    public static func runsBundledCommands(_ version: String) -> Bool {
        func parts(_ version: String) -> (core: [Int], preRelease: Bool) {
            let core = version.split(separator: "+")[0].split(separator: "-", maxSplits: 1)
            return (core[0].split(separator: ".").map { Int($0) ?? 0 }, core.count > 1)
        }
        let (have, preRelease) = parts(version)
        let need = parts(minimumLauncherVersion).core
        return have == need ? !preRelease : !have.lexicographicallyPrecedes(need)
    }
}
